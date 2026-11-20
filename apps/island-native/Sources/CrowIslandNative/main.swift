import AppKit
import AVFoundation
import Carbon
import CRNNoise
import Foundation
import Speech

struct IslandState: Codable, Equatable {
    var status: String
    var title: String
    var message: String
    var kind: String
    var phase: String?
    var action: String?
    var detail: String?
    var executor: String?
    var pendingApprovals: Int
    var approvalId: String?
    var approvalTitle: String?
    var approvalAction: String?
    var approvalPreview: String?
    var approvalRisk: Int?
    var updatedAt: String

    static let idle = IslandState(
        status: "idle",
        title: "Crow",
        message: "Waiting for your next task.",
        kind: "assistant",
        phase: "idle",
        action: "Waiting",
        detail: "Ready for your next command.",
        executor: nil,
        pendingApprovals: 0,
        approvalId: nil,
        approvalTitle: nil,
        approvalAction: nil,
        approvalPreview: nil,
        approvalRisk: nil,
        updatedAt: ""
    )
}

struct IslandAction: Codable {
    let id: String
    let type: String
    let approvalId: String
    let createdAt: String
}

struct VoiceCommand: Codable {
    let id: String
    let text: String
    let source: String
    let createdAt: String
    let audioPath: String?
}

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}

enum CrowEnvironment {
    static func value(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        if let value = runtimeSettingsValue(key), !value.isEmpty {
            return value
        }
        return dotEnvValues[key]
    }

    private static let dotEnvValues: [String: String] = {
        for url in candidateEnvURLs() {
            if let values = parseEnvFile(url), !values.isEmpty {
                return values
            }
        }
        return [:]
    }()

    private static func candidateEnvURLs() -> [URL] {
        var urls: [URL] = []
        if let bundlePath = Bundle.main.bundleURL.path.removingPercentEncoding {
            let bundleURL = URL(fileURLWithPath: bundlePath)
            urls.append(
                bundleURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(".env")
            )
        }
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"))
        return urls
    }

    private static func parseEnvFile(_ url: URL) -> [String: String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var values: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = stripQuotes(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            values[key] = value
        }
        return values
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }
        if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func runtimeSettingsValue(_ key: String) -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = support
            .appendingPathComponent("Crow", isDirectory: true)
            .appendingPathComponent("runtime-settings.json")
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return values[key]
    }
}

enum CrowPermissionBridge {
    static func requestSpeech(_ completion: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status)
        }
    }

    static func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }
}

private final class CrowRNNoiseDenoiser {
    private let processor: OpaquePointer
    private let frameSize: Int
    private var pendingInput: [Float] = []
    private let pcmScale: Float = 32768

    init?() {
        guard let processor = crow_rnnoise_create() else {
            return nil
        }
        self.processor = processor
        self.frameSize = Int(crow_rnnoise_frame_size())
        self.pendingInput.reserveCapacity(frameSize * 2)
    }

    deinit {
        crow_rnnoise_destroy(processor)
    }

    static func isSupported(format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32
            && format.channelCount == 1
            && abs(format.sampleRate - 48_000) < 1
            && !format.isInterleaved
    }

    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard Self.isSupported(format: buffer.format),
              let inputChannels = buffer.floatChannelData,
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: AVAudioFrameCount(Int(buffer.frameLength) + frameSize)
              ),
              let outputChannels = outputBuffer.floatChannelData else {
            return nil
        }

        let input = inputChannels[0]
        let inputCount = Int(buffer.frameLength)
        guard inputCount > 0 else {
            return nil
        }

        pendingInput.reserveCapacity(pendingInput.count + inputCount)
        for index in 0..<inputCount {
            pendingInput.append(input[index] * pcmScale)
        }

        var denoisedSamples: [Float] = []
        denoisedSamples.reserveCapacity(inputCount)
        while pendingInput.count >= frameSize {
            let frame = Array(pendingInput.prefix(frameSize))
            pendingInput.removeFirst(frameSize)
            var denoisedFrame = [Float](repeating: 0, count: frameSize)

            frame.withUnsafeBufferPointer { inputPointer in
                denoisedFrame.withUnsafeMutableBufferPointer { outputPointer in
                    _ = crow_rnnoise_process_frame(processor, outputPointer.baseAddress, inputPointer.baseAddress)
                }
            }

            for sample in denoisedFrame {
                denoisedSamples.append(sample / pcmScale)
            }
        }

        guard !denoisedSamples.isEmpty else {
            return nil
        }

        outputBuffer.frameLength = AVAudioFrameCount(denoisedSamples.count)
        let output = outputChannels[0]
        for index in 0..<denoisedSamples.count {
            output[index] = denoisedSamples[index]
        }
        return outputBuffer
    }
}

final class CrowStreamingSpeechSession {
    let id = UUID().uuidString

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(localeIdentifier: String) throws {
        stop(cancel: true)

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw NSError(domain: "CrowStreamingSpeechSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognizer is unavailable"
            ])
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        let sessionID = id
        let rnnoiseEnabled = (CrowEnvironment.value("CROW_RNNOISE_ENABLED") ?? "true").lowercased() != "false"
        let denoiser = rnnoiseEnabled && CrowRNNoiseDenoiser.isSupported(format: format)
            ? CrowRNNoiseDenoiser()
            : nil
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let speechBuffer: AVAudioPCMBuffer
            if let denoiser {
                guard let denoisedBuffer = denoiser.process(buffer) else {
                    return
                }
                speechBuffer = denoisedBuffer
            } else {
                speechBuffer = buffer
            }
            request.append(speechBuffer)
            let power = Self.averagePower(from: speechBuffer)
            CrowStreamingEventPoster.postLevel(sessionID: sessionID, power: power)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                CrowStreamingEventPoster.postTranscript(sessionID: sessionID, text: text, isFinal: isFinal)
            }
            if let error {
                CrowStreamingEventPoster.postError(sessionID: sessionID, message: error.localizedDescription)
            }
        }

        engine.prepare()
        try engine.start()

        audioEngine = engine
        recognitionRequest = request
    }

    func stopInput() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        recognitionRequest?.endAudio()
    }

    func stop(cancel: Bool) {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        if cancel {
            recognitionTask?.cancel()
        } else {
            recognitionRequest?.endAudio()
        }
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
    }

    private static func averagePower(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return -60
        }
        let channel = channelData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return -60
        }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        return 20 * log10(max(rms, 0.000_001))
    }
}

enum CrowStreamingEventPoster {
    static func postLevel(sessionID: String, power: Float) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .crowStreamingSpeechLevel, object: nil, userInfo: [
                "id": sessionID,
                "power": power
            ])
        }
    }

    static func postTranscript(sessionID: String, text: String, isFinal: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .crowStreamingSpeechTranscript, object: nil, userInfo: [
                "id": sessionID,
                "text": text,
                "isFinal": isFinal
            ])
        }
    }

    static func postError(sessionID: String, message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .crowStreamingSpeechError, object: nil, userInfo: [
                "id": sessionID,
                "message": message
            ])
        }
    }
}

extension Notification.Name {
    static let crowStreamingSpeechLevel = Notification.Name("dev.crow.streamingSpeech.level")
    static let crowStreamingSpeechTranscript = Notification.Name("dev.crow.streamingSpeech.transcript")
    static let crowStreamingSpeechError = Notification.Name("dev.crow.streamingSpeech.error")
    static let crowVoiceInputStarted = Notification.Name("dev.crow.voiceInput.started")
}

@MainActor
final class CrowHotKeyCenter {
    static let shared = CrowHotKeyCenter()

    var onWake: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        guard hotKeyRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr, hotKeyID.signature == fourCharCode("CROW"), hotKeyID.id == 1 {
                Task { @MainActor in
                    CrowHotKeyCenter.shared.triggerWake()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)

        let hotKey = CrowHotKey.fromEnvironment()
        let hotKeyID = EventHotKeyID(signature: fourCharCode("CROW"), id: 1)
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("Crow Island failed to register hotkey: \(status)")
        }
    }

    private func triggerWake() {
        onWake?()
    }
}

struct CrowHotKey {
    let keyCode: UInt32
    let modifiers: UInt32

