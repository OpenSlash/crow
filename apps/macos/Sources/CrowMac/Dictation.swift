import AppKit
import AVFoundation
import Carbon.HIToolbox
import Speech

/// System-wide dictation: hold the dictation shortcut and speak, or tap it to
/// start and tap again to stop. The transcript is cleaned up by the model and
/// typed into the app that was in front, like an input method's voice input.
@MainActor
final class CrowDictation {
    static let shared = CrowDictation()

    /// Cleans up a transcript for the named app; set by the app model. Returns the
    /// input unchanged when no model is available.
    var polish: ((String, String) async -> String)?

    private enum Phase { case idle, recording, finishing }
    private var phase = Phase.idle
    private var session: CrowVoiceInputSession?
    private var observers: [NSObjectProtocol] = []
    private var pressedAt = Date.distantPast
    private var toggleMode = false
    private var targetApp: NSRunningApplication?
    private var transcript = ""
    private var finalTimeout: DispatchWorkItem?
    private let hud = CrowDictationHUD()

    /// A press shorter than this starts hands-free mode: tap again to stop.
    private static let tapThreshold: TimeInterval = 0.35

    private init() {}

    func hotKey(pressed: Bool) {
        switch (phase, pressed) {
        case (.idle, true):
            pressedAt = Date()
            toggleMode = false
            begin()
        case (.recording, true) where toggleMode:
            finish()
        case (.recording, false) where !toggleMode:
            if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
                toggleMode = true
                hud.show(L("Dictating… tap the shortcut again to finish"), level: nil)
            } else {
                finish()
            }
        default:
            break
        }
    }

    // MARK: Recording

    private func begin() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            CrowPermissionBridge.requestMicrophone { _ in }
            hud.flash(L("Allow microphone access for Crow, then try again."))
            return
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            CrowPermissionBridge.requestSpeech { _ in }
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        transcript = ""
        let locale = CrowIslandView.speechLocaleIdentifier()
        var started: CrowVoiceInputSession?
        for candidate in Self.makeSessions() {
            observe(candidate.id)
            do {
                try candidate.start(localeIdentifier: locale)
                started = candidate
                break
            } catch {
                NSLog("Crow dictation could not start \(type(of: candidate)): \(error.localizedDescription)")
                removeObservers()
            }
        }
        guard let started else {
            hud.flash(L("Speech recognition is unavailable."))
            return
        }
        session = started
        phase = .recording
        hud.show(L("Dictating…"), level: 0)
    }

    /// The configured recognizer first, then system speech as the fallback.
    private static func makeSessions() -> [CrowVoiceInputSession] {
        let provider = (CrowEnvironment.value("CROW_STT_PROVIDER") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch provider {
        case "cloud", "crow_cloud":
            return [CrowOpenAITranscriptionSession(useCloudBackend: true), CrowSystemSpeechSession()]
        case "openai", "openai_transcribe":
            return [CrowOpenAITranscriptionSession(), CrowSystemSpeechSession()]
        default:
            return [CrowSystemSpeechSession()]
        }
    }

    private func observe(_ sessionID: String) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .crowStreamingSpeechTranscript, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["id"] as? String == sessionID,
                  let text = note.userInfo?["text"] as? String else { return }
            let isFinal = note.userInfo?["isFinal"] as? Bool ?? false
            MainActor.assumeIsolated { self?.received(text, isFinal: isFinal) }
        })
        observers.append(center.addObserver(forName: .crowStreamingSpeechLevel, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["id"] as? String == sessionID,
                  let power = note.userInfo?["power"] as? Float else { return }
            MainActor.assumeIsolated { self?.hud.setLevel(power) }
        })
        observers.append(center.addObserver(forName: .crowStreamingSpeechError, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["id"] as? String == sessionID else { return }
            NSLog("Crow dictation recognition error: \(note.userInfo?["message"] as? String ?? "")")
            // Keep whatever live text there is; the final pass failed.
            MainActor.assumeIsolated { self?.finalized() }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func received(_ text: String, isFinal: Bool) {
        transcript = text
        if phase == .recording {
            hud.show(Self.tail(text), level: nil)
        } else if phase == .finishing, isFinal {
            finalized()
        }
    }

    private func finish() {
        guard phase == .recording, let session else { return }
        phase = .finishing
        hud.show(L("Tidying up…"), level: nil)
        if session.keepsSessionAliveAfterInputStop {
            // The recognizer uploads the recording and posts the final transcript.
            session.stopInput()
            let timeout = DispatchWorkItem { [weak self] in self?.finalized() }
            finalTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.finalized() }
        }
    }

    /// Runs once per dictation, on the final transcript, an error or the timeout.
    private func finalized() {
        guard phase == .finishing else { return }
        finalTimeout?.cancel()
        finalTimeout = nil
        session?.stop(cancel: true)
        session = nil
        removeObservers()
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            phase = .idle
            hud.flash(L("Didn't catch that."))
            return
        }
        let appName = targetApp?.localizedName ?? ""
        Task { @MainActor in
            let text = await polish?(raw, appName) ?? raw
            await insert(text.isEmpty ? raw : text)
            phase = .idle
        }
    }

    // MARK: Typing

    private func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Synthetic keys need Accessibility, and macOS drops them while secure input
        // (a password field) is on. Leave the text on the clipboard instead.
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            hud.flash(L("Copied. Press ⌘V to paste."))
            return
        }
        if let targetApp, targetApp != NSWorkspace.shared.frontmostApplication {
            targetApp.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await Self.waitForModifierRelease()
        Self.pressPaste()
        hud.hide()
        // Give the app time to read the clipboard before restoring it.
        try? await Task.sleep(nanoseconds: 600_000_000)
        if pasteboard.string(forType: .string) == text {
            Self.restore(saved, to: pasteboard)
        }
    }

    /// The shortcut's modifiers may still be held after a hold-to-talk release;
    /// ⌘V must not arrive as ⌃⌥⌘V.
    private static func waitForModifierRelease() async {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        for _ in 0..<40 where !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func pressPaste() {
        let key = CrowComputerUseHost.layoutKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                data[type] = item.data(forType: type)
            }
            return data
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data {
                item.setData(value, forType: type)
            }
            return item
        })
    }

    private static func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 28 ? "…" + trimmed.suffix(28) : trimmed
    }
}

/// A small pill at the bottom of the screen showing dictation progress. It never
/// takes focus or clicks, so typing still goes to the app in front.
@MainActor
final class CrowDictationHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, level: Float?) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        if let level { setLevel(level) }
        position(panel)
        panel.orderFrontRegardless()
    }

    func flash(_ text: String) {
        show(text, level: nil)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    /// `power` is in decibels, about -60 (silence) to 0.
    func setLevel(_ power: Float) {
        let level = CGFloat(max(0, min(1, (power + 55) / 40)))
        dot.layer?.opacity = Float(0.35 + 0.65 * level)
        dot.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.7 + 0.5 * level, y: 0.7 + 0.5 * level))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .hudWindow
        background.appearance = NSAppearance(named: .vibrantDark)
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(background)

        dot.frame = NSRect(x: 16, y: 14, width: 12, height: 12)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        dot.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dot.layer?.position = CGPoint(x: 22, y: 20)
        background.addSubview(dot)

        label.frame = NSRect(x: 38, y: 11, width: 268, height: 18)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        background.addSubview(label)

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 48))
    }
}
