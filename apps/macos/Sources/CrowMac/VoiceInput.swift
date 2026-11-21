import AVFoundation

/// Prepares microphone audio for recognition, shared by every voice session.
///
/// It turns on macOS voice processing (the noise suppression, echo cancellation
/// and gain control FaceTime uses) unless CROW_VOICE_PROCESSING is "false". With
/// voice processing on, the input node reports several channels and the processed
/// voice is on the first, so every buffer is reduced to that channel. Without it,
/// RNNoise does the denoising when the format allows.
final class CrowMicPipeline: @unchecked Sendable {
    let usesVoiceProcessing: Bool
    /// The format of buffers `process` returns: mono Float32.
    let format: AVAudioFormat
    private let tapFormat: AVAudioFormat
    private let denoiser: CrowRNNoiseDenoiser?

    /// Configures `engine`'s input node. Pass `voiceProcessing: false` to retry
    /// after an engine failed to start with it on.
    init?(engine: AVAudioEngine, voiceProcessing: Bool = CrowMicPipeline.voiceProcessingConfigured) {
        let input = engine.inputNode
        var enabled = false
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                enabled = true
                if #available(macOS 14.0, *) {
                    // Keep other apps' audio as loud as possible while Crow listens.
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                NSLog("Crow voice processing unavailable: \(error.localizedDescription)")
            }
        } else if input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
        }
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: tapFormat.sampleRate, channels: 1, interleaved: false) else {
            return nil
        }
        usesVoiceProcessing = enabled
        self.tapFormat = tapFormat
        format = mono
        let rnnoise = (CrowEnvironment.value("CROW_RNNOISE_ENABLED") ?? "true").lowercased() != "false"
        denoiser = !enabled && rnnoise && CrowRNNoiseDenoiser.isSupported(format: mono) ? CrowRNNoiseDenoiser() : nil
    }

    static var voiceProcessingConfigured: Bool {
        (CrowEnvironment.value("CROW_VOICE_PROCESSING") ?? "true").lowercased() != "false"
    }

    /// Installs a tap that receives processed mono buffers.
    func installTap(on engine: AVAudioEngine, _ block: @escaping (AVAudioPCMBuffer) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [self] buffer, _ in
            if let processed = process(buffer) {
                block(processed)
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let mono = firstChannel(of: buffer)
        guard let denoiser else { return mono }
        return mono.flatMap { denoiser.process($0) }
    }

    private func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.channelCount == 1, !buffer.format.isInterleaved {
            return buffer
        }
        guard let source = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = mono.floatChannelData else {
            return nil
        }
        mono.frameLength = buffer.frameLength
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        for index in 0..<Int(buffer.frameLength) {
            target[0][index] = source[0][index * stride]
        }
        return mono
    }

    /// Starts `engine` with voice processing, falling back to plain input when the
    /// device refuses it. `setup` installs taps for the pipeline it is given.
    static func start(_ engine: AVAudioEngine, voiceProcessing preferred: Bool = voiceProcessingConfigured,
                      setup: (CrowMicPipeline) throws -> Void) throws -> CrowMicPipeline {
        var lastError: Error?
        for voiceProcessing in preferred ? [true, false] : [false] {
            guard let pipeline = CrowMicPipeline(engine: engine, voiceProcessing: voiceProcessing) else { continue }
            do {
                try setup(pipeline)
                engine.prepare()
                try engine.start()
                return pipeline
            } catch {
                lastError = error
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                NSLog("Crow microphone start failed (voice processing \(pipeline.usesVoiceProcessing)): \(error.localizedDescription)")
            }
        }
        throw lastError ?? NSError(domain: "CrowMicPipeline", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The microphone could not be started"
        ])
    }
}