    static func fromEnvironment() -> CrowHotKey {
        let raw = CrowEnvironment.value("CROW_ISLAND_HOTKEY") ?? "ctrl+option+space"
        let parts = raw
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var modifiers: UInt32 = 0
        var keyCode = UInt32(kVK_Space)

        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers |= UInt32(cmdKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            case "opt", "option", "alt":
                modifiers |= UInt32(optionKey)
            case "space":
                keyCode = UInt32(kVK_Space)
            default:
                continue
            }
        }

        return CrowHotKey(keyCode: keyCode, modifiers: modifiers)
    }
}

@MainActor
final class CrowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CrowIslandController: NSObject, NSApplicationDelegate, AVSpeechSynthesizerDelegate {
    private var panelWidth: CGFloat = 640
    private var panelHeight: CGFloat = 210
    private var panel: CrowPanel!
    private var islandView: CrowIslandView!
    private var stateTimer: Timer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var lastSpeechKey = ""
    private var voiceInputObserver: NSObjectProtocol?
    private var speechVisualHideWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CrowEnvironment.value("CROW_ISLAND_LIST_SCREENS") == "1" {
            printScreens()
            NSApp.terminate(nil)
            return
        }
        createPanel()
        speechSynthesizer.delegate = self
        CrowHotKeyCenter.shared.onWake = { [weak islandView] in
            islandView?.wakeFromShortcut()
        }
        CrowHotKeyCenter.shared.register()
        voiceInputObserver = NotificationCenter.default.addObserver(
            forName: .crowVoiceInputStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopSpeechOutput()
            }
        }
        startPollingState()
    }

    private func createPanel() {
        let screen = selectTargetScreen()
        let metrics = IslandGeometry.metrics(for: screen)
        panelWidth = metrics.windowSize.width
        panelHeight = metrics.windowSize.height
        let screenFrame = screen.frame
        let origin = NSPoint(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.maxY - panelHeight
        )

        panel = CrowPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        islandView = CrowIslandView(
            frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            geometry: metrics
        )
        panel.contentView = islandView
        panel.orderFrontRegardless()
    }

    private func selectTargetScreen() -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return NSScreen.main ?? NSScreen()
        }

        let target = CrowEnvironment.value("CROW_ISLAND_SCREEN")?.lowercased() ?? "builtin"

        if target == "mouse" {
            return screenContainingMouse() ?? builtinScreen(from: screens) ?? NSScreen.main ?? screens[0]
        }

        if target == "main" {
            return NSScreen.main ?? screens[0]
        }

        if let index = Int(target), screens.indices.contains(index) {
            return screens[index]
        }

        return builtinScreen(from: screens) ?? NSScreen.main ?? screens[0]
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouse)
        }
    }

    private func builtinScreen(from screens: [NSScreen]) -> NSScreen? {
        if let notched = screens.first(where: { $0.isNotchedDisplay }) {
            return notched
        }
        return screens.first { screen in
            guard let displayID = screen.displayID else {
                return false
            }
            return CGDisplayIsBuiltin(displayID) != 0
        }
    }

    private func printScreens() {
        for (index, screen) in NSScreen.screens.enumerated() {
            let displayID = screen.displayID ?? 0
            let builtin = CGDisplayIsBuiltin(displayID) != 0
            let main = screen == NSScreen.main
            print("screen[\(index)] frame=\(screen.frame) visible=\(screen.visibleFrame) safeArea=\(screen.safeAreaInsets) notchSize=\(screen.notchSize) builtin=\(builtin) main=\(main) displayID=\(displayID)")
        }
    }

    private func startPollingState() {
        loadState(shouldSpeak: false)
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadState(shouldSpeak: true)
            }
        }
    }

    private func loadState(shouldSpeak: Bool) {
        let nextState = readState()
        islandView.updateRuntimeState(nextState)
        handleSpeechOutput(for: nextState, shouldSpeak: shouldSpeak)
    }

    private func readState() -> IslandState {
        let path = CrowEnvironment.value("CROW_ISLAND_STATE_PATH")
            ?? defaultStatePath()
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(IslandState.self, from: data) else {
            return IslandState.idle
        }
        return state
    }

    private func defaultStatePath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support?
            .appendingPathComponent("Crow", isDirectory: true)
            .appendingPathComponent("island-state.json")
            .path ?? "~/Library/Application Support/Crow/island-state.json"
    }

    private func handleSpeechOutput(for state: IslandState, shouldSpeak: Bool) {
        guard let speech = speechOutput(for: state) else {
            return
        }

        let key = [
            state.status,
            state.phase ?? "",
            state.updatedAt,
            speech
        ].joined(separator: "|")
        if key == lastSpeechKey {
            return
        }
        lastSpeechKey = key

        guard shouldSpeak else {
            return
        }
        speak(speech)
    }

    private func speechOutput(for state: IslandState) -> String? {
        let phase = (state.phase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case "speaking":
            return compactSpeechText(state.message)
        case "completed":
            if ttsStreamingEnabled(), state.title == "Codex conclusion" {
                return nil
            }
            return localizedSpeech(prefixZH: "任务完成。", prefixEN: "Task complete. ", body: state.message)
        case "failed":
            return localizedSpeech(prefixZH: "任务失败，需要你查看。", prefixEN: "Task failed and needs your review. ", body: humanReadableFailure(state.message))
        case "approval":
            return localizedSpeech(prefixZH: "需要你的确认。", prefixEN: "Approval required. ", body: state.message)
        default:
            return nil
        }
    }

    private func ttsStreamingEnabled() -> Bool {
        let raw = (CrowEnvironment.value("CROW_TTS_STREAMING") ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw.isEmpty || raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    private func localizedSpeech(prefixZH: String, prefixEN: String, body: String) -> String {
        let locale = CrowIslandView.speechLocaleIdentifier().lowercased()
        let prefix = locale.hasPrefix("zh") ? prefixZH : prefixEN
        let cleanedBody = compactSpeechText(body)
        if cleanedBody.isEmpty {
            return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix + cleanedBody
    }

    private func compactSpeechText(_ value: String) -> String {
        var text = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        if text.count > 180 {
            text = String(text.prefix(180)) + "..."
        }
        return text
    }

    private func humanReadableFailure(_ value: String) -> String {
        let text = compactSpeechText(value)
        if text.contains("stream disconnected") || text.contains("idle timeout") {
            return CrowIslandView.speechLocaleIdentifier().lowercased().hasPrefix("zh")
                ? "Codex 连接超时。"
                : "Codex connection timed out."
        }
        if text.hasPrefix("map[") {
            return CrowIslandView.speechLocaleIdentifier().lowercased().hasPrefix("zh")
                ? "执行器返回了错误。"
                : "The executor returned an error."
        }
        return text
    }

    private func speak(_ text: String) {
        let provider = (CrowEnvironment.value("CROW_TTS_PROVIDER") ?? "system")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard provider != "off" else {
            return
        }

        stopSpeechOutput()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = speechVoice()
        islandView.isSpeaking = true
        scheduleSpeechVisualHide(for: text)
        speechSynthesizer.speak(utterance)
    }

    private func stopSpeechOutput() {
        speechVisualHideWorkItem?.cancel()
        speechVisualHideWorkItem = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        islandView.isSpeaking = false
    }

    private func scheduleSpeechVisualHide(for text: String) {
        speechVisualHideWorkItem?.cancel()
        let estimated = max(2.2, min(10.0, Double(text.count) / 7.0 + 1.2))
        let item = DispatchWorkItem { [weak self] in
            self?.islandView.isSpeaking = false
        }
        speechVisualHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + estimated, execute: item)
    }

    private func speechVoice() -> AVSpeechSynthesisVoice? {
        let configured = (CrowEnvironment.value("CROW_TTS_VOICE") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            if let byIdentifier = AVSpeechSynthesisVoice(identifier: configured) {
                return byIdentifier
            }
            if let byName = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name.caseInsensitiveCompare(configured) == .orderedSame }) {
                return byName
            }
        }
        return AVSpeechSynthesisVoice(language: CrowIslandView.speechLocaleIdentifier())
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speechVisualHideWorkItem?.cancel()
            self.speechVisualHideWorkItem = nil
            self.islandView.isSpeaking = false
            self.islandView.noteSpeechPlaybackEnded()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speechVisualHideWorkItem?.cancel()
            self.speechVisualHideWorkItem = nil
            self.islandView.isSpeaking = false
            self.islandView.noteSpeechPlaybackEnded()
        }
    }
}

struct IslandGeometry {
    let windowSize: NSSize
    let closedHeight: CGFloat
    let notchWidth: CGFloat
    let isNotchedDisplay: Bool

