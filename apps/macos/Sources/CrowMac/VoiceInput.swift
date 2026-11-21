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
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CROW_MIC_PROBE"] != nil else { return }
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