/// Tells the main speaker's voice from quieter background speech by loudness: the
/// person talking to Crow is close to the microphone and much louder than a TV or
/// a colleague across the room. It learns the speaker's level as they talk and then
/// only counts sound within `margin` dB of it as speech, holding briefly after each
/// word so syllable gaps do not cut in. It does not separate two people who are
/// both close to the microphone. CROW_VOICE_NEAR_FIELD=false turns it off.
final class CrowNearFieldGate {
    private(set) var noiseFloor: Float = -60
    private(set) var speakerLevel: Float?
    private var candidateFrames = 0
    private var candidateSum: Float = 0
    private var holdUntil: Date = .distantPast
    private let margin: Float
    private let enabled: Bool

    /// About 300 ms: speech pauses shorter than this stay open.
    private static let hold: TimeInterval = 0.3

    init(margin: Float = 18) {
        self.margin = margin
        enabled = (CrowEnvironment.value("CROW_VOICE_NEAR_FIELD") ?? "true").lowercased() != "false"
    }

    /// Feeds one buffer's power in dB and reports whether the main speaker is talking.
    @discardableResult
    func process(power: Float, now: Date = Date()) -> Bool {
        // The floor follows quiet stretches quickly and loud ones very slowly.
        if power < noiseFloor + 3 {
            noiseFloor = noiseFloor * 0.9 + power * 0.1
        } else {
            noiseFloor += (power - noiseFloor) * 0.002
        }
        let isSound = power > max(noiseFloor + 9, -52)
        guard isSound else {
            return now < holdUntil
        }
        let isSpeaker: Bool
        if let level = speakerLevel {
            isSpeaker = !enabled || power > level - margin
            // Only the speaker's own frames move the estimate, so a long stretch of
            // background speech cannot pull it down: rise fast, fall slowly.
            if power > level - margin {
                speakerLevel = power > level ? level + (power - level) * 0.3 : level + (power - level) * 0.02
            }
        } else {
            isSpeaker = true
            candidateFrames += 1
            candidateSum += power
            // About 0.2 s of speech sets the first estimate.
            if candidateFrames >= 10 {
                speakerLevel = candidateSum / Float(candidateFrames)
            }
        }
        if isSpeaker {
            holdUntil = now.addingTimeInterval(Self.hold)
            return true
        }
        return now < holdUntil
    }
}

/// Development aid: with CROW_MIC_PROBE set, logs the microphone level for a few
/// seconds after launch, with and without voice processing, to check that the
/// processed channel carries sound on this Mac.
enum CrowMicProbe {
    /// Checks the shared microphone: pre-roll, and how loud speech played by the
    /// Mac sounds to it (echo cancellation).
    private static func probeHub() {
        let hub = CrowMicHub.shared
        do { try hub.acquire() } catch {
            CrowMacLog("hub probe: acquire failed \(error.localizedDescription)")
            return
        }
        Thread.sleep(forTimeInterval: 1.5)
        var prerollFrames = 0
        var collecting = true
        let lock = NSLock()
        var sum: Float = 0
        var frames = 0
        let id = hub.subscribe(preroll: 0.8) { buffer in
            lock.lock(); defer { lock.unlock() }
            if collecting { prerollFrames += Int(buffer.frameLength) }
            guard let d = buffer.floatChannelData else { return }
            for i in 0..<Int(buffer.frameLength) { sum += d[0][i] * d[0][i] }
            frames += Int(buffer.frameLength)
        }
        lock.withLock { collecting = false }
        let rate = hub.format?.sampleRate ?? 48_000
        CrowMacLog("hub probe: preroll \(Double(prerollFrames) / rate)s")

        func level(during play: () -> Void) -> Float {
            lock.withLock { sum = 0; frames = 0 }
            play()
            return lock.withLock { 10 * log10(max(sum / Float(max(frames, 1)), 1e-12)) }
        }
        let quiet = level { Thread.sleep(forTimeInterval: 2) }
        let playing = level {
            let speech = Process()
            speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            speech.arguments = ["Crow is speaking. Can the microphone hear it?"]
            try? speech.run()
            speech.waitUntilExit()
        }
        CrowMacLog("hub probe: mic level quiet=\(quiet)dB while the Mac speaks=\(playing)dB")
        hub.unsubscribe(id)
        hub.release()
    }