    static func metrics(for screen: NSScreen) -> IslandGeometry {
        let isNotched = screen.isNotchedDisplay
        let notchSize = screen.notchSize
        let closedHeight = screen.islandClosedHeight
        let openedWidth = min(max(notchSize.width + 260, 430), screen.frame.width - 96)
        let voiceHeight: CGFloat = 98
        let shadowBottom: CGFloat = 14

        return IslandGeometry(
            windowSize: NSSize(width: openedWidth, height: voiceHeight + shadowBottom),
            closedHeight: closedHeight,
            notchWidth: notchSize.width,
            isNotchedDisplay: isNotched
        )
    }
}

enum IslandVisualState {
    case idle
    case listening
    case speaking
    case thinking
    case running
    case approval
    case failed
}

@MainActor
final class CrowIslandView: NSView {
    private let geometry: IslandGeometry

    var state: IslandState = .idle {
        didSet {
            if oldValue != state {
                needsDisplay = true
            }
        }
    }

    var isSpeaking = false {
        didSet {
            if oldValue != isSpeaking {
                needsDisplay = true
            }
        }
    }

    private var phase: CGFloat = 0
    private var isExpanded = false
    private var isAwake = false
    private var proximity: CGFloat = 0
    private var hoverScale: CGFloat = 1
    private var isRecording = false
    private var isTranscribing = false
    private var isFinishingVoiceCapture = false
    private var isAwaitingVoiceConfirmation = false
    private var didSubmitVoiceCommand = false
    private var voiceTranscript = ""
    private var voiceAgentText = ""
    private var voiceAgentPhase = ""
    private var voiceHint = "Tap to stop. Auto-creates after silence."
    private var inputLevel: CGFloat = 0
    private var silentSince: Date?
    private var noiseFloorPower: Float = -58
    private var speechPeakPower: Float = -58
    private var lastSpeechActivityAt: Date?
    private var lastTranscriptUpdateAt: Date?
    private var autoCloseWorkItem: DispatchWorkItem?
    private var captureStartedAt: Date?
    private var voiceSubmittedAt: Date?
    private var streamingSession: CrowStreamingSpeechSession?
    private var streamingObserverTokens: [NSObjectProtocol] = []
    private var animationTimer: Timer?
    private var trackingArea: NSTrackingArea?

    private var visualState: IslandVisualState {
        if isExpanded {
            if didSubmitVoiceCommand {
                switch voiceAgentPhase {
                case "speaking":
                    return .speaking
                case "responding":
                    return .thinking
                case "failed":
                    return .failed
                case "approval":
                    return .approval
                default:
                    return .running
                }
            }
            return .listening
        }
        if isSpeaking {
            return .speaking
        }
        switch executionPhase {
        case "approval":
            return .approval
        case "failed":
            return .failed
        case "thinking", "planning", "responding", "tool", "starting", "running":
            return .running
        default:
            return proximity > 0 ? .idle : .idle
        }
    }

