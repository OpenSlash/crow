import AppKit
import ApplicationServices
import ScreenCaptureKit

struct CrowComputerCommand: Decodable, Sendable {
    let id: String
    let action: String
    let argsJson: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        action = try container.decodeIfPresent(String.self, forKey: .action) ?? ""
        argsJson = try container.decodeIfPresent(String.self, forKey: .argsJson) ?? "{}"
    }

    enum CodingKeys: String, CodingKey {
        case id, action, argsJson
    }
}

struct CrowEmptyResponse: Decodable {}

private struct ComputerUseError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Performs computer-use commands from the daemon on the main display: screenshots
/// through ScreenCaptureKit, mouse and keyboard through CGEvent.
///
/// Safety: actions wait while the user is using the mouse or keyboard and give up
/// if they keep going; text is never typed into password fields; held keys are
/// released when a task ends or is stopped (Ctrl-Option-Esc).
@MainActor
final class CrowComputerUseHost {
    /// Screenshots are scaled to at most this width; coordinates use the same space.
    static let maxScreenshotWidth: CGFloat = 1280
    static let userIdleSeconds: TimeInterval = 2
    static let userWaitLimit: TimeInterval = 15

    var onStop: (() -> Void)?
    private var loop: Swift.Task<Void, Never>?
    private var lastPostedAt = Date.distantPast
    private var stopMonitors: [Any] = []