    static func runIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["CROW_MIC_PROBE"] else { return }
        if mode == "hub" {
            DispatchQueue.global().async { probeHub() }
            return
        }
        DispatchQueue.global().async {
            for voiceProcessing in [false, true, true, false] {
                let engine = AVAudioEngine()
                var sum: Float = 0
                var frames = 0
                let lock = NSLock()
                do {
                    let pipeline = try CrowMicPipeline.start(engine, voiceProcessing: voiceProcessing) { pipeline in
                        pipeline.installTap(on: engine) { buffer in
                            guard let data = buffer.floatChannelData else { return }
                            lock.lock()
                            for i in 0..<Int(buffer.frameLength) { sum += data[0][i] * data[0][i] }
                            frames += Int(buffer.frameLength)
                            lock.unlock()
                        }
                    }
                    Thread.sleep(forTimeInterval: 3)
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    lock.lock()
                    let db = 10 * log10(max(sum / Float(max(frames, 1)), 1e-12))
                    lock.unlock()
                    CrowMacLog("mic probe voiceProcessing=\(pipeline.usesVoiceProcessing) frames=\(frames) level=\(db)dB")
                } catch {
                    CrowMacLog("mic probe failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// One microphone shared by every voice session while Crow is in a conversation.
///
/// Starting an engine with voice processing takes a moment, so a fresh engine per
/// turn dropped the first words. The hub keeps one engine running while anyone
/// holds it and remembers the last second of audio: a new session first receives
/// that pre-roll, so words spoken just before it started are kept. It also lets
/// Crow listen while it speaks: macOS voice processing cancels everything the Mac
/// plays (measured: speech from the speakers drops from -33 dB to the room's
/// level), so Crow's own voice does not reach the microphone.
final class CrowMicHub: @unchecked Sendable {
    static let shared = CrowMicHub()

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var pipeline: CrowMicPipeline?
    private var holders = 0
    private var stopWork: DispatchWorkItem?
    private var subscribers: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var ring: [AVAudioPCMBuffer] = []
    private var ringFrames: AVAudioFrameCount = 0
    private var pendingPreroll: TimeInterval = 0
    private static let ringSeconds: Double = 1.2

    private init() {}

    /// The format of delivered buffers, while running.
    var format: AVAudioFormat? { lock.withLock { pipeline?.format } }

    /// Starts the microphone if needed. Balance every call with `release`.
    func acquire() throws {
        lock.lock()
        stopWork?.cancel()
        stopWork = nil
        holders += 1
        let running = engine != nil
        lock.unlock()
        guard !running else { return }
        do {
            let engine = AVAudioEngine()
            let pipeline = try CrowMicPipeline.start(engine) { pipeline in
                pipeline.installTap(on: engine) { [weak self] buffer in self?.deliver(buffer) }
            }
            lock.withLock {
                self.engine = engine
                self.pipeline = pipeline
            }
        } catch {
            lock.withLock { holders = max(0, holders - 1) }
            throw error
        }
    }

    /// Stops the microphone shortly after the last holder lets go, so a session
    /// that follows right away finds it still running.
    func release() {
        lock.lock()
        holders = max(0, holders - 1)
        guard holders == 0, engine != nil else {
            lock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.stopIfUnused() }
        stopWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func stopIfUnused() {
        lock.lock()
        guard holders == 0, let engine else {
            lock.unlock()
            return
        }
        self.engine = nil
        pipeline = nil
        ring.removeAll()
        ringFrames = 0
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The next subscription receives at least this much pre-roll, e.g. to keep
    /// the words that interrupted Crow.
    func requestPreroll(_ seconds: TimeInterval) {
        lock.withLock { pendingPreroll = max(pendingPreroll, seconds) }
    }

    /// Receives every processed buffer, starting with up to `preroll` seconds
    /// of recent audio. Handlers run on the audio thread.
    func subscribe(preroll: TimeInterval = 0, _ handler: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let seconds = max(preroll, pendingPreroll)
        pendingPreroll = 0
        var recent: [AVAudioPCMBuffer] = []
        if seconds > 0, let rate = pipeline?.format.sampleRate {
            var frames: Double = 0
            for buffer in ring.reversed() where frames < seconds * rate {
                recent.insert(buffer, at: 0)
                frames += Double(buffer.frameLength)
            }
        }
        // Replay inside the lock so no live buffer can arrive before the pre-roll.
        recent.forEach(handler)
        subscribers[id] = handler
        lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: id) }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        lock.lock()
        ring.append(copy)
        ringFrames += copy.frameLength
        let limit = AVAudioFrameCount(copy.format.sampleRate * Self.ringSeconds)
        while ringFrames > limit, !ring.isEmpty {
            ringFrames -= ring.removeFirst().frameLength
        }
        let handlers = Array(subscribers.values)
        lock.unlock()
        handlers.forEach { $0(copy) }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData,
              let target = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}

/// Notices the user starting to talk while Crow is busy or speaking. It learns
/// the level of what the microphone hears meanwhile (room noise, and Crow's own
/// voice where echo cancellation cannot remove it) and fires when sound stays
/// well above that level for about 0.4 s. CROW_VOICE_BARGE_IN=false turns it off.
final class CrowBargeInDetector {
    static var isEnabled: Bool {
        (CrowEnvironment.value("CROW_VOICE_BARGE_IN") ?? "true").lowercased() != "false"
    }

    private let startedAt: Date
    private var floor: Float?
    private var aboveSince: Date?
    private var lastAbove: Date?
    private static let learning: TimeInterval = 0.5
    private static let sustain: TimeInterval = 0.4
    private static let margin: Float = 12

    init(now: Date = Date()) { startedAt = now }

    func process(power: Float, now: Date = Date()) -> Bool {
        guard let floor, now.timeIntervalSince(startedAt) > Self.learning else {
            self.floor = self.floor.map { $0 * 0.85 + power * 0.15 } ?? power
            return false
        }
        if power < floor + 6 {
            // Follow the background, including Crow's voice getting louder or softer.
            self.floor = floor * 0.97 + power * 0.03
        }
        guard power > max(floor + Self.margin, -48) else {
            if let lastAbove, now.timeIntervalSince(lastAbove) > 0.15 {
                aboveSince = nil
            }
            return false
        }
        lastAbove = now
        let since = aboveSince ?? now
        aboveSince = since
        return now.timeIntervalSince(since) >= Self.sustain
    }
}

/// A voice session's hold on the shared microphone.
final class CrowMicSubscription: @unchecked Sendable {
    /// Default pre-roll: words spoken just before listening started.
    static let defaultPreroll: TimeInterval = 0.4

    let format: AVAudioFormat
    private var id: UUID?
    private let lock = NSLock()

    /// `prepare` runs with the buffer format before any audio arrives.
    init(preroll: TimeInterval = CrowMicSubscription.defaultPreroll,
         prepare: (AVAudioFormat) throws -> Void = { _ in },
         _ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let hub = CrowMicHub.shared
        try hub.acquire()
        guard let format = hub.format else {
            hub.release()
            throw NSError(domain: "CrowMicSubscription", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone is not running"])
        }
        do {
            try prepare(format)
        } catch {
            hub.release()
            throw error
        }
        self.format = format
        id = hub.subscribe(preroll: preroll, handler)
    }

    func cancel() {
        let id: UUID? = lock.withLock {
            defer { self.id = nil }
            return self.id
        }
        guard let id else { return }
        CrowMicHub.shared.unsubscribe(id)
        CrowMicHub.shared.release()
    }

    deinit { cancel() }
}