    private var executionPhase: String {
        let phase = (state.phase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !phase.isEmpty {
            return phase
        }
        switch state.status {
        case "waiting_approval":
            return "approval"
        case "completed":
            return "completed"
        case "failed", "cancelled":
            return "failed"
        case "running":
            return "running"
        default:
            return "idle"
        }
    }

    init(frame frameRect: NSRect, geometry: IslandGeometry) {
        self.geometry = geometry
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        startAnimation()
    }

    required init?(coder: NSCoder) {
        self.geometry = IslandGeometry(
            windowSize: NSSize(width: 640, height: 210),
            closedHeight: 38,
            notchWidth: 190,
            isNotchedDisplay: false
        )
        super.init(coder: coder)
        startAnimation()
    }

    static func speechLocaleIdentifier() -> String {
        let raw = CrowEnvironment.value("CROW_STT_LANGUAGE")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch raw {
        case "zh", "cn", "zh-cn":
            return "zh-CN"
        case "zh-tw":
            return "zh-TW"
        case "en", "en-us":
            return "en-US"
        default:
            return raw.isEmpty ? Locale.current.identifier : raw
        }
    }

    func updateRuntimeState(_ nextState: IslandState) {
        state = nextState
        updateVoiceConversation(from: nextState)
    }

    func noteSpeechPlaybackEnded() {
        guard isExpanded, didSubmitVoiceCommand, !voiceAgentText.isEmpty else {
            return
        }
        if voiceAgentPhase == "completed" || voiceAgentPhase == "speaking" {
            scheduleAutoClose(delay: Self.voiceConversationIdleCloseDelay())
        }
    }

    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.phase += 0.18
                self.updateProximityFromMouse()
                let targetScale: CGFloat = 1 + self.proximity * 0.07
                self.hoverScale += (targetScale - self.hoverScale) * 0.28
                self.needsDisplay = true
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextArea
        addTrackingArea(nextArea)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if interactiveRect.contains(point) || approvalPanelRect.contains(point) || approvalApproveButtonRect.contains(point) || approvalRejectButtonRect.contains(point) {
            return self
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        if isExpanded {
            drawVoicePanel()
        } else if executionPhase == "approval" {
            drawApprovalPanel()
        } else if shouldShowCompactBar {
            drawBar()
        }
    }

    private var shouldShowCompactBar: Bool {
        if isAwake || isSpeaking || proximity > 0.72 {
            return true
        }
        switch executionPhase {
        case "approval":
            return true
        case "speaking", "thinking", "planning", "responding", "tool", "starting", "running":
            return stateAge() <= Self.compactBarIdleHideDelay()
        default:
            return false
        }
    }

    private func stateAge() -> TimeInterval {
        guard let updatedAt = parseStateUpdatedAt(state.updatedAt) else {
            return .greatestFiniteMagnitude
        }
        return max(0, Date().timeIntervalSince(updatedAt))
    }

    private func parseStateUpdatedAt(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return nil
        }

        let isoWithColon = ISO8601DateFormatter()
        isoWithColon.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithColon.date(from: text) {
            return date
        }

        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]
        if let date = isoNoFraction.date(from: text) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: text)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if executionPhase == "approval" {
            if approvalApproveButtonRect.contains(point) {
                submitApprovalAction(type: "approval.approve")
                return
            }
            if approvalRejectButtonRect.contains(point) {
                submitApprovalAction(type: "approval.reject")
                return
            }
            if approvalPanelRect.contains(point) {
                openCrowMainApp()
                return
            }
        }
        if !isExpanded, wakeHitRect.contains(point) {
            wakeVoicePanel()
            return
        }
        if isExpanded, voicePanelRect.contains(point) {
            if isRecording {
                finishVoiceCapture()
            } else if isAwaitingVoiceConfirmation {
                confirmVoiceCommand()
            } else {
                closeVoicePanel()
            }
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isExpanded {
            closeVoicePanel()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverState(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverState(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        proximity = 0
    }

    private func updateHoverState(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        proximity = proximityValue(for: point)
    }

    func wakeFromShortcut() {
        if isExpanded {
            if isRecording {
                finishVoiceCapture()
            } else if isAwaitingVoiceConfirmation {
                confirmVoiceCommand()
            }
            return
        }
        wakeVoicePanel()
    }

    private func wakeVoicePanel() {
        cancelAutoClose()
        isAwake = true
        isExpanded = true
        proximity = 1
        beginVoiceCapture()
        needsDisplay = true
    }

    private func updateProximityFromMouse() {
        guard let window else {
            proximity = 0
            return
        }
        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let mouseInView = convert(mouseInWindow, from: nil)
        proximity = proximityValue(for: mouseInView)
    }

    private func proximityValue(for point: NSPoint) -> CGFloat {
        if proximityRect.contains(point) {
            let target = baseBarRect
            let dx = max(target.minX - point.x, point.x - target.maxX, 0)
            let dy = max(target.minY - point.y, point.y - target.maxY, 0)
            let distance = sqrt(dx * dx + dy * dy)
            return max(0, min(1, 1 - distance / 18))
        }
        return 0
    }

    private func beginVoiceCapture() {
        guard !isRecording && !isTranscribing else {
            return
        }
        NotificationCenter.default.post(name: .crowVoiceInputStarted, object: nil)
        voiceTranscript = ""
        voiceHint = "Requesting speech access..."
        isAwaitingVoiceConfirmation = false
        didSubmitVoiceCommand = false
        voiceSubmittedAt = nil
        voiceAgentText = ""
        voiceAgentPhase = ""
        needsDisplay = true

        CrowPermissionBridge.requestSpeech { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.voiceHint = "Speech recognition denied. No task will be created."
                    self.needsDisplay = true
                    return
                }

                self.voiceHint = "Requesting microphone access..."
                self.needsDisplay = true
                CrowPermissionBridge.requestMicrophone { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if granted {
                            self.startStreamingRecognition()
                        } else {
                            self.voiceHint = "Microphone access denied. No task will be created."
                            self.needsDisplay = true
                        }
                    }
                }
            }
        }
    }

    private func startStreamingRecognition() {
        cancelAutoClose()
        stopStreamingRecognition(cancel: true)

        let session = CrowStreamingSpeechSession()
        installStreamingObservers(for: session.id)

        do {
            try session.start(localeIdentifier: Self.speechLocaleIdentifier())
            streamingSession = session
            isRecording = true
            isTranscribing = false
            captureStartedAt = Date()
            silentSince = nil
            noiseFloorPower = -58
            speechPeakPower = -58
            lastSpeechActivityAt = nil
            lastTranscriptUpdateAt = nil
            inputLevel = 0
            voiceHint = "Listening..."
            needsDisplay = true
        } catch {
            stopStreamingRecognition(cancel: true)
            voiceHint = "Audio engine failed. No task will be created."
            NSLog("Crow Island failed to start streaming recognition: \(error.localizedDescription)")
            needsDisplay = true
        }
    }

    private func finishVoiceCapture() {
        if isTranscribing || isFinishingVoiceCapture {
            return
        }

        if isRecording {
            isFinishingVoiceCapture = true
            streamingSession?.stop(cancel: true)
            streamingSession = nil
            removeStreamingObservers()
            isRecording = false
            isTranscribing = true
            voiceHint = "Finalizing transcript..."
            needsDisplay = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                self.submitCurrentTranscript()
            }
            return
        }

        voiceHint = missingTranscriptMessage()
        closeVoicePanel()
    }

    private func closeVoicePanel() {
        cancelAutoClose()
        stopStreamingRecognition(cancel: true)
        isExpanded = false
        isAwake = false
        isRecording = false
        isTranscribing = false
        isFinishingVoiceCapture = false
        isAwaitingVoiceConfirmation = false
        didSubmitVoiceCommand = false
        voiceTranscript = ""
        voiceAgentText = ""
        voiceAgentPhase = ""
        voiceHint = "Tap to stop. Auto-creates after silence."
        inputLevel = 0
        silentSince = nil
        noiseFloorPower = -58
        speechPeakPower = -58
        lastSpeechActivityAt = nil
        lastTranscriptUpdateAt = nil
        captureStartedAt = nil
        voiceSubmittedAt = nil
        needsDisplay = true
    }

    private func stopStreamingInput() {
        streamingSession?.stopInput()
    }

    private func stopStreamingRecognition(cancel: Bool) {
        streamingSession?.stop(cancel: cancel)
        streamingSession = nil
        removeStreamingObservers()
    }

    private func installStreamingObservers(for sessionID: String) {
        removeStreamingObservers()
        let center = NotificationCenter.default

        let levelToken = center.addObserver(forName: .crowStreamingSpeechLevel, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  notification.userInfo?["id"] as? String == sessionID,
                  let power = notification.userInfo?["power"] as? Float else {
                return
            }
            Task { @MainActor in
                self.updateAudioMeter(power: power)
            }
        }

        let transcriptToken = center.addObserver(forName: .crowStreamingSpeechTranscript, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  notification.userInfo?["id"] as? String == sessionID,
                  let text = notification.userInfo?["text"] as? String else {
                return
            }
            let isFinal = notification.userInfo?["isFinal"] as? Bool ?? false
            Task { @MainActor in
                if text != self.voiceTranscript {
                    self.lastTranscriptUpdateAt = Date()
                    self.lastSpeechActivityAt = Date()
                    self.silentSince = nil
                }
                self.voiceTranscript = text
                self.voiceHint = isFinal ? "Final transcript ready." : "Listening..."
                self.needsDisplay = true
            }
        }

        let errorToken = center.addObserver(forName: .crowStreamingSpeechError, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  notification.userInfo?["id"] as? String == sessionID else {
                return
            }
            Task { @MainActor in
                if self.voiceTranscript.isEmpty {
                    self.voiceHint = "Speech recognition failed. No task will be created."
                    self.needsDisplay = true
                }
            }
        }

        streamingObserverTokens = [levelToken, transcriptToken, errorToken]
    }

    private func removeStreamingObservers() {
        let center = NotificationCenter.default
        for token in streamingObserverTokens {
            center.removeObserver(token)
        }
        streamingObserverTokens = []
    }

    private func submitCurrentTranscript() {
        let cleaned = voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            voiceHint = missingTranscriptMessage()
            scheduleAutoClose()
        } else {
            submitVoiceCommand(text: cleaned, audioURL: nil)
            didSubmitVoiceCommand = true
            isAwaitingVoiceConfirmation = false
            voiceSubmittedAt = Date()
            voiceAgentText = ""
            voiceAgentPhase = "waiting"
            voiceHint = "Waiting for Crow..."
            scheduleAutoClose(delay: Self.voiceConversationNoResponseCloseDelay())
        }
        isTranscribing = false
        isFinishingVoiceCapture = false
        inputLevel = 0
        needsDisplay = true
    }

    private func confirmVoiceCommand() {
        guard isAwaitingVoiceConfirmation, !didSubmitVoiceCommand else {
            return
        }
        let cleaned = voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            voiceHint = missingTranscriptMessage()
            isAwaitingVoiceConfirmation = false
            needsDisplay = true
            scheduleAutoClose()
            return
        }
        submitVoiceCommand(text: cleaned, audioURL: nil)
        didSubmitVoiceCommand = true
        isAwaitingVoiceConfirmation = false
        voiceSubmittedAt = Date()
        voiceAgentText = ""
        voiceAgentPhase = "waiting"
        voiceHint = "Waiting for Crow..."
        inputLevel = 0
        needsDisplay = true
        scheduleAutoClose(delay: Self.voiceConversationNoResponseCloseDelay())
    }

    private func scheduleAutoClose(delay: TimeInterval? = nil) {
        cancelAutoClose()
        let delay = delay ?? Self.voicePanelIdleCloseDelay()
        guard delay > 0 else {
            return
        }
        let item = DispatchWorkItem { [weak self] in
            self?.closeVoicePanel()
        }
        autoCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelAutoClose() {
        autoCloseWorkItem?.cancel()
        autoCloseWorkItem = nil
    }

    private func updateVoiceConversation(from nextState: IslandState) {
        guard isExpanded, didSubmitVoiceCommand else {
            return
        }
        if let submittedAt = voiceSubmittedAt,
           let updatedAt = parseStateUpdatedAt(nextState.updatedAt),
           updatedAt < submittedAt.addingTimeInterval(-0.5) {
            return
        }

        let phase = effectivePhase(for: nextState)
        voiceAgentPhase = phase

        if shouldCollapseVoiceConversation(for: phase) {
            closeVoicePanel()
            return
        }

        guard shouldKeepVoiceConversationOpen(for: phase) else {
            return
        }

        cancelAutoClose()
        isAwake = true
        isExpanded = true
        let response = voiceResponseText(from: nextState, phase: phase)
        if !response.isEmpty {
            voiceAgentText = response
        }

        switch phase {
        case "speaking":
            voiceHint = "Crow is speaking"
        case "responding":
            voiceHint = "Crow is responding"
        case "completed":
            voiceHint = "Response complete"
            if !isSpeaking {
                scheduleAutoClose(delay: Self.voiceConversationIdleCloseDelay())
            }
        case "failed":
            voiceHint = "Needs review"
        case "approval":
            voiceHint = "Approval required"
        case "thinking":
            voiceHint = "Crow is thinking"
        case "planning":
            voiceHint = "Crow is planning"
        case "starting", "running":
            voiceHint = "Crow is working"
        default:
            voiceHint = "Waiting for Crow..."
        }
        needsDisplay = true
    }

    private func effectivePhase(for state: IslandState) -> String {
        let phase = (state.phase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !phase.isEmpty {
            return phase
        }
        switch state.status {
        case "waiting_approval":
            return "approval"
        case "completed":
            return "completed"
        case "failed", "cancelled":
            return "failed"
        case "running":
            return "running"
        default:
            return "idle"
        }
    }

    private func shouldKeepVoiceConversationOpen(for phase: String) -> Bool {
        switch phase {
        case "speaking", "responding", "completed", "failed", "approval", "thinking", "planning", "starting", "running":
            return true
        default:
            return false
        }
    }

    private func shouldCollapseVoiceConversation(for phase: String) -> Bool {
        switch phase {
        case "tool":
            return true
        default:
            return false
        }
    }

    private func voiceResponseText(from state: IslandState, phase: String) -> String {
        let message = state.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (state.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)

        switch phase {
        case "approval":
            return [title, detail.isEmpty ? message : detail]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        default:
            return !message.isEmpty ? message : title
        }
    }

    private func updateAudioMeter(power: Float) {
        guard isRecording, !isFinishingVoiceCapture else {
            inputLevel = 0
            return
        }

        inputLevel = normalizedAudioLevel(power)

        let elapsed = captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        updateNoiseModel(power: power, elapsed: elapsed)

        let hasTranscript = !voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let minimumDuration: TimeInterval = hasTranscript ? 1.0 : 2.2
        let silenceDuration: TimeInterval = hasTranscript ? 0.95 : 1.7
        let speechGate = max(noiseFloorPower + 9, -50)
        let releaseGate = max(noiseFloorPower + 4, min(speechPeakPower - 18, -43))
        let transcriptIdle = lastTranscriptUpdateAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let isLikelySpeech = power > speechGate

        if isLikelySpeech {
            lastSpeechActivityAt = Date()
            speechPeakPower = max(speechPeakPower, power)
            silentSince = nil
        } else if elapsed > minimumDuration, hasTranscript, transcriptIdle > 0.8, power < releaseGate {
            markPotentialSilence(duration: silenceDuration)
        } else if elapsed > minimumDuration, hasTranscript, transcriptIdle > 1.35 {
            markPotentialSilence(duration: silenceDuration + 0.25)
        } else {
            silentSince = nil
        }
        needsDisplay = true
    }

    private func updateNoiseModel(power: Float, elapsed: TimeInterval) {
        let hasTranscript = !voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let likelyBackground = !hasTranscript && (elapsed < 0.9 || power < noiseFloorPower + 5)
        if likelyBackground {
            noiseFloorPower = (noiseFloorPower * 0.88) + (power * 0.12)
        }
        if power > speechPeakPower {
            speechPeakPower = power
        }
    }

    private func markPotentialSilence(duration: TimeInterval) {
        if let silentSince {
            if Date().timeIntervalSince(silentSince) >= duration {
                finishVoiceCapture()
            }
        } else {
            silentSince = Date()
        }
    }

    private func normalizedAudioLevel(_ power: Float) -> CGFloat {
        let floor: Float = -60
        let clipped = max(floor, min(0, power))
        return CGFloat((clipped - floor) / abs(floor))
    }

    private func missingTranscriptMessage() -> String {
        "No transcript recognized. Tap to close."
    }

    static func voicePanelIdleCloseDelay() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_ISLAND_IDLE_CLOSE_SECONDS"),
              let value = TimeInterval(raw) else {
            return 8
        }
        return max(0, value)
    }

    static func voiceConversationIdleCloseDelay() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_ISLAND_VOICE_IDLE_CLOSE_SECONDS"),
              let value = TimeInterval(raw) else {
            return 12
        }
        return max(0, value)
    }

    static func voiceConversationNoResponseCloseDelay() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_ISLAND_VOICE_NO_RESPONSE_CLOSE_SECONDS"),
              let value = TimeInterval(raw) else {
            return 24
        }
        return max(0, value)
    }

    static func compactBarIdleHideDelay() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_ISLAND_COMPACT_IDLE_HIDE_SECONDS"),
              let value = TimeInterval(raw) else {
            return 6
        }
        return max(1, value)
    }

    private func submitVoiceCommand(text: String, audioURL: URL?) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return
        }
        let command = VoiceCommand(
            id: "voice_\(Int(Date().timeIntervalSince1970 * 1000))",
            text: cleaned,
            source: "native-island",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            audioPath: audioURL?.path
        )

        do {
            let directory = try crowApplicationSupportDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(command)
            let url = directory.appendingPathComponent("voice-command.json")
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("Crow Island failed to submit voice command: \(error.localizedDescription)")
        }
    }

    private func crowApplicationSupportDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "CrowIsland", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Application Support directory is unavailable"
            ])
        }
        return support.appendingPathComponent("Crow", isDirectory: true)
    }

    private var barRect: NSRect {
        let width = compactBarWidth
        let baseRect = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.height - geometry.closedHeight,
            width: width,
            height: geometry.closedHeight
        )
        return scale(rect: baseRect, by: hoverScale, anchorY: baseRect.maxY)
    }

    private var baseBarRect: NSRect {
        let width = compactBarWidth
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.height - geometry.closedHeight,
            width: width,
            height: geometry.closedHeight
        )
    }

    private var compactBarWidth: CGFloat {
        if isExpanded {
            return min(max(geometry.notchWidth + 220, 390), bounds.width - 40)
        }
        if executionPhase == "approval" {
            return min(max(geometry.notchWidth + 240, 420), bounds.width - 28)
        }
        return min(max(geometry.notchWidth + 72, 258), bounds.width - 72)
    }

    private var voicePanelRect: NSRect {
        let width = min(max(geometry.notchWidth + 230, 400), bounds.width - 28)
        let height = max(78, bounds.height - 14)
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    private var approvalPanelRect: NSRect {
        guard executionPhase == "approval" else {
            return .zero
        }
        let width = min(max(geometry.notchWidth + 330, 520), bounds.width - 18)
        let height = max(104, bounds.height - 8)
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    private var expandedRect: NSRect {
        NSRect(
            x: 18,
            y: bounds.height - expandedPanelHeight,
            width: bounds.width - 36,
            height: expandedPanelHeight
        )
    }

    private var expandedPanelHeight: CGFloat {
        max(196, bounds.height - 18)
    }

    private var hoverRect: NSRect {
        baseBarRect.insetBy(dx: -4, dy: -3)
    }

    private var proximityRect: NSRect {
        baseBarRect.insetBy(dx: -8, dy: -8)
    }

    private var interactiveRect: NSRect {
        if isExpanded {
            return voicePanelRect
        }
        if executionPhase == "approval" {
            return approvalPanelRect.insetBy(dx: -8, dy: -8)
        }
        return wakeHitRect
    }

    private var wakeHitRect: NSRect {
        baseBarRect.insetBy(dx: -8, dy: -8)
    }

    private func drawVoicePanel() {
        let rect = voicePanelRect
        shadow(color: NSColor.black.withAlphaComponent(0.24), blur: 22, offset: NSSize(width: 0, height: -12)) {
            let path = expandedPanelPath(rect: rect, radius: 20)
            NSColor(calibratedRed: 0.01, green: 0.012, blue: 0.014, alpha: 0.99).setFill()
            path.fill()
        }

        let headerY = rect.maxY - geometry.closedHeight
        drawStateIcon(in: NSRect(x: rect.minX + 24, y: headerY + 8, width: 16, height: 16), visualState: visualState)
        drawVoiceWaveform(in: NSRect(x: rect.maxX - 112, y: headerY + 7, width: 78, height: 22))

        drawText(voicePrimaryLine(), in: NSRect(x: rect.minX + 26, y: rect.minY + 26, width: rect.width - 52, height: 28), size: 13, weight: .medium, color: NSColor(calibratedWhite: 0.88, alpha: 1))
    }

    private func voiceTitle() -> String {
        if didSubmitVoiceCommand {
            switch voiceAgentPhase {
            case "speaking":
                return "Crow Speaking"
            case "responding":
                return "Crow Responding"
            case "completed":
                return "Crow"
            case "failed":
                return "Needs Review"
            case "approval":
                return "Approval Required"
            case "planning":
                return "Crow Planning"
            case "starting", "running", "thinking":
                return "Crow Thinking"
            default:
                return "Crow Thinking"
            }
        }
        if isAwaitingVoiceConfirmation {
            return "Confirm Task"
        }
        if didSubmitVoiceCommand {
            return "Task Created"
        }
        if isTranscribing {
            return "Transcribing"
        }
        if isRecording {
            return "Listening"
        }
        return "Voice"
    }

    private func voicePrimaryLine() -> String {
        let agentText = voiceAgentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if didSubmitVoiceCommand {
            if !agentText.isEmpty {
                return agentText
            }
            if !voiceTranscript.isEmpty {
                return "你：\(voiceTranscript)"
            }
            return "Crow 正在处理..."
        }
        if isAwaitingVoiceConfirmation, !voiceTranscript.isEmpty {
            return voiceTranscript
        }
        if didSubmitVoiceCommand, !voiceTranscript.isEmpty {
            return voiceTranscript
        }
        if !voiceTranscript.isEmpty {
            return voiceTranscript
        }
        if isTranscribing {
            return "正在整理输入..."
        }
        if isRecording {
            return "请说话"
        }
        return "等待语音输入"
    }

    private func voiceInlineText() -> String {
        let agentText = voiceAgentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if didSubmitVoiceCommand {
            if !agentText.isEmpty {
                return agentText
            }
            return voiceTitle()
        }
        let cleaned = voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned
        }
        if didSubmitVoiceCommand {
            return "已发送"
        }
        if isTranscribing {
            return "识别中"
        }
        if isRecording {
            return "正在听"
        }
        return voiceTitle()
    }

    private var centerControlsRect: NSRect {
        let rect = expandedRect
        let top = rect.maxY - geometry.closedHeight - 26
        return NSRect(x: rect.midX - 88, y: rect.minY + 48, width: 176, height: top - rect.minY - 48)
    }

    private var collapseButtonRect: NSRect {
        let rect = centerControlsRect
        let y = rect.midY - 8
        return NSRect(x: rect.midX - 64, y: y - 6, width: 36, height: 36)
    }

    private var openAppButtonRect: NSRect {
        let rect = centerControlsRect
        let y = rect.midY - 8
        return NSRect(x: rect.midX - 20, y: y - 8, width: 40, height: 40)
    }

    private var nextButtonRect: NSRect {
        let rect = centerControlsRect
        let y = rect.midY - 8
        return NSRect(x: rect.midX + 36, y: y - 6, width: 36, height: 36)
    }

    private var approvalApproveButtonRect: NSRect {
        guard executionPhase == "approval" else {
            return .zero
        }
        let rect = approvalPanelRect
        return NSRect(x: rect.maxX - 174, y: rect.minY + 18, width: 82, height: 30)
    }

    private var approvalRejectButtonRect: NSRect {
        guard executionPhase == "approval" else {
            return .zero
        }
        let rect = approvalPanelRect
        return NSRect(x: rect.maxX - 82, y: rect.minY + 18, width: 62, height: 30)
    }

    private func drawExpandedPanel() {
        let rect = expandedRect
        shadow(color: NSColor.black.withAlphaComponent(0.26), blur: 24, offset: NSSize(width: 0, height: -14)) {
            let path = expandedPanelPath(rect: rect, radius: 22)
            NSColor(calibratedRed: 0.012, green: 0.014, blue: 0.016, alpha: 0.985).setFill()
            path.fill()
        }
    }

    private func drawBar() {
        let rect = barRect
        let path = isExpanded
            ? NSBezierPath(rect: rect)
            : bottomRoundedPath(rect: rect, radius: min(16, rect.height / 2))
        NSColor(calibratedRed: 0.012, green: 0.014, blue: 0.016, alpha: 0.99).setFill()
        path.fill()

        let centerY = rect.midY
        drawStateIcon(in: NSRect(x: rect.minX + 22, y: centerY - 7, width: 14, height: 14), visualState: visualState)
        if isSpeaking {
            drawSpeakingActivity(in: NSRect(x: rect.maxX - 48, y: centerY - 9, width: 30, height: 18))
        } else {
            drawCompactActivity(in: NSRect(x: rect.maxX - 38, y: centerY - 7, width: 20, height: 14))
        }
    }

    private func drawApprovalPanel() {
        let rect = approvalPanelRect
        shadow(color: NSColor.black.withAlphaComponent(0.24), blur: 22, offset: NSSize(width: 0, height: -12)) {
            let path = expandedPanelPath(rect: rect, radius: 20)
            NSColor(calibratedRed: 0.012, green: 0.014, blue: 0.016, alpha: 0.992).setFill()
            path.fill()
        }

        let headerY = rect.maxY - geometry.closedHeight
        drawStateIcon(in: NSRect(x: rect.minX + 24, y: headerY + 8, width: 16, height: 16), visualState: .approval)
        drawApprovalPulse(in: NSRect(x: rect.minX + 52, y: headerY + 10, width: 54, height: 12))

        let contentRight = approvalApproveButtonRect.minX - 18
        drawText(approvalSummaryText(), in: NSRect(x: rect.minX + 26, y: rect.minY + 52, width: contentRight - rect.minX - 26, height: 20), size: 14, weight: .bold, color: .white)
        drawText(approvalDetailText(), in: NSRect(x: rect.minX + 26, y: rect.minY + 34, width: contentRight - rect.minX - 26, height: 16), size: 11, weight: .regular, color: NSColor(calibratedWhite: 0.7, alpha: 1))
        drawText("Open full details in Crow.", in: NSRect(x: rect.minX + 26, y: rect.minY + 17, width: contentRight - rect.minX - 26, height: 13), size: 10, weight: .regular, color: NSColor(calibratedWhite: 0.52, alpha: 1))
        drawApprovalButton("Approve", rect: approvalApproveButtonRect, primary: true)
        drawApprovalButton("Reject", rect: approvalRejectButtonRect, primary: false)
    }

    private func drawApprovalButton(_ title: String, rect: NSRect, primary: Bool) {
        let fill = primary ? accentColor() : NSColor.white.withAlphaComponent(0.08)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        let color = primary ? NSColor.black.withAlphaComponent(0.86) : NSColor.white.withAlphaComponent(0.82)
        drawCenteredText(title, in: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 15), size: 11, weight: .bold, color: color)
    }

    private func drawApprovalPulse(in rect: NSRect) {
        let dots = 5
        for index in 0..<dots {
            let wave = (sin(phase * 1.4 + CGFloat(index) * 0.6) + 1) / 2
            let size: CGFloat = 4 + wave * 3
            let x = rect.minX + CGFloat(index) * 10
            accentColor().withAlphaComponent(0.36 + wave * 0.54).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - size / 2, width: size, height: size)).fill()
        }
    }

    private func drawExpandedContent() {
        let rect = expandedRect
        let headerY = rect.maxY - geometry.closedHeight
        drawText("◆", in: NSRect(x: rect.midX - 210, y: headerY + 9, width: 18, height: 16), size: 10, weight: .bold, color: accentColor())
        drawText(barLabel(), in: NSRect(x: rect.midX - 166, y: headerY + 5, width: 280, height: 24), size: 14, weight: .semibold, color: .white)
        if isSpeaking {
            drawSpeakingActivity(in: NSRect(x: rect.midX + 184, y: headerY + 5, width: 46, height: 26))
        } else {
            drawEqualizer(in: NSRect(x: rect.midX + 190, y: headerY + 6, width: 34, height: 24))
        }

        let top = rect.maxY - geometry.closedHeight - 26
        let left = NSRect(x: rect.minX + 34, y: rect.minY + 46, width: 290, height: top - rect.minY - 46)
        let center = NSRect(x: rect.midX - 88, y: rect.minY + 48, width: 176, height: top - rect.minY - 48)
        let right = NSRect(x: rect.maxX - 250, y: rect.minY + 46, width: 216, height: top - rect.minY - 46)

        drawTaskPreview(in: left)
        drawExecutionControls(in: center)
        drawSideSummary(in: right)
        drawProgress(in: NSRect(x: rect.minX + 34, y: rect.minY + 24, width: rect.width - 68, height: 5))
    }

    private func drawTaskPreview(in rect: NSRect) {
        let thumb = NSRect(x: rect.minX, y: rect.maxY - 82, width: 74, height: 74)
        drawThumbnail(in: thumb)
        drawText(taskEyebrow(), in: NSRect(x: thumb.maxX + 16, y: rect.maxY - 24, width: rect.width - 90, height: 14), size: 10, weight: .bold, color: accentColor())
        drawText(primaryTaskText(), in: NSRect(x: thumb.maxX + 16, y: rect.maxY - 49, width: rect.width - 90, height: 22), size: 14, weight: .bold, color: .white)
        drawText(secondaryTaskText(), in: NSRect(x: thumb.maxX + 16, y: rect.maxY - 72, width: rect.width - 90, height: 20), size: 12, weight: .regular, color: NSColor(calibratedWhite: 0.72, alpha: 1))
    }

    private func drawExecutionControls(in rect: NSRect) {
        let y = rect.midY - 8
        drawControlButton("⌄", rect: collapseButtonRect, size: 18)
        drawControlButton("↗", rect: openAppButtonRect, size: 22)
        drawControlButton("▶", rect: nextButtonRect, size: 18)
        drawText(executionLabel(), in: NSRect(x: rect.minX, y: y + 42, width: rect.width, height: 18), size: 11, weight: .semibold, color: NSColor(calibratedWhite: 0.78, alpha: 1))
    }

    private func drawSideSummary(in rect: NSRect) {
        let pill = state.pendingApprovals > 0 ? "\(state.pendingApprovals) approval" : displayStatus()
        drawText(monthLabel(), in: NSRect(x: rect.minX, y: rect.maxY - 26, width: 90, height: 22), size: 18, weight: .semibold, color: .white)
        drawCalendarStrip(in: NSRect(x: rect.minX, y: rect.maxY - 64, width: rect.width, height: 32))
        drawStatusDot(at: NSPoint(x: rect.minX + 4, y: rect.minY + 40))
        drawText(pill, in: NSRect(x: rect.minX + 22, y: rect.minY + 32, width: rect.width - 26, height: 22), size: 12, weight: .semibold, color: NSColor(calibratedWhite: 0.86, alpha: 1))
        drawText(sideSummaryText(), in: NSRect(x: rect.minX, y: rect.minY + 10, width: rect.width, height: 18), size: 11, weight: .regular, color: NSColor(calibratedWhite: 0.66, alpha: 1))
    }

    private func drawEqualizer(in rect: NSRect) {
        let heights: [CGFloat] = [10, 18, 13]
        for index in 0..<3 {
            let wave = (sin(phase + CGFloat(index) * 0.8) + 1) / 2
            let height = heights[index] * (0.55 + wave * 0.45)
            let bar = NSRect(x: rect.minX + CGFloat(index) * 10, y: rect.midY - height / 2, width: 4, height: height)
            let path = NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2)
            accentColor().setFill()
            path.fill()
        }
    }

    private func drawCompactMark(in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.line(to: NSPoint(x: rect.midX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.midY))
        path.close()
        accentColor().setFill()
        path.fill()
    }

    private func drawStateIcon(in rect: NSRect, visualState: IslandVisualState) {
        switch visualState {
        case .listening:
            drawMicDot(in: rect)
        case .speaking:
            drawSpeakingIcon(in: rect)
        case .thinking:
            drawThinkingRing(in: rect)
        case .approval:
            drawApprovalIcon(in: rect)
        case .failed:
            drawFailureDot(in: rect)
        case .running:
            let pulse = 0.76 + ((sin(phase * 1.2) + 1) / 2) * 0.24
            let size = min(rect.width, rect.height) * pulse
            let scaled = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
            drawCompactMark(in: scaled)
        case .idle:
            let size = min(rect.width, rect.height) * 0.72
            let scaled = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
            drawCompactMark(in: scaled)
        }
    }

    private func drawMicDot(in rect: NSRect) {
        let stem = NSRect(x: rect.midX - 2, y: rect.minY + 2, width: 4, height: rect.height - 4)
        listeningColor().setFill()
        NSBezierPath(roundedRect: stem, xRadius: 2, yRadius: 2).fill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - 5, y: rect.maxY - 8, width: 10, height: 7)).fill()
    }

    private func drawThinkingRing(in rect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        path.lineWidth = 1.5
        path.stroke()
        accentColor().setFill()
        let angle = phase.truncatingRemainder(dividingBy: CGFloat.pi * 2)
        let point = NSPoint(x: rect.midX + cos(angle) * rect.width * 0.34, y: rect.midY + sin(angle) * rect.height * 0.34)
        NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
    }

    private func drawApprovalIcon(in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: rect.maxY - 1))
        path.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
        path.line(to: NSPoint(x: rect.minX + 1, y: rect.minY + 1))
        path.close()
        accentColor().setFill()
        path.fill()
    }

    private func drawFailureDot(in rect: NSRect) {
        accentColor().setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
    }

    private func drawSpeakingIcon(in rect: NSRect) {
        let center = NSPoint(x: rect.minX + rect.width * 0.34, y: rect.midY)
        accentColor().setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4)).fill()

        for index in 0..<2 {
            let inset = CGFloat(index) * 3
            let waveRect = NSRect(
                x: center.x - 2 + inset,
                y: rect.minY + 2 + inset * 0.25,
                width: rect.width - 2 - inset,
                height: rect.height - 4 - inset * 0.5
            )
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: min(waveRect.width, waveRect.height) * (0.48 + CGFloat(index) * 0.22),
                startAngle: -42,
                endAngle: 42,
                clockwise: false
            )
            path.lineWidth = 1.4
            accentColor().withAlphaComponent(0.85 - CGFloat(index) * 0.22).setStroke()
            path.stroke()
        }
    }

    private func drawCompactActivity(in rect: NSRect) {
        let heights: [CGFloat] = [8, 12, 7]
        let barWidth: CGFloat = 3
        let gap: CGFloat = 5
        for index in 0..<3 {
            let wave = (sin(phase * 1.2 + CGFloat(index) * 0.75) + 1) / 2
            let height = heights[index] * (0.72 + wave * 0.28)
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let bar = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
            accentColor().setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func drawSpeakingActivity(in rect: NSRect) {
        let bars = 5
        let gap: CGFloat = 3.2
        let barWidth = max(2.6, (rect.width - CGFloat(bars - 1) * gap) / CGFloat(bars))
        for index in 0..<bars {
            let wave = (sin(phase * 2.4 + CGFloat(index) * 0.78) + 1) / 2
            let height = 4 + wave * (rect.height - 4)
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let bar = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
            accentColor().withAlphaComponent(0.46 + wave * 0.54).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func drawVoiceWaveform(in rect: NSRect) {
        let bars = 9
        let gap: CGFloat = 4
        let barWidth = max(3, (rect.width - CGFloat(bars - 1) * gap) / CGFloat(bars))
        let outputBoost: CGFloat = (isSpeaking || voiceAgentPhase == "speaking") ? 0.72 : 0.18
        let liveBoost = max(outputBoost, inputLevel)
        let baseColor = accentColor()
        for index in 0..<bars {
            let wave = (sin(phase * 1.35 + CGFloat(index) * 0.72) + 1) / 2
            let height = 4 + wave * liveBoost * (rect.height - 4)
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let y = rect.midY - height / 2
            let bar = NSRect(x: x, y: y, width: barWidth, height: height)
            let alpha = 0.36 + liveBoost * 0.64
            baseColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func drawProgress(in rect: NSRect) {
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()

        let base: CGFloat
        switch state.status {
        case "completed":
            base = 1
        case "failed":
            base = 1
        default:
            base = 0.42 + ((sin(phase) + 1) / 2) * 0.42
        }
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width * base, height: rect.height)
        accentColor().setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5).fill()
    }

    private func drawStatusDot(at point: NSPoint) {
        let rect = NSRect(x: point.x, y: point.y, width: 9, height: 9)
        accentColor().setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawThumbnail(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(calibratedRed: 0.07, green: 0.1, blue: 0.16, alpha: 1).setFill()
        rect.fill()
        NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 42, y: rect.minY + 38, width: 46, height: 46)).fill()
        NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.72).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX - 14, y: rect.minY - 10, width: 60, height: 60)).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawText("C", in: NSRect(x: rect.midX - 8, y: rect.midY - 12, width: 20, height: 24), size: 20, weight: .bold, color: .white)
    }

    private func drawControlButton(_ value: String, rect: NSRect, size: CGFloat) {
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let textRect = NSRect(x: rect.minX, y: rect.midY - size / 2 - 1, width: rect.width, height: size + 4)
        drawCenteredText(value, in: textRect, size: size, weight: .bold, color: .white)
    }

    private func drawCalendarStrip(in rect: NSRect) {
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        let today = Calendar.current.component(.day, from: Date())
        for (index, day) in days.enumerated() {
            let x = rect.minX + CGFloat(index) * 40
            let isSelected = index == 2
            if isSelected {
                NSColor(calibratedRed: 0.11, green: 0.43, blue: 0.92, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 8, y: rect.minY, width: 28, height: 31), xRadius: 10, yRadius: 10).fill()
            }
            drawText(day, in: NSRect(x: x, y: rect.minY + 18, width: 40, height: 12), size: 9, weight: .medium, color: NSColor(calibratedWhite: isSelected ? 1 : 0.48, alpha: 1))
            drawText("\(today + index - 2)", in: NSRect(x: x, y: rect.minY + 2, width: 40, height: 16), size: 12, weight: .semibold, color: NSColor(calibratedWhite: isSelected ? 1 : 0.54, alpha: 1))
        }
    }

    private func monthLabel() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: Date())
    }

    private func sideSummaryText() -> String {
        if state.pendingApprovals > 0 {
            return "Waiting for your decision"
        }
        switch state.status {
        case "completed":
            return "Task finished"
        case "failed":
            return "Needs review"
        default:
            return "No events today"
        }
    }

    private func openCrowMainApp() {
        let explicitPath = CrowEnvironment.value("CROW_MAIN_APP_PATH")
        let fallbackPath = FileManager.default.currentDirectoryPath
            .components(separatedBy: "/apps/island-native")
            .first
            .map { "\($0)/apps/macos/build/CrowMac.app" }
        let path = explicitPath ?? fallbackPath

        if let path {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Crow"]
        try? process.run()
    }

    private func submitApprovalAction(type: String) {
        let approvalId = (state.approvalId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !approvalId.isEmpty else {
            openCrowMainApp()
            return
        }
        let action = IslandAction(
            id: "island_action_\(Int(Date().timeIntervalSince1970 * 1000))",
            type: type,
            approvalId: approvalId,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            let directory = try crowApplicationSupportDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(action)
            try data.write(to: directory.appendingPathComponent("island-action.json"), options: .atomic)
        } catch {
            print("approval action write failed: \(error)")
            openCrowMainApp()
        }
    }

    private func scale(rect: NSRect, by scale: CGFloat, anchorY: CGFloat) -> NSRect {
        let nextWidth = rect.width * scale
        let nextHeight = rect.height * scale
        return NSRect(
            x: rect.midX - nextWidth / 2,
            y: anchorY - nextHeight,
            width: nextWidth,
            height: nextHeight
        )
    }

    private func drawText(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        NSString(string: value).draw(in: rect, withAttributes: attributes)
    }

    private func drawCenteredText(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        NSString(string: value).draw(in: rect, withAttributes: attributes)
    }

    private func bottomRoundedPath(rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
        path.curve(to: NSPoint(x: rect.maxX - radius, y: rect.minY), controlPoint1: NSPoint(x: rect.maxX, y: rect.minY + radius * 0.45), controlPoint2: NSPoint(x: rect.maxX - radius * 0.45, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.curve(to: NSPoint(x: rect.minX, y: rect.minY + radius), controlPoint1: NSPoint(x: rect.minX + radius * 0.45, y: rect.minY), controlPoint2: NSPoint(x: rect.minX, y: rect.minY + radius * 0.45))
        path.close()
        return path
    }

    private func expandedPanelPath(rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
        path.curve(
            to: NSPoint(x: rect.maxX - radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.minY + radius * 0.42),
            controlPoint2: NSPoint(x: rect.maxX - radius * 0.42, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.minY + radius),
            controlPoint1: NSPoint(x: rect.minX + radius * 0.42, y: rect.minY),
            controlPoint2: NSPoint(x: rect.minX, y: rect.minY + radius * 0.42)
        )
        path.close()
        return path
    }

    private func shadow(color: NSColor, blur: CGFloat, offset: NSSize, draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = offset
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func accentColor() -> NSColor {
        if isSpeaking {
            return NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 1)
        }
        switch executionPhase {
        case "approval":
            return NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        case "completed":
            return NSColor(calibratedRed: 0.13, green: 0.77, blue: 0.37, alpha: 1)
        case "failed":
            return NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        case "tool":
            return NSColor(calibratedRed: 0.62, green: 0.49, blue: 0.95, alpha: 1)
        case "thinking", "planning":
            return NSColor(calibratedRed: 0.22, green: 0.58, blue: 0.96, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 1)
        }
    }

    private func listeningColor() -> NSColor {
        NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 1)
    }

    private func barLabel() -> String {
        if isSpeaking {
            return "Crow Speaking"
        }
        switch executionPhase {
        case "approval":
            return "Approval Required"
        case "completed":
            return "Task Complete"
        case "failed":
            return "Task Failed"
        case "thinking":
            return "Codex Thinking"
        case "planning":
            return "Planning"
        case "responding":
            return "Responding"
        case "tool":
            return "Using Tool"
        case "starting":
            return "Starting"
        case "idle":
            return "Crow"
        default:
            return "Running"
        }
    }

    private func taskEyebrow() -> String {
        if isSpeaking {
            return "\(state.kind) · speaking".uppercased()
        }
        let executor = (state.executor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !executor.isEmpty {
            return "\(executor) · \(executionPhase)".uppercased()
        }
        return "\(state.kind) · \(executionPhase)".uppercased()
    }

    private func primaryTaskText() -> String {
        if isSpeaking {
            return "Crow is speaking"
        }
        let action = (state.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return action.isEmpty ? state.title : action
    }

    private func secondaryTaskText() -> String {
        let detail = (state.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? state.message : detail
    }

    private func executionLabel() -> String {
        if isSpeaking {
            return "Playing voice response"
        }
        switch executionPhase {
        case "approval":
            return "Waiting for approval"
        case "thinking":
            return "Codex reasoning"
        case "planning":
            return "Planning next step"
        case "responding":
            return "Streaming response"
        case "tool":
            return "Running a tool"
        case "completed":
            return "Execution complete"
        case "failed":
            return "Execution needs review"
        default:
            return "Crow executing"
        }
    }

    private func displayStatus() -> String {
        if isSpeaking {
            return "Speaking"
        }
        return executionPhase.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func approvalSummaryText() -> String {
        let action = firstNonEmptyText(state.approvalAction, state.title)
        let lower = action.lowercased()
        if lower.contains("open -a") || lower.contains("open -b") {
            return "Allow Codex to open an application?"
        }
        if lower.contains("/bin/zsh") || lower.contains("local command") || lower.contains("command") {
            return "Allow Codex to run a local command?"
        }
        return "Allow Crow to continue this action?"
    }

    private func approvalDetailText() -> String {
        let risk = state.approvalRisk ?? 2
        let title = firstNonEmptyText(state.approvalTitle, state.message)
        if title.lowercased().contains("codex") {
            return "Codex is requesting permission. Risk level \(risk)."
        }
        return "Review required before continuing. Risk level \(risk)."
    }

    private func firstNonEmptyText(_ values: String?...) -> String {
        for value in values {
            let cleaned = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return ""
    }
}

private extension NSScreen {
    static let fallbackNotchWidth: CGFloat = 190
    static let fallbackNotchHeight: CGFloat = 38

    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    var isNotchedDisplay: Bool {
        safeAreaInsets.top > 0
            || auxiliaryTopLeftArea?.isEmpty == false
            || auxiliaryTopRightArea?.isEmpty == false
    }

    var notchSize: CGSize {
        guard isNotchedDisplay else {
            return CGSize(width: Self.fallbackNotchWidth, height: Self.fallbackNotchHeight)
        }

        let notchHeight = max(safeAreaInsets.top, topStatusBarHeight)
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        let derivedWidth = frame.width - leftPadding - rightPadding + 4
        let notchWidth = derivedWidth.isFinite && derivedWidth > 80 ? derivedWidth : Self.fallbackNotchWidth

        return CGSize(width: notchWidth, height: notchHeight)
    }

    var topStatusBarHeight: CGFloat {
        let reservedTopInset = max(0, frame.maxY - visibleFrame.maxY)
        if reservedTopInset > 0 {
            return reservedTopInset
        }
        if safeAreaInsets.top > 0 {
            return safeAreaInsets.top
        }
        return 24
    }

    var islandClosedHeight: CGFloat {
        if isNotchedDisplay {
            return notchSize.height
        }
        return topStatusBarHeight
    }
}

let app = NSApplication.shared
let delegate = CrowIslandController()
app.delegate = delegate
app.run()