    func start(client: CrowRPCClient) {
        loop?.cancel()
        loop = Swift.Task { [weak self] in
            while !Swift.Task.isCancelled {
                do {
                    for try await command in try client.watchComputerCommands() {
                        guard let self else { return }
                        let result = await self.perform(command)
                        try? await client.submitComputerResult(result)
                    }
                } catch {
                    CrowMacLog("computer command stream ended \(error.localizedDescription)")
                }
                try? await Swift.Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        installStopShortcut()
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Permissions

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openPrivacyPane("Privacy_ScreenCapture")
        }
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Commands

    private func perform(_ command: CrowComputerCommand) async -> [String: Any] {
        var result: [String: Any] = ["id": command.id, "ok": true]
        do {
            let args = (try? JSONSerialization.jsonObject(with: Data(command.argsJson.utf8))) as? [String: Any] ?? [:]
            CrowMacLog("computer action=\(command.action)")
            if command.action == "release" {
                releaseHeldInput()
                return result
            }
            guard Self.hasScreenRecording else {
                Self.requestScreenRecording()
                throw ComputerUseError("Crow needs Screen Recording permission. Ask the user to allow it in System Settings > Privacy & Security, then try again.")
            }
            if command.action != "screenshot" {
                guard Self.hasAccessibility else {
                    Self.requestAccessibility()
                    throw ComputerUseError("Crow needs Accessibility permission to use the mouse and keyboard. Ask the user to allow it in System Settings > Privacy & Security, then try again.")
                }
                try await waitForUserToPause()
                try await act(command.action, args)
                lastPostedAt = Date()
                try await Swift.Task.sleep(nanoseconds: 600_000_000)
            }
            let shot = try await screenshot()
            result["image"] = shot.jpeg.base64EncodedString()
            result["imageMediaType"] = "image/jpeg"
            result["width"] = shot.width
            result["height"] = shot.height
        } catch {
            result["ok"] = false
            result["error"] = error.localizedDescription
        }
        return result
    }

    private func act(_ action: String, _ args: [String: Any]) async throws {
        switch action {
        case "click":
            let point = try screenPoint(args, "x", "y")
            let count = max(1, min(3, (args["count"] as? NSNumber)?.intValue ?? 1))
            click(at: point, button: args["button"] as? String ?? "left", count: count)
        case "move":
            post(mouse: .mouseMoved, at: try screenPoint(args, "x", "y"), button: .left)
        case "drag":
            drag(from: try screenPoint(args, "x", "y"), to: try screenPoint(args, "to_x", "to_y"))
        case "type":
            try refuseSecureField()
            type(args["text"] as? String ?? "")
        case "key":
            try pressKeys(args["keys"] as? String ?? "")
        case "scroll":
            let point = try screenPoint(args, "x", "y")
            post(mouse: .mouseMoved, at: point, button: .left)
            scroll(direction: args["direction"] as? String ?? "down", amount: (args["amount"] as? NSNumber)?.intValue ?? 3)
        case "open_app":
            try await openApp(args["name"] as? String ?? "")
        default:
            throw ComputerUseError("Unknown action \(action)")
        }
    }

    /// Waits until the user has not touched the mouse or keyboard for a moment.
    /// Crow's own synthetic events also reset the idle timer, so only input after
    /// Crow's last action counts as the user's.
    private func waitForUserToPause() async throws {
        let anyInput = CGEventType(rawValue: ~0)!
        let deadline = Date().addingTimeInterval(Self.userWaitLimit)
        while true {
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
            let lastInput = Date().addingTimeInterval(-idle)
            let userActive = idle < Self.userIdleSeconds && lastInput > lastPostedAt.addingTimeInterval(0.3)
            if !userActive { return }
            if Date() > deadline {
                throw ComputerUseError("The user is using the computer, so Crow stopped to avoid interfering.")
            }
            try await Swift.Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: Screen

    private var displayBounds: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    private var screenshotScale: CGFloat {
        min(1, Self.maxScreenshotWidth / max(displayBounds.width, 1))
    }

    private func screenPoint(_ args: [String: Any], _ xKey: String, _ yKey: String) throws -> CGPoint {
        guard let x = (args[xKey] as? NSNumber)?.doubleValue, let y = (args[yKey] as? NSNumber)?.doubleValue else {
            throw ComputerUseError("\(xKey) and \(yKey) are required")
        }
        let scale = screenshotScale
        let point = CGPoint(x: displayBounds.minX + x / scale, y: displayBounds.minY + y / scale)
        guard displayBounds.insetBy(dx: -1, dy: -1).contains(point) else {
            throw ComputerUseError("(\(Int(x)), \(Int(y))) is outside the screenshot")
        }
        return point
    }

    private func screenshot() async throws -> (jpeg: Data, width: Int, height: Int) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ComputerUseError("No display found")
        }
        let scale = screenshotScale
        let configuration = SCStreamConfiguration()
        configuration.width = Int((CGFloat(display.width) * scale).rounded())
        configuration.height = Int((CGFloat(display.height) * scale).rounded())
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw ComputerUseError("Could not encode the screenshot")
        }
        return (jpeg, image.width, image.height)
    }

    // MARK: Mouse

    private func post(mouse type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event?.post(tap: .cghidEventTap)
    }

    private func click(at point: CGPoint, button name: String, count: Int) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = switch name {
        case "right": (.rightMouseDown, .rightMouseUp, .right)
        case "middle": (.otherMouseDown, .otherMouseUp, .center)
        default: (.leftMouseDown, .leftMouseUp, .left)
        }
        post(mouse: .mouseMoved, at: point, button: button)
        for state in 1...count {
            post(mouse: down, at: point, button: button, clickState: state)
            post(mouse: up, at: point, button: button, clickState: state)
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint) {
        post(mouse: .mouseMoved, at: start, button: .left)
        post(mouse: .leftMouseDown, at: start, button: .left)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(mouse: .leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), button: .left)
            usleep(10_000)
        }
        post(mouse: .leftMouseUp, at: end, button: .left)
    }

    private func scroll(direction: String, amount: Int) {
        let lines = Int32(max(1, min(30, amount)))
        let (vertical, horizontal): (Int32, Int32) = switch direction {
        case "up": (lines, 0)
        case "left": (0, lines)
        case "right": (0, -lines)
        default: (-lines, 0)
        }
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func refuseSecureField() throws {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) {
            throw ComputerUseError("The focused field is a password field. Crow never types passwords; ask the user to do this step.")
        }
    }

    private func type(_ text: String) {
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { tap(key: 36, flags: []) }
            let units = Array(line.utf16)
            var start = 0
            while start < units.count {
                let chunk = Array(units[start..<min(start + 20, units.count)])
                for keyDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.post(tap: .cghidEventTap)
                }
                start += 20
                usleep(8_000)
            }
        }
    }

    private func pressKeys(_ combo: String) throws {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "super", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                guard let code = Self.keyCodes[part] else {
                    throw ComputerUseError("Unknown key \"\(part)\"")
                }
                key = code
            }
        }
        guard let key else { throw ComputerUseError("No key in \"\(combo)\"") }
        tap(key: key, flags: flags)
    }

    private func tap(key: CGKeyCode, flags: CGEventFlags) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Lifts modifier keys and mouse buttons in case anything was left down.
    func releaseHeldInput() {
        for code: CGKeyCode in [55, 54, 56, 60, 58, 61, 59, 62, 63] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        for (type, button) in [(CGEventType.leftMouseUp, CGMouseButton.left), (.rightMouseUp, .right)]
        where CGEventSource.buttonState(.combinedSessionState, button: button) {
            post(mouse: type, at: location, button: button)
        }
    }

    private func openApp(_ name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ComputerUseError("name is required") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        try process.run()
        while process.isRunning { try await Swift.Task.sleep(nanoseconds: 100_000_000) }
        guard process.terminationStatus == 0 else { throw ComputerUseError("Could not open \(name)") }
        try await Swift.Task.sleep(nanoseconds: 900_000_000)
    }

    // MARK: Stop shortcut

    /// Ctrl-Option-Esc stops the running task anywhere (needs Accessibility for other apps).
    private func installStopShortcut() {
        guard stopMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Bool = { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 53, mods == [.control, .option] else { return false }
            Swift.Task { @MainActor in
                self?.releaseHeldInput()
                self?.onStop?()
            }
            return true
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handler($0) }) {
            stopMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0) ? nil : $0 }) {
            stopMonitors.append(local)
        }
    }

    static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126
        ]
        let functionKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in functionKeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()
}
