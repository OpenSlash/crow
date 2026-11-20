import AppKit
import ApplicationServices
import Carbon
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
    /// Shows Crow's Settings at the Computer use section.
    var onOpenSettings: (() -> Void)?
    private var loop: Swift.Task<Void, Never>?
    private var lastPostedAt = Date.distantPast
    private var stopMonitors: [Any] = []
    /// Elements numbered by the latest `elements` call.
    private var elements: [Int: AXUIElement] = [:]

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
            if command.action == "open_settings" {
                onOpenSettings?()
                return result
            }
            guard Self.hasScreenRecording else {
                onOpenSettings?()
                throw ComputerUseError("Crow needs Screen Recording permission. Crow Settings is now open at Computer use: tell the user to click Grant next to Screen Recording, allow Crow in System Settings, then restart Crow.")
            }
            var text = ""
            var attachScreenshot = true
            switch command.action {
            case "screenshot":
                break
            case "zoom":
                let shot = try await zoom(args)
                attach(shot, to: &result)
                attachScreenshot = false
            case "windows":
                text = listWindows()
                attachScreenshot = false
            case "elements":
                let found = collectElements()
                text = describeElements(found)
                attach(try await screenshot(marking: found), to: &result)
                attachScreenshot = false
            default:
                guard Self.hasAccessibility else {
                    onOpenSettings?()
                    throw ComputerUseError("Crow needs Accessibility permission to use the mouse and keyboard. Crow Settings is now open at Computer use: tell the user to click Grant next to Accessibility and allow Crow in System Settings.")
                }
                try await waitForUserToPause()
                try await act(command.action, args)
                lastPostedAt = Date()
                try await Swift.Task.sleep(nanoseconds: 600_000_000)
                attachScreenshot = (args["screenshot"] as? Bool) ?? true
            }
            if attachScreenshot {
                attach(try await screenshot(), to: &result)
            }
            result["text"] = [text, screenContext()].filter { !$0.isEmpty }.joined(separator: "\n")
        } catch {
            result["ok"] = false
            result["error"] = error.localizedDescription
        }
        return result
    }

    private func act(_ action: String, _ args: [String: Any]) async throws {
        switch action {
        case "click":
            let count = max(1, min(3, (args["count"] as? NSNumber)?.intValue ?? 1))
            let button = args["button"] as? String ?? "left"
            if let number = (args["element"] as? NSNumber)?.intValue {
                let element = try cachedElement(number)
                // A plain click on a pressable control uses AXPress: no pointer movement, works even if covered.
                if button == "left", count == 1, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    break
                }
                guard let frame = elementFrame(element) else { throw ComputerUseError("Element \(number) is no longer on screen; call elements again") }
                click(at: CGPoint(x: frame.midX, y: frame.midY), button: button, count: count)
            } else {
                click(at: try screenPoint(args, "x", "y"), button: button, count: count)
            }
        case "set_value":
            guard let number = (args["element"] as? NSNumber)?.intValue else { throw ComputerUseError("element is required") }
            try setValue(args["text"] as? String ?? "", on: try cachedElement(number))
        case "move":
            post(mouse: .mouseMoved, at: try screenPoint(args, "x", "y"), button: .left)
        case "drag":
            drag(from: try screenPoint(args, "x", "y"), to: try screenPoint(args, "to_x", "to_y"))
        case "type":
            try refuseSecureInput()
            try await type(args["text"] as? String ?? "")
        case "key":
            try refuseSecureInput()
            try pressKeys(args["keys"] as? String ?? "")
        case "scroll":
            let point = try screenPoint(args, "x", "y")
            post(mouse: .mouseMoved, at: point, button: .left)
            scroll(direction: args["direction"] as? String ?? "down", amount: (args["amount"] as? NSNumber)?.intValue ?? 3)
        case "open_app":
            try await openApp(args["name"] as? String ?? "")
        case "focus":
            try await focus(app: args["name"] as? String ?? "", title: args["title"] as? String)
        default:
            throw ComputerUseError("Unknown action \(action)")
        }
    }

    /// Waits until the user has not touched the mouse or keyboard for a moment.
    /// Crow's own synthetic events also reset the idle timer, so only input after
    /// Crow's last action counts as the user's.
    private func waitForUserToPause() async throws {
        let deadline = Date().addingTimeInterval(Self.userWaitLimit)
        while true {
            if !isUserActive() { return }
            if Date() > deadline {
                throw ComputerUseError("The user is using the computer, so Crow stopped to avoid interfering.")
            }
            try await Swift.Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// True when hardware input arrived recently and after Crow's own last event.
    private func isUserActive() -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let lastInput = Date().addingTimeInterval(-idle)
        return idle < Self.userIdleSeconds && lastInput > lastPostedAt.addingTimeInterval(0.3)
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

    private typealias Shot = (jpeg: Data, width: Int, height: Int)

    private func attach(_ shot: Shot, to result: inout [String: Any]) {
        result["image"] = shot.jpeg.base64EncodedString()
        result["imageMediaType"] = "image/jpeg"
        result["width"] = shot.width
        result["height"] = shot.height
    }

    /// The whole main display, scaled to the screenshot coordinate space. The pointer is drawn in;
    /// `marking` draws numbered boxes around elements.
    private func screenshot(marking marks: [FoundElement] = []) async throws -> Shot {
        let display = try await mainDisplay()
        let scale = screenshotScale
        return try await capture(display: display, region: nil,
                                 width: Int((CGFloat(display.width) * scale).rounded()),
                                 height: Int((CGFloat(display.height) * scale).rounded()),
                                 marks: marks)
    }

    /// A region of the latest screenshot (in its pixels), captured again at up to full detail.
    private func zoom(_ args: [String: Any]) async throws -> Shot {
        guard let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue,
              let w = (args["width"] as? NSNumber)?.doubleValue, let h = (args["height"] as? NSNumber)?.doubleValue,
              w >= 4, h >= 4 else {
            throw ComputerUseError("zoom needs x, y, width and height (at least 4 pixels)")
        }
        let display = try await mainDisplay()
        let scale = screenshotScale
        let region = CGRect(x: x / scale, y: y / scale, width: w / scale, height: h / scale)
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height)))
        guard !region.isEmpty else { throw ComputerUseError("The zoom region is outside the screenshot") }
        let backing = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.backingScaleFactor ?? 2
        let fit = min(1, Self.maxScreenshotWidth / (region.width * backing), 800 / (region.height * backing))
        return try await capture(display: display, region: region,
                                 width: max(1, Int((region.width * backing * fit).rounded())),
                                 height: max(1, Int((region.height * backing * fit).rounded())))
    }

    private func mainDisplay() async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ComputerUseError("No display found")
        }
        return display
    }

    private func capture(display: SCDisplay, region: CGRect?, width: Int, height: Int, marks: [FoundElement] = []) async throws -> Shot {
        let configuration = SCStreamConfiguration()
        if let region { configuration.sourceRect = region }
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = true
        var image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        if !marks.isEmpty, let marked = draw(marks, on: image) {
            image = marked
        }
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw ComputerUseError("Could not encode the screenshot")
        }
        return (jpeg, image.width, image.height)
    }

    /// Converts screen points to screenshot pixels.
    private func screenshotPoint(_ point: CGPoint) -> (Int, Int) {
        let scale = screenshotScale
        return (Int(((point.x - displayBounds.minX) * scale).rounded()), Int(((point.y - displayBounds.minY) * scale).rounded()))
    }

    /// Pointer position and front window, so the model knows where it is.
    private func screenContext() -> String {
        var lines: [String] = []
        if let location = CGEvent(source: nil)?.location {
            let (x, y) = screenshotPoint(location)
            lines.append("Pointer at (\(x), \(y)).")
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            var line = "Front app: \(app.localizedName ?? "unknown")"
            if let title = focusedWindowTitle(pid: app.processIdentifier), !title.isEmpty {
                line += ", window \"\(title)\""
            }
            lines.append(line + ".")
        }
        return lines.joined(separator: " ")
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    // MARK: Elements

    struct FoundElement {
        let number: Int
        let role: String
        let label: String
        let frame: CGRect // screen points
        let enabled: Bool
    }

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXMenuButton", "AXLink", "AXSlider", "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle", "AXIncrementor",
        "AXSearchField", "AXCell", "AXRow", "AXTab", "AXSegmentedControl", "AXColorWell", "AXDateField", "AXStepper",
    ]

    /// Walks the front window's accessibility tree for visible controls, within a time and count budget.
    private func collectElements() -> [FoundElement] {
        elements = [:]
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var roots: [AXUIElement] = []
        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) { roots.append(window) }
        if let menuBar: AXUIElement = attribute(appElement, kAXMenuBarAttribute) { roots.append(menuBar) }
        let deadline = Date().addingTimeInterval(1.5)
        var found: [FoundElement] = []
        var stack = roots.reversed().map { ($0, 0) }
        while let (element, depth) = stack.popLast(), found.count < 150, Date() < deadline {
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if Self.interactiveRoles.contains(role), let frame = elementFrame(element),
               frame.width >= 3, frame.height >= 3, displayBounds.intersects(frame),
               // Menu bar items only at the top level, not every hidden menu item.
               !(role == "AXMenuItem" && depth > 3) {
                let number = found.count + 1
                elements[number] = element
                let enabled: Bool = attribute(element, kAXEnabledAttribute) ?? true
                found.append(FoundElement(number: number, role: role, label: elementLabel(element), frame: frame, enabled: enabled))
            }
            guard depth < 30, role != "AXMenu" else { continue }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return found
    }

    private func describeElements(_ found: [FoundElement]) -> String {
        guard !found.isEmpty else {
            return "No accessible controls found in the front window; use coordinates from the screenshot."
        }
        let scale = screenshotScale
        let lines = found.map { element -> String in
            let (x, y) = screenshotPoint(element.frame.origin)
            let role = element.role.replacingOccurrences(of: "AX", with: "").lowercased()
            let label = element.label.isEmpty ? "" : " \"\(element.label)\""
            return "[\(element.number)] \(role)\(label) at (\(x), \(y)) size \(Int(element.frame.width * scale))x\(Int(element.frame.height * scale))\(element.enabled ? "" : " (disabled)")"
        }
        return "Elements (numbers are drawn on the screenshot):\n" + lines.joined(separator: "\n")
    }

    private func elementLabel(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute] {
            if let text: String = attribute(element, key), !text.isEmpty { return String(text.prefix(60)) }
        }
        if let value: String = attribute(element, kAXValueAttribute), !value.isEmpty {
            return String(value.prefix(60))
        }
        if let titleElement: AXUIElement = attribute(element, kAXTitleUIElementAttribute),
           let text: String = attribute(titleElement, kAXValueAttribute) {
            return String(text.prefix(60))
        }
        return ""
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement) as? T
        }
        return value as? T
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private func cachedElement(_ number: Int) throws -> AXUIElement {
        guard let element = elements[number] else {
            throw ComputerUseError("No element \(number); call elements again")
        }
        return element
    }

    /// Fills a text control through accessibility, without the keyboard. Refuses password fields.
    private func setValue(_ text: String, on element: AXUIElement) throws {
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) {
            throw ComputerUseError("This is a password field. Crow never types passwords; ask the user to do this step.")
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw ComputerUseError("This element does not accept a value; click it and use type instead")
        }
    }

    /// Draws numbered boxes for elements on a screenshot (Set-of-Mark).
    private func draw(_ marks: [FoundElement], on image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to top-left origin so screenshot coordinates apply directly.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let scale = screenshotScale
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let color = NSColor.systemRed
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
        ]
        for mark in marks {
            let rect = CGRect(x: (mark.frame.minX - displayBounds.minX) * scale, y: (mark.frame.minY - displayBounds.minY) * scale,
                              width: mark.frame.width * scale, height: mark.frame.height * scale)
            context.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect)
            let label = "\(mark.number)" as NSString
            let size = label.size(withAttributes: attributes)
            let tag = CGRect(x: rect.minX, y: max(0, rect.minY - size.height), width: size.width + 4, height: size.height)
            context.setFillColor(color.cgColor)
            context.fill(tag)
            label.draw(at: CGPoint(x: tag.minX + 2, y: tag.minY), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: Windows

    /// On-screen app windows, front to back, with bounds in screenshot pixels.
    private func listWindows() -> String {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return "No windows found."
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var lines: [String] = []
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40,
                  bounds.intersects(displayBounds) else { continue }
            let title = window[kCGWindowName as String] as? String ?? ""
            let (x, y) = screenshotPoint(bounds.origin)
            let scale = screenshotScale
            lines.append("\(lines.count + 1). \(owner)\(title.isEmpty ? "" : " — \"\(title)\"") at (\(x), \(y)) size \(Int(bounds.width * scale))x\(Int(bounds.height * scale))")
            if lines.count >= 30 { break }
        }
        return lines.isEmpty ? "No windows found on the main display." : "Windows, front to back:\n" + lines.joined(separator: "\n")
    }

    /// Brings an app forward and, if a title is given, raises its matching window.
    private func focus(app name: String, title: String?) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw ComputerUseError("name is required") }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let app = apps.first(where: { $0.localizedName?.lowercased() == name })
            ?? apps.first(where: { $0.localizedName?.lowercased().contains(name) == true }) else {
            throw ComputerUseError("\(name) is not running; use open_app")
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !title.isEmpty {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
            let match = (windows as? [AXUIElement])?.first { window in
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
                return (value as? String)?.lowercased().contains(title) == true
            }
            guard let match else { throw ComputerUseError("No \(app.localizedName ?? name) window titled \"\(title)\"") }
            AXUIElementPerformAction(match, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        app.activate()
        try await Swift.Task.sleep(nanoseconds: 400_000_000)
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

    /// Refuses keyboard input into password fields, and while macOS secure input is on
    /// (it silently drops synthetic keys, e.g. Terminal's Secure Keyboard Entry).
    private func refuseSecureInput() throws {
        if IsSecureEventInputEnabled() {
            throw ComputerUseError("macOS secure input is on (a password field or Secure Keyboard Entry is active), so typed keys would be dropped. Ask the user to do this step.")
        }
        let system = AXUIElementCreateSystemWide()
        // An unresponsive app must not stall Crow's main thread.
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) {
            throw ComputerUseError("The focused field is a password field. Crow never types passwords; ask the user to do this step.")
        }
    }

    /// Types Unicode text regardless of keyboard layout or input method. Stops between
    /// chunks if the user starts typing or the task is cancelled.
    private func type(_ text: String) async throws {
        var typed = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                tap(key: 36, flags: [])
                typed += 1
            }
            let units = Array(line.utf16)
            var start = 0
            while start < units.count {
                if isUserActive() || Swift.Task.isCancelled {
                    throw ComputerUseError("Stopped after typing \(typed) of \(text.utf16.count) characters because the user started using the computer.")
                }
                let chunk = Array(units[start..<min(start + 20, units.count)])
                for keyDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.post(tap: .cghidEventTap)
                }
                lastPostedAt = Date()
                start += 20
                typed += chunk.count
                try await Swift.Task.sleep(nanoseconds: 8_000_000)
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
                guard let code = Self.layoutKeyCode(for: part) ?? Self.keyCodes[part] else {
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

    /// The key that types `character` in the current keyboard layout, so shortcuts
    /// like cmd+a hit the right key on AZERTY or Dvorak too. Named keys return nil.
    static func layoutKeyCode(for character: String) -> CGKeyCode? {
        guard character.count == 1,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<CGKeyCode(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == character {
                    return code
                }
            }
            return nil
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
