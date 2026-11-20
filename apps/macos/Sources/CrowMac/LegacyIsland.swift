import AppKit
import AVFoundation
import Carbon
import CRNNoise
import Foundation
import Security
import Speech

extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

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

enum CrowVoiceProvider {
    static var configured: String {
        (CrowEnvironment.value("CROW_VOICE_PROVIDER") ?? "system")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static var effective: String {
        let provider = configured
        if provider == "openai_realtime" && !hasOpenAIRealtimePath {
            return "system"
        }
        return provider
    }

    static var hasOpenAIRealtimePath: Bool {
        if CrowCloudHTTP.baseURL().isEmpty == false {
            return true
        }
        guard let key = CrowEnvironment.value("CROW_OPENAI_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !key.isEmpty
    }

    static var fallbackReason: String? {
        configured == "openai_realtime" && !hasOpenAIRealtimePath
            ? "OpenAI Realtime is not configured. Using system voice."
            : nil
    }
}

enum CrowPermissionBridge {
    static func requestSpeech(_ completion: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") is String else {
            NSLog("Crow speech permission request skipped: NSSpeechRecognitionUsageDescription is missing from the runtime bundle.")
            completion(.denied)
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status)
        }
    }

    static func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String else {
            NSLog("Crow microphone permission request skipped: NSMicrophoneUsageDescription is missing from the runtime bundle.")
            completion(false)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }
}

enum CrowProxySettings {
    static func urlSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        if let proxy = proxyDictionary() {
            configuration.connectionProxyDictionary = proxy
        }
        return configuration
    }

    private static func proxyDictionary() -> [AnyHashable: Any]? {
        if let httpURL = firstProxyURL(keys: ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]) {
            return httpProxyDictionary(from: httpURL)
        }
        if let socksURL = firstProxyURL(keys: ["ALL_PROXY", "all_proxy"]) {
            return socksProxyDictionary(from: socksURL)
        }
        return nil
    }

    private static func firstProxyURL(keys: [String]) -> URL? {
        for key in keys {
            guard let raw = CrowEnvironment.value(key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw),
                  url.host != nil else {
                continue
            }
            return url
        }
        return nil
    }

    private static func httpProxyDictionary(from url: URL) -> [AnyHashable: Any] {
        var values: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: url.host ?? "",
            kCFNetworkProxiesHTTPPort as String: url.port ?? 80,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: url.host ?? "",
            kCFNetworkProxiesHTTPSPort as String: url.port ?? 80
        ]
        if let user = url.user, !user.isEmpty {
            values[kCFProxyUsernameKey as String] = user
        }
        if let password = url.password, !password.isEmpty {
            values[kCFProxyPasswordKey as String] = password
        }
        return values
    }

    private static func socksProxyDictionary(from url: URL) -> [AnyHashable: Any] {
        var values: [AnyHashable: Any] = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: url.host ?? "",
            kCFNetworkProxiesSOCKSPort as String: url.port ?? 1080
        ]
        if let user = url.user, !user.isEmpty {
            values[kCFProxyUsernameKey as String] = user
        }
        if let password = url.password, !password.isEmpty {
            values[kCFProxyPasswordKey as String] = password
        }
        return values
    }
}

enum CrowOpenAIHTTP {
    struct MultipartFile {
        let fieldName: String
        let filename: String
        let contentType: String
        let data: Data
    }

    static func apiKey() -> String? {
        guard let key = CrowEnvironment.value("CROW_OPENAI_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func baseURL() -> String {
        (CrowEnvironment.value("CROW_OPENAI_BASE_URL")
            ?? CrowEnvironment.value("CROW_OPENAI_REALTIME_BASE_URL")
            ?? "https://api.openai.com")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func url(path: String) -> URL? {
        URL(string: baseURL() + path)
    }

    static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let key = apiKey() {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func multipartBody(boundary: String, fields: [String: String], files: [MultipartFile]) -> Data {
        var body = Data()
        func append(_ value: String) {
            body.append(value.data(using: .utf8)!)
        }

        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        for file in files {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }

        append("--\(boundary)--\r\n")
        return body
    }

    static func errorMessage(from data: Data?) -> String? {
        guard let data else {
            return nil
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8)
    }
}

enum CrowCloudHTTP {
    static func baseURL() -> String {
        (CrowEnvironment.value("CROW_CLOUD_BASE_URL") ?? "http://127.0.0.1:8080")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func url(path: String) -> URL? {
        URL(string: baseURL() + path)
    }

    static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = fastBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func fastBearerToken() -> String? {
        CrowEnvironment.value("CROW_DEVICE_TOKEN")
            ?? CrowEnvironment.value("CROW_CLOUD_DEVICE_TOKEN")
            ?? CrowEnvironment.value("CROW_CLOUD_DEV_TOKEN")
            ?? CrowCloudDevice.cachedToken()
    }

    static func bearerToken() -> String? {
        CrowEnvironment.value("CROW_DEVICE_TOKEN")
            ?? CrowEnvironment.value("CROW_CLOUD_DEVICE_TOKEN")
            ?? CrowEnvironment.value("CROW_CLOUD_DEV_TOKEN")
            ?? CrowCloudDevice.token()
    }
}

enum CrowOpenAIRealtimeControlPlane {
    struct Credential {
        let bearerToken: String
        let baseURL: String
        let model: String
        let voice: String
    }

    static func resolve(model: String, voice: String, instructions: String) throws -> Credential {
        do {
            return try fetchCrowCloudCredential(model: model, voice: voice, instructions: instructions, allowTokenRefresh: true)
        } catch {
            if let direct = directCredential(model: model, voice: voice) {
                NSLog("Crow Realtime control plane unavailable, using local OpenAI key fallback: \(error.localizedDescription)")
                return direct
            }
            throw error
        }
    }

    private static func directCredential(model: String, voice: String) -> Credential? {
        guard let key = CrowOpenAIHTTP.apiKey() else {
            return nil
        }
        return Credential(
            bearerToken: key,
            baseURL: realtimeBaseURL(),
            model: model.isEmpty ? "gpt-realtime" : model,
            voice: voice.isEmpty ? "marin" : voice
        )
    }

    private static func fetchCrowCloudCredential(model: String, voice: String, instructions: String, allowTokenRefresh: Bool) throws -> Credential {
        if CrowCloudHTTP.bearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            _ = ensureCloudDeviceToken(timeout: 5)
        }

        guard let url = CrowCloudHTTP.url(path: "/v1/realtime/client-secret") else {
            throw NSError(domain: "CrowOpenAIRealtimeControlPlane", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Crow Cloud Realtime URL"
            ])
        }

        var request = CrowCloudHTTP.request(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "voice": voice,
            "instructions": instructions
        ])

        let response = try performSynchronousJSONRequest(request, timeout: 12)
        if response.status == 401 && allowTokenRefresh {
            CrowCloudDevice.clearStoredToken()
            _ = ensureCloudDeviceToken(timeout: 5)
            return try fetchCrowCloudCredential(model: model, voice: voice, instructions: instructions, allowTokenRefresh: false)
        }
        guard (200..<300).contains(response.status) else {
            throw NSError(domain: "CrowOpenAIRealtimeControlPlane", code: response.status, userInfo: [
                NSLocalizedDescriptionKey: CrowOpenAIHTTP.errorMessage(from: response.data) ?? "Crow Cloud Realtime failed with status \(response.status)"
            ])
        }
        guard let data = response.data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = clientSecretValue(from: object) else {
            throw NSError(domain: "CrowOpenAIRealtimeControlPlane", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Crow Cloud Realtime response did not include a client secret"
            ])
        }

        let configuration = object["configuration"] as? [String: Any]
        let resolvedBaseURL = (configuration?["base_url"] as? String) ?? realtimeBaseURL()
        let resolvedModel = (object["model"] as? String) ?? model
        let resolvedVoice = (object["voice"] as? String) ?? voice
        return Credential(
            bearerToken: token,
            baseURL: resolvedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            model: resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-realtime" : resolvedModel,
            voice: resolvedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "marin" : resolvedVoice
        )
    }

    private static func clientSecretValue(from object: [String: Any]) -> String? {
        if let secret = object["client_secret"] as? [String: Any],
           let value = secret["value"] as? String,
           !value.isEmpty {
            return value
        }
        if let value = object["value"] as? String, !value.isEmpty {
            return value
        }
        if let openAI = object["openai"] as? [String: Any] {
            if let secret = openAI["client_secret"] as? [String: Any],
               let value = secret["value"] as? String,
               !value.isEmpty {
                return value
            }
            if let value = openAI["value"] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func ensureCloudDeviceToken(timeout: TimeInterval) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var resolvedToken: String?
        CrowCloudDevice.ensureActivated { token in
            resolvedToken = token
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return resolvedToken
    }

    private static func performSynchronousJSONRequest(_ request: URLRequest, timeout: TimeInterval) throws -> (data: Data?, status: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var resultData: Data?
        nonisolated(unsafe) var resultStatus = 0
        nonisolated(unsafe) var resultError: Error?
        let task = URLSession(configuration: CrowProxySettings.urlSessionConfiguration()).dataTask(with: request) { data, response, error in
            resultData = data
            resultStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            resultError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw NSError(domain: "CrowOpenAIRealtimeControlPlane", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Crow Cloud Realtime request timed out"
            ])
        }
        if let resultError {
            throw resultError
        }
        return (resultData, resultStatus)
    }

    private static func realtimeBaseURL() -> String {
        (CrowEnvironment.value("CROW_OPENAI_REALTIME_BASE_URL")
            ?? CrowEnvironment.value("CROW_OPENAI_BASE_URL")
            ?? "https://api.openai.com")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum CrowCloudDevice {
    private static let service = "ai.crow.cloud"
    private static let tokenAccount = "device_token"
    private static let activationQueue = DispatchQueue(label: "ai.crow.cloud.device.activation")
    nonisolated(unsafe) private static var inMemoryToken: String?
    nonisolated(unsafe) private static var isActivating = false
    nonisolated(unsafe) private static var pendingCompletions: [@Sendable (String?) -> Void] = []

    static func shouldUseCloudVoice() -> Bool {
        let stt = (CrowEnvironment.value("CROW_STT_PROVIDER") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let tts = (CrowEnvironment.value("CROW_TTS_PROVIDER") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let voice = CrowVoiceProvider.configured
        return stt == "cloud" || stt == "crow_cloud" || tts == "cloud" || tts == "crow_cloud" || voice == "openai_realtime"
    }

    static func token() -> String? {
        if let inMemoryToken, !inMemoryToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inMemoryToken
        }
        let value = keychainValue(account: tokenAccount)
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inMemoryToken = value
        }
        return value
    }

    static func cachedToken() -> String? {
        inMemoryToken
    }

    static func clearStoredToken() {
        inMemoryToken = nil
        deleteKeychainValue(account: tokenAccount)
    }

    static func ensureActivated(completion: @escaping @Sendable (String?) -> Void = { _ in }) {
        if let token = CrowEnvironment.value("CROW_DEVICE_TOKEN")
            ?? CrowEnvironment.value("CROW_CLOUD_DEVICE_TOKEN")
            ?? CrowEnvironment.value("CROW_CLOUD_DEV_TOKEN")
            ?? token(),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(token)
            return
        }

        activationQueue.async {
            pendingCompletions.append(completion)
            guard !isActivating else {
                return
            }
            isActivating = true
            DispatchQueue.main.async {
                activate()
            }
        }
    }

    private static func activate() {
        guard let url = CrowCloudHTTP.url(path: "/v1/devices/activate") else {
            finishActivation(token: nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": deviceID(),
            "device_name": Host.current().localizedName ?? "Mac",
            "platform": "macos",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        ])

        URLSession(configuration: CrowProxySettings.urlSessionConfiguration()).dataTask(with: request) { data, response, error in
            if let error {
                NSLog("Crow Cloud device activation failed: \(error.localizedDescription)")
                finishActivation(token: nil)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data,
                  (200..<300).contains(status),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["device_token"] as? String,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSLog("Crow Cloud device activation failed with status \(status)")
                finishActivation(token: nil)
                return
            }
            saveKeychainValue(token, account: tokenAccount)
            inMemoryToken = token
            finishActivation(token: token)
        }.resume()
    }

    private static func finishActivation(token: String?) {
        activationQueue.async {
            let completions = pendingCompletions
            pendingCompletions = []
            isActivating = false
            DispatchQueue.main.async {
                completions.forEach { $0(token) }
            }
        }
    }

    private static func deviceID() -> String {
        let key = "CrowCloudDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let next = "mac_" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(next, forKey: key)
        return next
    }

    private static func keychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func saveKeychainValue(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8)
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return
        }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    private static func deleteKeychainValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
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

protocol CrowVoiceInputSession: AnyObject {
    var id: String { get }
    var keepsSessionAliveAfterInputStop: Bool { get }
    func start(localeIdentifier: String) throws
    func stopInput()
    func stop(cancel: Bool)
}

extension CrowVoiceInputSession {
    var keepsSessionAliveAfterInputStop: Bool { false }
}

final class CrowSystemSpeechSession: CrowVoiceInputSession {
    let id = UUID().uuidString

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(localeIdentifier: String) throws {
        stop(cancel: true)

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw NSError(domain: "CrowSystemSpeechSession", code: 1, userInfo: [
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

    static func averagePower(from buffer: AVAudioPCMBuffer) -> Float {
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

final class CrowOpenAITranscriptionSession: CrowVoiceInputSession, @unchecked Sendable {
    let id = UUID().uuidString
    let keepsSessionAliveAfterInputStop = true

    private let useCloudBackend: Bool
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var partialRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var partialRecognitionTask: SFSpeechRecognitionTask?
    private var uploadTask: URLSessionDataTask?
    private var didStopInput = false
    private let audioQueue = DispatchQueue(label: "dev.crow.openai-stt.audio")
    private var pcm16Data = Data()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init(useCloudBackend: Bool = false) {
        self.useCloudBackend = useCloudBackend
    }

    func start(localeIdentifier: String) throws {
        stop(cancel: true)

        guard useCloudBackend || CrowOpenAIHTTP.apiKey() != nil else {
            throw NSError(domain: "CrowOpenAITranscriptionSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "OpenAI API key is not configured"
            ])
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "CrowOpenAITranscriptionSession", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create audio converter for OpenAI transcription"
            ])
        }
        audioConverter = converter
        didStopInput = false
        audioQueue.sync {
            pcm16Data = Data()
        }
        startPartialRecognition(localeIdentifier: localeIdentifier)

        inputNode.removeTap(onBus: 0)
        let sessionID = id
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            CrowStreamingEventPoster.postLevel(sessionID: sessionID, power: CrowSystemSpeechSession.averagePower(from: buffer))
            self.partialRecognitionRequest?.append(buffer)
            guard let data = self.convertToPCM16(buffer) else { return }
            self.audioQueue.async {
                self.pcm16Data.append(data)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    func stopInput() {
        guard !didStopInput else {
            return
        }
        didStopInput = true
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        stopPartialRecognition(cancel: false)

        audioQueue.async { [weak self] in
            guard let self else { return }
            let wav = Self.wavData(fromPCM16: self.pcm16Data, sampleRate: 16_000, channels: 1)
            DispatchQueue.main.async {
                self.upload(wavData: wav)
            }
        }
    }

    func stop(cancel: Bool) {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        stopPartialRecognition(cancel: cancel)
        if cancel {
            uploadTask?.cancel()
            uploadTask = nil
        } else {
            stopInput()
        }
    }

    private func startPartialRecognition(localeIdentifier: String) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        partialRecognitionRequest = request
        let sessionID = id
        partialRecognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Cloud STT owns the final transcript. System speech only drives live preview text.
                    CrowStreamingEventPoster.postTranscript(sessionID: sessionID, text: text, isFinal: false)
                }
            }
            if let error,
               !error.localizedDescription.lowercased().contains("cancel") {
                NSLog("Crow cloud STT partial recognition ended: \(error.localizedDescription)")
            }
        }
    }

    private func stopPartialRecognition(cancel: Bool) {
        if cancel {
            partialRecognitionTask?.cancel()
        } else {
            partialRecognitionRequest?.endAudio()
        }
        partialRecognitionRequest = nil
        partialRecognitionTask = nil
    }

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter = audioConverter,
              let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 8
              ) else {
            return nil
        }

        let state = CrowAudioConversionState()
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error,
              conversionError == nil,
              let channels = converted.floatChannelData else {
            return nil
        }

        let samples = channels[0]
        let sampleCount = Int(converted.frameLength)
        var data = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        for index in 0..<sampleCount {
            let clipped = max(-1, min(1, samples[index]))
            var value = Int16(clipped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func upload(wavData: Data) {
        performUpload(wavData: wavData, allowTokenRefresh: true)
    }

    private func performUpload(wavData: Data, allowTokenRefresh: Bool) {
        guard !wavData.isEmpty else {
            CrowStreamingEventPoster.postError(sessionID: id, message: "No audio captured")
            return
        }
        let url = useCloudBackend
            ? CrowCloudHTTP.url(path: "/v1/voice/transcriptions")
            : CrowOpenAIHTTP.url(path: "/v1/audio/transcriptions")
        guard let url else {
            CrowStreamingEventPoster.postError(sessionID: id, message: useCloudBackend ? "Invalid Crow Cloud transcription URL" : "Invalid OpenAI transcription URL")
            return
        }

        let model = (CrowEnvironment.value("CROW_OPENAI_STT_MODEL") ?? "gpt-4o-mini-transcribe")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = Self.transcriptionLanguage()
        let boundary = "CrowBoundary\(UUID().uuidString)"
        var request = useCloudBackend ? CrowCloudHTTP.request(url: url) : CrowOpenAIHTTP.request(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fields = useCloudBackend
            ? ["language": language]
            : [
                "model": model.isEmpty ? "gpt-4o-mini-transcribe" : model,
                "language": language,
                "response_format": "json"
            ]
        let body = CrowOpenAIHTTP.multipartBody(
            boundary: boundary,
            fields: fields,
            files: [
                CrowOpenAIHTTP.MultipartFile(
                    fieldName: "file",
                    filename: "crow-voice.wav",
                    contentType: "audio/wav",
                    data: wavData
                )
            ]
        )

        let task = URLSession(configuration: CrowProxySettings.urlSessionConfiguration()).uploadTask(with: request, from: body) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                CrowStreamingEventPoster.postError(sessionID: self.id, message: error.localizedDescription)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if self.useCloudBackend, status == 401, allowTokenRefresh {
                CrowCloudDevice.clearStoredToken()
                CrowCloudDevice.ensureActivated { [weak self] _ in
                    self?.performUpload(wavData: wavData, allowTokenRefresh: false)
                }
                return
            }
            guard let data,
                  (200..<300).contains(status),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let providerName = self.useCloudBackend ? "Crow Cloud transcription" : "OpenAI transcription"
                let message = CrowOpenAIHTTP.errorMessage(from: data) ?? "\(providerName) failed with status \(status)"
                CrowStreamingEventPoster.postError(sessionID: self.id, message: message)
                return
            }
            CrowStreamingEventPoster.postTranscript(sessionID: self.id, text: text, isFinal: true)
        }
        uploadTask = task
        task.resume()
    }

    private static func wavData(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        func appendString(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        let byteRate = sampleRate * channels * 2
        appendString("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(channels * 2))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private static func transcriptionLanguage() -> String {
        let raw = (CrowEnvironment.value("CROW_STT_LANGUAGE") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw.hasPrefix("zh") || raw == "cn" {
            return "zh"
        }
        if raw.hasPrefix("en") {
            return "en"
        }
        return raw.isEmpty ? "zh" : raw
    }
}

private final class CrowAudioConversionState: @unchecked Sendable {
    var didProvideInput = false
}

final class CrowOpenAIRealtimeSpeechSession: CrowVoiceInputSession, @unchecked Sendable {
    let id = UUID().uuidString
    let keepsSessionAliveAfterInputStop = true

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var scheduledPlaybackBuffers = 0
    private var transcript = ""
    private var webSocketTask: URLSessionWebSocketTask?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    func start(localeIdentifier: String) throws {
        stop(cancel: true)

        let model = (CrowEnvironment.value("CROW_OPENAI_REALTIME_MODEL") ?? "gpt-realtime")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (CrowEnvironment.value("CROW_OPENAI_REALTIME_VOICE") ?? "marin")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = try CrowOpenAIRealtimeControlPlane.resolve(
            model: model.isEmpty ? "gpt-realtime" : model,
            voice: voice.isEmpty ? "marin" : voice,
            instructions: "You are Crow's realtime voice layer. Transcribe the user's speech accurately. Crow will route tasks and tool execution separately."
        )
        guard var components = URLComponents(string: credential.baseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/v1/realtime") else {
            throw NSError(domain: "CrowOpenAIRealtimeSpeechSession", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid OpenAI Realtime base URL"
            ])
        }
        components.queryItems = [URLQueryItem(name: "model", value: credential.model)]
        guard let url = components.url else {
            throw NSError(domain: "CrowOpenAIRealtimeSpeechSession", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid OpenAI Realtime URL"
            ])
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = URLSession(configuration: CrowProxySettings.urlSessionConfiguration()).webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        receiveNextMessage()
        sendSessionUpdate(localeIdentifier: localeIdentifier, voice: credential.voice)
        try startAudioCapture()
    }

    func stopInput() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        sendJSON(["type": "input_audio_buffer.commit"])
    }

    func stop(cancel: Bool) {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        stopPlayback()
        if !cancel {
            sendJSON(["type": "input_audio_buffer.commit"])
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func sendSessionUpdate(localeIdentifier: String, voice: String) {
        let turnDetection = (CrowEnvironment.value("CROW_OPENAI_REALTIME_TURN_DETECTION") ?? "semantic_vad")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptionModel = (CrowEnvironment.value("CROW_OPENAI_REALTIME_TRANSCRIPTION_MODEL") ?? "gpt-4o-mini-transcribe")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        sendJSON([
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": voice.isEmpty ? "marin" : voice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": transcriptionModel.isEmpty ? "gpt-4o-mini-transcribe" : transcriptionModel,
                    "language": normalizedRealtimeLanguage(localeIdentifier)
                ],
                "turn_detection": [
                    "type": turnDetection.isEmpty ? "semantic_vad" : turnDetection
                ],
                "instructions": "You are Crow's realtime voice layer. Transcribe the user's speech accurately. Crow will route tasks and tool execution separately."
            ]
        ])
    }

    private func startAudioCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "CrowOpenAIRealtimeSpeechSession", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Could not create audio converter for OpenAI Realtime"
            ])
        }
        audioConverter = converter

        inputNode.removeTap(onBus: 0)
        let sessionID = id
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            CrowStreamingEventPoster.postLevel(sessionID: sessionID, power: Self.averagePower(from: buffer))
            guard let data = self.convertToPCM16(buffer) else { return }
            self.sendJSON([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString()
            ])
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter = audioConverter,
              let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 8
              ) else {
            return nil
        }

        let state = CrowAudioConversionState()
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error,
              conversionError == nil,
              let channels = converted.floatChannelData else {
            return nil
        }

        let samples = channels[0]
        let sampleCount = Int(converted.frameLength)
        var data = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        for index in 0..<sampleCount {
            let clipped = max(-1, min(1, samples[index]))
            var value = Int16(clipped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketTask.send(.string(text)) { [weak self] error in
            if let error, let self {
                CrowStreamingEventPoster.postError(sessionID: self.id, message: error.localizedDescription)
            }
        }
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveNextMessage()
            case .failure(let error):
                CrowStreamingEventPoster.postError(sessionID: self.id, message: error.localizedDescription)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let value):
            data = value
        @unknown default:
            data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        if type.contains("transcription") && type.hasSuffix(".delta"),
           let delta = firstString(object, keys: ["delta", "text", "transcript"]) {
            transcript += delta
            CrowStreamingEventPoster.postTranscript(sessionID: id, text: transcript, isFinal: false)
            return
        }

        if type.contains("transcription") && (type.hasSuffix(".completed") || type.hasSuffix(".done")),
           let text = firstString(object, keys: ["transcript", "text"]) {
            transcript = text
            CrowStreamingEventPoster.postTranscript(sessionID: id, text: text, isFinal: true)
            return
        }

        if type.contains("audio") && type.hasSuffix(".delta"),
           let delta = firstString(object, keys: ["delta", "audio"]),
           let audio = Data(base64Encoded: delta) {
            enqueuePlaybackAudio(audio)
            return
        }

        if type.contains("audio") && (type.hasSuffix(".done") || type.hasSuffix(".completed")) {
            if scheduledPlaybackBuffers == 0 {
                CrowStreamingEventPoster.postPlaybackEnded(sessionID: id)
            }
            return
        }

        if type == "error" {
            let message = (object["error"] as? [String: Any]).flatMap { firstString($0, keys: ["message", "code"]) }
                ?? firstString(object, keys: ["message", "code"])
                ?? "OpenAI Realtime error"
            CrowStreamingEventPoster.postError(sessionID: id, message: message)
        }
    }

    private func normalizedRealtimeLanguage(_ localeIdentifier: String) -> String {
        let value = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("zh") {
            return "zh"
        }
        if value.lowercased().hasPrefix("en") {
            return "en"
        }
        return value.isEmpty ? "zh" : value
    }

    private func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func enqueuePlaybackAudio(_ data: Data) {
        guard !data.isEmpty,
              let buffer = pcm16PlaybackBuffer(from: data) else {
            return
        }
        do {
            try ensurePlaybackEngine()
        } catch {
            CrowStreamingEventPoster.postError(sessionID: id, message: error.localizedDescription)
            return
        }

        scheduledPlaybackBuffers += 1
        CrowStreamingEventPoster.postPlaybackStarted(sessionID: id)
        playerNode?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.scheduledPlaybackBuffers = max(0, self.scheduledPlaybackBuffers - 1)
            if self.scheduledPlaybackBuffers == 0 {
                CrowStreamingEventPoster.postPlaybackEnded(sessionID: self.id)
            }
        }
        if playerNode?.isPlaying != true {
            playerNode?.play()
        }
    }

    private func ensurePlaybackEngine() throws {
        if playbackEngine != nil {
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
        try engine.start()
        playbackEngine = engine
        playerNode = player
    }

    private func stopPlayback() {
        playerNode?.stop()
        playbackEngine?.stop()
        playerNode = nil
        playbackEngine = nil
        scheduledPlaybackBuffers = 0
        CrowStreamingEventPoster.postPlaybackEnded(sessionID: id)
    }

    private func pcm16PlaybackBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channels = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                channels[0][index] = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
            }
        }
        return buffer
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

final class CrowOpenAIRealtimeSpeaker: @unchecked Sendable {
    let id = UUID().uuidString

    private var webSocketTask: URLSessionWebSocketTask?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var scheduledPlaybackBuffers = 0
    private var didReceiveAudio = false
    private var didFinishResponse = false
    private var didComplete = false
    private var onStarted: (() -> Void)?
    private var onFinished: (() -> Void)?
    private var onFailed: ((String) -> Void)?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    @MainActor
    func speak(
        _ text: String,
        onStarted: @escaping () -> Void,
        onFinished: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        stop()
        self.onStarted = onStarted
        self.onFinished = onFinished
        self.onFailed = onFailed

        let model = (CrowEnvironment.value("CROW_OPENAI_REALTIME_MODEL") ?? "gpt-realtime")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (CrowEnvironment.value("CROW_OPENAI_REALTIME_VOICE") ?? "marin")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: CrowOpenAIRealtimeControlPlane.Credential
        do {
            credential = try CrowOpenAIRealtimeControlPlane.resolve(
                model: model.isEmpty ? "gpt-realtime" : model,
                voice: voice.isEmpty ? "marin" : voice,
                instructions: "You are Crow's voice output layer. Speak assistant responses clearly and naturally without adding extra content."
            )
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard var components = URLComponents(string: credential.baseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/v1/realtime") else {
            fail("Invalid OpenAI Realtime base URL")
            return
        }
        components.queryItems = [URLQueryItem(name: "model", value: credential.model)]
        guard let url = components.url else {
            fail("Invalid OpenAI Realtime URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = URLSession(configuration: CrowProxySettings.urlSessionConfiguration()).webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        receiveNextMessage()
        sendSessionUpdate(voice: credential.voice)
        sendResponseRequest(text)
    }

    @MainActor
    func stop() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        stopPlayback()
        onStarted = nil
        onFinished = nil
        onFailed = nil
        didReceiveAudio = false
        didFinishResponse = false
        didComplete = false
    }

    private func sendSessionUpdate(voice: String) {
        sendJSON([
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": voice.isEmpty ? "marin" : voice,
                "output_audio_format": "pcm16",
                "instructions": "You are Crow's voice output layer. Speak assistant responses clearly and naturally without adding extra content."
            ]
        ])
    }

    private func sendResponseRequest(_ text: String) {
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": "Read this aloud exactly, without adding commentary:\n\(text)"
                    ]
                ]
            ]
        ])
        sendJSON([
            "type": "response.create",
            "response": [
                "modalities": ["audio", "text"],
                "instructions": "Speak the provided text naturally. Do not summarize, translate, or add any other words."
            ]
        ])
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketTask.send(.string(text)) { [weak self] error in
            if let error {
                self?.fail(error.localizedDescription)
            }
        }
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                if !self.didComplete {
                    self.receiveNextMessage()
                }
            case .failure(let error):
                if !self.didComplete {
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let value):
            data = value
        @unknown default:
            data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        if type.contains("audio") && type.hasSuffix(".delta"),
           let delta = firstString(object, keys: ["delta", "audio"]),
           let audio = Data(base64Encoded: delta) {
            didReceiveAudio = true
            enqueuePlaybackAudio(audio)
            return
        }

        if type.contains("audio") && (type.hasSuffix(".done") || type.hasSuffix(".completed")) {
            didFinishResponse = true
            completeIfReady()
            return
        }

        if type == "response.done" || type == "response.completed" {
            didFinishResponse = true
            completeIfReady()
            return
        }

        if type == "error" {
            let message = (object["error"] as? [String: Any]).flatMap { firstString($0, keys: ["message", "code"]) }
                ?? firstString(object, keys: ["message", "code"])
                ?? "OpenAI Realtime error"
            fail(message)
        }
    }

    private func enqueuePlaybackAudio(_ data: Data) {
        guard !data.isEmpty,
              let buffer = pcm16PlaybackBuffer(from: data) else {
            return
        }
        do {
            try ensurePlaybackEngine()
        } catch {
            fail(error.localizedDescription)
            return
        }

        scheduledPlaybackBuffers += 1
        DispatchQueue.main.async { [weak self] in
            self?.onStarted?()
            CrowStreamingEventPoster.postPlaybackStarted(sessionID: self?.id ?? "")
        }
        playerNode?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.scheduledPlaybackBuffers = max(0, self.scheduledPlaybackBuffers - 1)
            self.completeIfReady()
        }
        if playerNode?.isPlaying != true {
            playerNode?.play()
        }
    }

    private func ensurePlaybackEngine() throws {
        if playbackEngine != nil {
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
        try engine.start()
        playbackEngine = engine
        playerNode = player
    }

    private func stopPlayback() {
        playerNode?.stop()
        playbackEngine?.stop()
        playerNode = nil
        playbackEngine = nil
        scheduledPlaybackBuffers = 0
    }

    private func completeIfReady() {
        guard didFinishResponse, scheduledPlaybackBuffers == 0, !didComplete else {
            return
        }
        if didReceiveAudio {
            complete()
        } else {
            fail("OpenAI Realtime returned no audio")
        }
    }

    private func complete() {
        guard !didComplete else {
            return
        }
        didComplete = true
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        stopPlayback()
        DispatchQueue.main.async { [onFinished, id] in
            CrowStreamingEventPoster.postPlaybackEnded(sessionID: id)
            onFinished?()
        }
    }

    private func fail(_ message: String) {
        guard !didComplete else {
            return
        }
        didComplete = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        stopPlayback()
        DispatchQueue.main.async { [onFailed, id] in
            CrowStreamingEventPoster.postError(sessionID: id, message: message)
            onFailed?(message)
        }
    }

    private func pcm16PlaybackBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channels = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                channels[0][index] = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
            }
        }
        return buffer
    }

    private func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

final class CrowOpenAITTSSpeaker: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let useCloudBackend: Bool
    private var dataTask: URLSessionDataTask?
    private var player: AVAudioPlayer?
    private var didComplete = false
    private var onStarted: (() -> Void)?
    private var onFinished: (() -> Void)?
    private var onFailed: ((String) -> Void)?

    init(useCloudBackend: Bool = false) {
        self.useCloudBackend = useCloudBackend
        super.init()
    }

    func speak(
        _ text: String,
        onStarted: @escaping () -> Void,
        onFinished: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        CrowMacLog("speech speaker speak entered provider=\(useCloudBackend ? "cloud" : "openai") chars=\(text.count)")
        stop()
        self.onStarted = onStarted
        self.onFinished = onFinished
        self.onFailed = onFailed

        requestSpeech(text, allowTokenRefresh: true)
    }

    private func requestSpeech(_ text: String, allowTokenRefresh: Bool) {
        CrowMacLog("speech request prepare")
        let cloudBaseURL = CrowCloudHTTP.baseURL()
        CrowMacLog("speech cloud base url=\(cloudBaseURL)")
        let url = useCloudBackend
            ? URL(string: cloudBaseURL + "/v1/voice/speech")
            : CrowOpenAIHTTP.url(path: "/v1/audio/speech")
        guard let url else {
            fail(useCloudBackend ? "Invalid Crow Cloud speech URL" : "Invalid OpenAI speech URL")
            return
        }
        guard useCloudBackend || CrowOpenAIHTTP.apiKey() != nil else {
            fail("OpenAI API key is not configured")
            return
        }

        let model = (CrowEnvironment.value("CROW_OPENAI_TTS_MODEL") ?? "gpt-4o-mini-tts")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (CrowEnvironment.value("CROW_OPENAI_TTS_VOICE") ?? "marin")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var request = useCloudBackend ? CrowCloudHTTP.request(url: url) : CrowOpenAIHTTP.request(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any]
        if useCloudBackend {
            payload = [
                "text": text,
                "voice": voice.isEmpty ? "marin" : voice,
                "format": "mp3"
            ]
        } else {
            payload = [
                "model": model.isEmpty ? "gpt-4o-mini-tts" : model,
                "voice": voice.isEmpty ? "marin" : voice,
                "input": text,
                "response_format": "mp3"
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        CrowMacLog("speech request provider=\(useCloudBackend ? "cloud" : "openai") url=\(url.absoluteString) chars=\(text.count)")

        let task = URLSession(configuration: CrowProxySettings.urlSessionConfiguration()).dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                CrowMacLog("speech request error \(error.localizedDescription)")
                self.fail(error.localizedDescription)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if self.useCloudBackend, status == 401, allowTokenRefresh {
                CrowMacLog("speech request unauthorized refreshing token")
                CrowCloudDevice.clearStoredToken()
                CrowCloudDevice.ensureActivated { [weak self] _ in
                    self?.requestSpeech(text, allowTokenRefresh: false)
                }
                return
            }
            guard let data, (200..<300).contains(status), !data.isEmpty else {
                let providerName = self.useCloudBackend ? "Crow Cloud speech" : "OpenAI speech"
                CrowMacLog("speech request failed status=\(status) bytes=\(data?.count ?? 0)")
                self.fail(CrowOpenAIHTTP.errorMessage(from: data) ?? "\(providerName) failed with status \(status)")
                return
            }
            CrowMacLog("speech request ok status=\(status) bytes=\(data.count)")
            DispatchQueue.main.async {
                self.play(data)
            }
        }
        dataTask = task
        task.resume()
    }

    func stop() {
        dataTask?.cancel()
        dataTask = nil
        player?.stop()
        player = nil
        onStarted = nil
        onFinished = nil
        onFailed = nil
        didComplete = false
    }

    private func play(_ data: Data) {
        guard !didComplete else {
            return
        }
        do {
            let nextPlayer = try AVAudioPlayer(data: data)
            nextPlayer.delegate = self
            nextPlayer.prepareToPlay()
            player = nextPlayer
            onStarted?()
            if !nextPlayer.play() {
                fail("OpenAI speech audio could not be played")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finish() {
        guard !didComplete else {
            return
        }
        didComplete = true
        player = nil
        DispatchQueue.main.async { [onFinished] in
            onFinished?()
        }
    }

    private func fail(_ message: String) {
        guard !didComplete else {
            return
        }
        didComplete = true
        dataTask?.cancel()
        dataTask = nil
        player?.stop()
        player = nil
        DispatchQueue.main.async { [onFailed] in
            onFailed?(message)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish()
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        fail(error?.localizedDescription ?? "OpenAI speech audio decode failed")
    }
}

final class CrowOpenAIStreamingTTSSpeaker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let useCloudBackend: Bool
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var pendingBytes = Data()
    private var scheduledBuffers = 0
    private var didReceiveAudio = false
    private var didFinishNetwork = false
    private var didStartPlayback = false
    private var didComplete = false
    private var onStarted: (() -> Void)?
    private var onFinished: (() -> Void)?
    private var onFailed: ((String) -> Void)?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    init(useCloudBackend: Bool = false) {
        self.useCloudBackend = useCloudBackend
        super.init()
    }

    @MainActor
    func speak(
        _ text: String,
        onStarted: @escaping () -> Void,
        onFinished: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        stop()
        self.onStarted = onStarted
        self.onFinished = onFinished
        self.onFailed = onFailed

        let url = useCloudBackend
            ? URL(string: CrowCloudHTTP.baseURL() + "/v1/voice/speech-stream")
            : CrowOpenAIHTTP.url(path: "/v1/audio/speech")
        guard let url else {
            fail(useCloudBackend ? "Invalid Crow Cloud speech stream URL" : "Invalid OpenAI speech stream URL")
            return
        }
        guard useCloudBackend || CrowOpenAIHTTP.apiKey() != nil else {
            fail("OpenAI API key is not configured")
            return
        }

        let model = (CrowEnvironment.value("CROW_OPENAI_TTS_MODEL") ?? "gpt-4o-mini-tts")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (CrowEnvironment.value("CROW_OPENAI_TTS_VOICE") ?? "marin")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var request = useCloudBackend ? CrowCloudHTTP.request(url: url) : CrowOpenAIHTTP.request(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")

        let payload: [String: Any]
        if useCloudBackend {
            payload = [
                "text": text,
                "voice": voice.isEmpty ? "marin" : voice
            ]
        } else {
            payload = [
                "model": model.isEmpty ? "gpt-4o-mini-tts" : model,
                "voice": voice.isEmpty ? "marin" : voice,
                "input": text,
                "response_format": "pcm",
                "stream_format": "audio"
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let session = URLSession(
            configuration: CrowProxySettings.urlSessionConfiguration(),
            delegate: self,
            delegateQueue: nil
        )
        self.session = session
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }

    @MainActor
    func stop() {
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        stopPlayback()
        pendingBytes.removeAll()
        scheduledBuffers = 0
        didReceiveAudio = false
        didFinishNetwork = false
        didStartPlayback = false
        didComplete = false
        onStarted = nil
        onFinished = nil
        onFailed = nil
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            Task { @MainActor in
                self.fail("OpenAI speech stream failed with status \(status)")
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Task { @MainActor in
            self.enqueuePCMBytes(data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error = error as NSError?, error.code != NSURLErrorCancelled {
                self.fail(error.localizedDescription)
                return
            }
            self.didFinishNetwork = true
            self.flushPendingBytes()
            self.completeIfReady()
        }
    }

    @MainActor
    private func enqueuePCMBytes(_ data: Data) {
        guard !didComplete, !data.isEmpty else {
            return
        }
        pendingBytes.append(data)
        flushPendingBytes()
    }

    @MainActor
    private func flushPendingBytes() {
        let minimumStartBytes = Self.minimumInitialPCMBytes
        if !didStartPlayback, !didFinishNetwork, pendingBytes.count < minimumStartBytes {
            return
        }
        let usableBytes = pendingBytes.count - (pendingBytes.count % 2)
        guard usableBytes > 0 else {
            return
        }
        let chunk = pendingBytes.prefix(usableBytes)
        pendingBytes.removeFirst(usableBytes)
        guard let buffer = pcm16PlaybackBuffer(from: Data(chunk)) else {
            return
        }
        do {
            try ensurePlaybackEngine()
        } catch {
            fail(error.localizedDescription)
            return
        }

        didReceiveAudio = true
        didStartPlayback = true
        scheduledBuffers += 1
        onStarted?()
        playerNode?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                self.completeIfReady()
            }
        }
        if playerNode?.isPlaying != true {
            playerNode?.play()
        }
    }

    @MainActor
    private func ensurePlaybackEngine() throws {
        if playbackEngine != nil {
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
        try engine.start()
        playbackEngine = engine
        playerNode = player
    }

    @MainActor
    private func stopPlayback() {
        playerNode?.stop()
        playbackEngine?.stop()
        playerNode = nil
        playbackEngine = nil
    }

    @MainActor
    private func completeIfReady() {
        guard didFinishNetwork, scheduledBuffers == 0, !didComplete else {
            return
        }
        if didReceiveAudio {
            complete()
        } else {
            fail("OpenAI speech stream returned no audio")
        }
    }

    @MainActor
    private func complete() {
        guard !didComplete else {
            return
        }
        didComplete = true
        session?.finishTasksAndInvalidate()
        session = nil
        dataTask = nil
        stopPlayback()
        onFinished?()
    }

    @MainActor
    private func fail(_ message: String) {
        guard !didComplete else {
            return
        }
        didComplete = true
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        stopPlayback()
        onFailed?(message)
    }

    private func pcm16PlaybackBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channels = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<sampleCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                channels[0][index] = Float(sample) / Float(Int16.max)
            }
        }
        return buffer
    }

    private static var minimumInitialPCMBytes: Int {
        // 24 kHz * 16-bit mono * ~80 ms. This prevents underruns from very small HTTP chunks.
        3_840
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

    static func postPlaybackStarted(sessionID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .crowStreamingSpeechPlaybackStarted, object: nil, userInfo: [
                "id": sessionID
            ])
        }
    }

    static func postPlaybackEnded(sessionID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .crowStreamingSpeechPlaybackEnded, object: nil, userInfo: [
                "id": sessionID
            ])
        }
    }
}

extension Notification.Name {
    static let crowStreamingSpeechLevel = Notification.Name("dev.crow.streamingSpeech.level")
    static let crowStreamingSpeechTranscript = Notification.Name("dev.crow.streamingSpeech.transcript")
    static let crowStreamingSpeechError = Notification.Name("dev.crow.streamingSpeech.error")
    static let crowStreamingSpeechPlaybackStarted = Notification.Name("dev.crow.streamingSpeech.playbackStarted")
    static let crowStreamingSpeechPlaybackEnded = Notification.Name("dev.crow.streamingSpeech.playbackEnded")
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

    func reload() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        register()
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
    var stateProvider: (() -> IslandState?)?
    var approvalHandler: ((String, Bool) -> Void)?
    var voiceCommandHandler: ((String, String) -> Void)?

    private var panelWidth: CGFloat = 640
    private var panelHeight: CGFloat = 210
    private var panel: CrowPanel!
    private var islandView: CrowIslandView!

    /// Opens the island and speaks a reminder.
    func announceReminder(_ text: String) {
        islandView?.announceReminder(text)
    }
    private var stateTimer: Timer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var realtimeSpeaker: CrowOpenAIRealtimeSpeaker?
    private var openAITTSSpeaker: CrowOpenAITTSSpeaker?
    private var realtimeSpeechDisabledUntil: Date?
    private var lastSpeechKey = ""
    private var currentSpeechKey = ""
    private var spokenSpeechTexts: [String] = []
    private var speechQueue: [(key: String, text: String)] = []
    private var queuedSpeechKeys = Set<String>()
    private var voiceInputObserver: NSObjectProtocol?
    private var speechVisualHideWorkItem: DispatchWorkItem?
    private let launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        islandView.approvalHandler = { [weak self] approvalId, approved in
            self?.approvalHandler?(approvalId, approved)
        }
        islandView.voiceCommandHandler = { [weak self] text, mode in
            self?.voiceCommandHandler?(text, mode)
        }
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
        if let state = stateProvider?() {
            return state
        }
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
            state.title,
            state.updatedAt,
            speech
        ].joined(separator: "|")
        if key == lastSpeechKey || key == currentSpeechKey || queuedSpeechKeys.contains(key) {
            return
        }
        let spokenTextKey = compactSpeechText(speech)
        if hasRecentlySpoken(spokenTextKey) {
            lastSpeechKey = key
            return
        }
        lastSpeechKey = key

        guard shouldSpeak else {
            return
        }
        guard shouldSpeakState(state) else {
            return
        }
        // Don't talk over Crow's own reply; the approval panel is visible anyway.
        if (state.phase ?? "") == "approval", islandView.isVoiceReplyActive {
            CrowMacLog("approval prompt not spoken: voice reply in progress")
            return
        }
        rememberSpoken(spokenTextKey)
        CrowMacLog("speech enqueue provider=\(speechOutputProvider()) text=\(spokenTextKey)")
        // Synthesis takes a moment; the island must not start listening before the result is spoken.
        islandView.expectSpeech()
        speak(speech, key: key)
    }

    private func shouldSpeakState(_ state: IslandState) -> Bool {
        guard let updatedAt = parseStateUpdatedAt(state.updatedAt) else {
            return false
        }
        return updatedAt >= launchedAt.addingTimeInterval(-0.5)
    }

    private func parseStateUpdatedAt(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return nil
        }
        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFraction.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private func speechOutput(for state: IslandState) -> String? {
        let phase = (state.phase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case "speaking":
            return compactSpeechText(state.message)
        case "completed":
            if state.title == "Codex conclusion" {
                return compactSpeechText(state.message)
            }
            return localizedSpeech(prefixZH: "任务完成。", prefixEN: "Task complete. ", body: state.message)
        case "failed":
            return localizedSpeech(prefixZH: "任务失败，需要你查看。", prefixEN: "Task failed and needs your review. ", body: humanReadableFailure(state.message))
        case "approval":
            // The action names are English internal labels; the panel shows the details.
            return localizedSpeech(prefixZH: "需要你确认一下，请在灵动岛上点同意或拒绝。", prefixEN: "Please approve or reject on the island.", body: "")
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

    /// Markdown reads badly aloud: drop table rules, emphasis, code ticks and
    /// headings, and turn table cell borders into pauses.
    private func speakableText(_ value: String) -> String {
        var text = value
        let rules: [(String, String)] = [
            (#"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"#, ""), // |---|---|
            (#"(?m)^\s{0,3}(#{1,6}|>|[-*+])\s+"#, ""),                          // headings, quotes, bullets
            (#"\*\*|__|`+"#, ""),                                              // emphasis, code
            (#"[ \t]*\|[ \t]*"#, "，"),                                       // table cells
            (#"(，[ \t]*){2,}"#, "，"),
            (#"(?m)^，|，$"#, ""),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    private func compactSpeechText(_ value: String) -> String {
        var text = speakableText(value)
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

    private func hasRecentlySpoken(_ text: String) -> Bool {
        spokenSpeechTexts.contains(text)
    }

    private func rememberSpoken(_ text: String) {
        guard !text.isEmpty else { return }
        spokenSpeechTexts.append(text)
        if spokenSpeechTexts.count > 12 {
            spokenSpeechTexts.removeFirst(spokenSpeechTexts.count - 12)
        }
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

    private func speak(_ text: String, key: String) {
        let provider = speechOutputProvider()
        guard provider != "off" else {
            return
        }

        if speechSynthesizer.isSpeaking || realtimeSpeaker != nil || openAITTSSpeaker != nil || !speechQueue.isEmpty {
            speechQueue.append((key: key, text: text))
            queuedSpeechKeys.insert(key)
            islandView.isSpeaking = true
            return
        }

        startSpeechOutput(text, key: key, preferredProvider: provider)
    }

    private func speechOutputProvider() -> String {
        let ttsProvider = (CrowEnvironment.value("CROW_TTS_PROVIDER") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !ttsProvider.isEmpty {
            return ttsProvider
        }
        if CrowVoiceProvider.effective == "openai_realtime",
           realtimeSpeechDisabledUntil.map({ Date() < $0 }) != true {
            return "openai_realtime"
        }
        return "system"
    }

    private func startSpeechOutput(_ text: String, key: String, preferredProvider: String? = nil) {
        let provider = (preferredProvider ?? speechOutputProvider())
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard provider != "off" else {
            finishCurrentSpeechAndContinue()
            return
        }
        if provider == "openai_realtime" {
            startRealtimeSpeechOutput(text, key: key)
            return
        }
        if provider == "cloud" || provider == "crow_cloud" {
            CrowMacLog("speech start cloud text=\(compactSpeechText(text))")
            startOpenAITTSOutput(text, key: key, useCloudBackend: true)
            return
        }
        if provider == "openai" || provider == "openai_tts" {
            CrowMacLog("speech start openai text=\(compactSpeechText(text))")
            startOpenAITTSOutput(text, key: key, useCloudBackend: false)
            return
        }
        CrowMacLog("speech start system text=\(compactSpeechText(text))")
        startSystemSpeechOutput(text, key: key)
    }

    private func startRealtimeSpeechOutput(_ text: String, key: String) {
        let speaker = CrowOpenAIRealtimeSpeaker()
        realtimeSpeaker = speaker
        currentSpeechKey = key
        queuedSpeechKeys.remove(key)
        islandView.isSpeaking = true
        islandView.noteSpeechPlaybackStarted()
        speaker.speak(
            text,
            onStarted: { [weak self, weak speaker] in
                guard let self, self.realtimeSpeaker === speaker else { return }
                self.islandView.isSpeaking = true
                self.islandView.noteSpeechPlaybackStarted()
            },
            onFinished: { [weak self, weak speaker] in
                guard let self, self.realtimeSpeaker === speaker else { return }
                self.realtimeSpeaker = nil
                self.finishCurrentSpeechAndContinue()
            },
            onFailed: { [weak self, weak speaker] message in
                guard let self, self.realtimeSpeaker === speaker else { return }
                NSLog("Crow Realtime speech failed, falling back to system voice: \(message)")
                self.realtimeSpeechDisabledUntil = Date().addingTimeInterval(Self.realtimeFailureCooldownSeconds())
                self.realtimeSpeaker = nil
                self.startSystemSpeechOutput(text, key: key)
            }
        )
    }

    private func startOpenAITTSOutput(_ text: String, key: String, useCloudBackend: Bool) {
        let speaker = CrowOpenAITTSSpeaker(useCloudBackend: useCloudBackend)
        openAITTSSpeaker = speaker
        currentSpeechKey = key
        queuedSpeechKeys.remove(key)
        islandView.isSpeaking = true
        islandView.noteSpeechPlaybackStarted()
        speaker.speak(
            text,
            onStarted: { [weak self, weak speaker] in
                guard let self, self.openAITTSSpeaker === speaker else { return }
                CrowMacLog("speech cloud playback started")
                self.islandView.isSpeaking = true
                self.islandView.noteSpeechPlaybackStarted()
            },
            onFinished: { [weak self, weak speaker] in
                guard let self, self.openAITTSSpeaker === speaker else { return }
                CrowMacLog("speech cloud playback finished")
                self.openAITTSSpeaker = nil
                self.finishCurrentSpeechAndContinue()
            },
            onFailed: { [weak self, weak speaker] message in
                guard let self, self.openAITTSSpeaker === speaker else { return }
                CrowMacLog("speech cloud failed \(message)")
                NSLog("Crow OpenAI speech failed, falling back to system voice: \(message)")
                self.openAITTSSpeaker = nil
                self.startSystemSpeechOutput(text, key: key)
            }
        )
    }

    private static func realtimeFailureCooldownSeconds() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_REALTIME_FAILURE_COOLDOWN_SECONDS"),
              let value = TimeInterval(raw) else {
            return 300
        }
        return max(0, value)
    }

    private func startSystemSpeechOutput(_ text: String, key: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = speechVoice()
        currentSpeechKey = key
        queuedSpeechKeys.remove(key)
        islandView.isSpeaking = true
        scheduleSpeechVisualHide(for: text)
        speechSynthesizer.speak(utterance)
    }

    private func stopSpeechOutput() {
        speechVisualHideWorkItem?.cancel()
        speechVisualHideWorkItem = nil
        speechQueue.removeAll()
        queuedSpeechKeys.removeAll()
        currentSpeechKey = ""
        realtimeSpeaker?.stop()
        realtimeSpeaker = nil
        openAITTSSpeaker?.stop()
        openAITTSSpeaker = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        islandView.isSpeaking = false
        islandView.noteSpeechPlaybackEnded()
    }

    private func finishCurrentSpeechAndContinue() {
        speechVisualHideWorkItem?.cancel()
        speechVisualHideWorkItem = nil
        currentSpeechKey = ""
        if let next = speechQueue.first {
            speechQueue.removeFirst()
            startSpeechOutput(next.text, key: next.key)
        } else {
            islandView.isSpeaking = false
            islandView.noteSpeechPlaybackEnded()
        }
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
            self.finishCurrentSpeechAndContinue()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speechVisualHideWorkItem?.cancel()
            self.speechVisualHideWorkItem = nil
            self.speechQueue.removeAll()
            self.queuedSpeechKeys.removeAll()
            self.currentSpeechKey = ""
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

enum IslandAvatarStyle: String {
    case `default`
    case cute
    case robot
    case jarvis

    static var configured: IslandAvatarStyle {
        let raw = (CrowEnvironment.value("CROW_ISLAND_AVATAR_STYLE") ?? "default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "cute", "cute_crow", "cute-crow":
            return .cute
        case "robot", "robot_face", "robot-face":
            return .robot
        case "jarvis", "jarvis_core", "jarvis-core", "core":
            return .jarvis
        default:
            return .default
        }
    }
}

@MainActor
final class CrowIslandView: NSView {
    private let geometry: IslandGeometry
    var approvalHandler: ((String, Bool) -> Void)?
    var voiceCommandHandler: ((String, String) -> Void)?

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
    private var expansionProgress: CGFloat = 0
    private var renderedVisualState: IslandVisualState = .idle
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
    private var voiceHint = L("Tap to stop. Auto-creates after silence.")
    private var inputLevel: CGFloat = 0
    private var silentSince: Date?
    private var noiseFloorPower: Float = -58
    private var speechPeakPower: Float = -58
    private var lastSpeechActivityAt: Date?
    private var lastTranscriptUpdateAt: Date?
    private var didHearSpeechInCurrentCapture = false
    private var autoCloseWorkItem: DispatchWorkItem?
    private var continueListeningWorkItem: DispatchWorkItem?
    private var noSpeechCloseWorkItem: DispatchWorkItem?
    private var retryListeningWorkItem: DispatchWorkItem?
    private var finalTranscriptTimeoutWorkItem: DispatchWorkItem?
    private var captureStartedAt: Date?
    private var voiceSubmittedAt: Date?
    private var lastVoiceUserText = ""
    private var isVoiceConversationActive = false
    private var streamingSession: CrowVoiceInputSession?
    private var realtimeInputDisabledUntil: Date?
    private var pendingFinalTranscriptSubmission = false
    private var streamingObserverTokens: [NSObjectProtocol] = []
    private var voiceResponseSpeaker: CrowOpenAITTSSpeaker?
    private var voiceStreamingSpeaker: CrowOpenAIStreamingTTSSpeaker?
    private var voiceSpeechBuffer = ""
    private var voiceSpeechQueue: [String] = []
    private var voiceAgentStream: CrowAgentStream?
    /// A task result is being synthesized and will be spoken; don't start listening yet.
    private var isAwaitingSpeech = false
    private var awaitingSpeechTimeout: DispatchWorkItem?
    private var isVoiceSpeechInputFinished = false
    private var didStartVoiceSpeechOutput = false
    private var shouldContinueAfterVoiceSpeech = false
    private let voiceResponseSynthesizer = AVSpeechSynthesizer()
    private var animationTimer: Timer?
    private var trackingArea: NSTrackingArea?

    private var visualState: IslandVisualState {
        if isExpanded {
            if isTranscribing || isFinishingVoiceCapture {
                return .thinking
            }
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

    static func sttFallbackProvider() -> String {
        (CrowEnvironment.value("CROW_STT_FALLBACK") ?? "system")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func updateRuntimeState(_ nextState: IslandState) {
        let wasApproval = executionPhase == "approval"
        state = nextState
        updateVoiceConversation(from: nextState)
        if executionPhase == "approval" {
            // Keep the island open while waiting for the user's decision.
            cancelAutoClose()
            if !wasApproval {
                needsDisplay = true
                snapshotApprovalIfRequested()
            }
        }
    }

    /// Development aid: with CROW_ISLAND_SNAPSHOT=<file.png>, renders the island when an
    /// approval appears. It draws only Crow's own view: no screen capture.
    private func snapshotApprovalIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CROW_ISLAND_SNAPSHOT"], !path.isEmpty else { return }
        // CROW_ISLAND_SNAPSHOT_VOICE=<text> reproduces an approval arriving over an open voice panel.
        if let text = environment["CROW_ISLAND_SNAPSHOT_VOICE"], !text.isEmpty {
            isAwake = true
            isExpanded = true
            expansionProgress = 1
            didSubmitVoiceCommand = true
            voiceAgentText = text
            voiceAgentPhase = "running"
            needsDisplay = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let rep = self.bitmapImageRepForCachingDisplay(in: self.bounds) else { return }
            self.cacheDisplay(in: self.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// A task result is about to be spoken. Listening waits for the end of playback
    /// (noteSpeechPlaybackEnded), or a timeout if speech never starts or ends.
    func expectSpeech() {
        isAwaitingSpeech = true
        cancelContinueListening()
        awaitingSpeechTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isAwaitingSpeech else { return }
            CrowMacLog("speech never finished; resuming listening")
            self.isAwaitingSpeech = false
            if self.voiceAgentPhase == "completed" || self.voiceAgentPhase == "speaking" {
                self.scheduleContinueListeningIfNeeded(after: self.lastVoiceUserText)
            }
        }
        awaitingSpeechTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    func noteSpeechPlaybackStarted() {
        isAwaitingSpeech = false
        guard isExpanded, didSubmitVoiceCommand else {
            return
        }
        cancelAutoClose()
        voiceAgentPhase = "speaking"
        voiceHint = L("Crow is speaking")
        needsDisplay = true
    }

    func noteSpeechPlaybackEnded() {
        isAwaitingSpeech = false
        awaitingSpeechTimeout?.cancel()
        guard isExpanded, didSubmitVoiceCommand, !voiceAgentText.isEmpty else {
            return
        }
        if voiceAgentPhase == "completed" || voiceAgentPhase == "speaking" {
            scheduleContinueListeningIfNeeded(after: lastVoiceUserText)
        }
    }

    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.phase += 0.18
                self.updateProximityFromMouse()
                self.updateVisualStateTransition()
                let targetScale: CGFloat = 1 + self.proximity * 0.07
                self.hoverScale += (targetScale - self.hoverScale) * 0.28
                let targetExpansion: CGFloat = self.isExpanded ? 1 : 0
                self.expansionProgress += (targetExpansion - self.expansionProgress) * 0.34
                if abs(targetExpansion - self.expansionProgress) < 0.006 {
                    self.expansionProgress = targetExpansion
                }
                self.needsDisplay = true
            }
        }
    }

    private func updateVisualStateTransition() {
        let target = visualState
        if target != renderedVisualState {
            renderedVisualState = target
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

        // A pending approval takes over the island, also over an open voice panel
        // (e.g. right after a hand-off), unless the user is speaking.
        if isShowingApproval {
            drawApprovalPanel()
        } else if isExpanded || expansionProgress > 0.01 {
            drawVoicePanel()
        } else if shouldShowCompactBar {
            drawBar()
        }
    }

    private var isShowingApproval: Bool {
        executionPhase == "approval" && !isRecording && !isTranscribing
    }

    private var shouldShowCompactBar: Bool {
        if expansionProgress > 0.01 {
            return true
        }
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
        if isShowingApproval {
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
        if isExpanded, finalVoicePanelRect.contains(point) {
            if isRecording {
                finishVoiceCapture()
            } else if isAwaitingVoiceConfirmation {
                confirmVoiceCommand()
            } else {
                closeVoicePanel(force: true, reason: "mouse")
            }
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isExpanded {
            closeVoicePanel(force: true, reason: "right-click")
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
            } else if isVoiceAgentBusy {
                // Barge-in: stop Crow and listen. A delegated Codex task keeps running.
                interruptVoiceAgent()
                isVoiceConversationActive = true
                beginVoiceCapture()
            }
            return
        }
        wakeVoicePanel()
    }

    /// Opens the island and speaks a reminder, unless the user is talking to Crow,
    /// in which case the notification alone carries it.
    func announceReminder(_ text: String) {
        guard !isRecording, !isTranscribing, !isVoiceAgentBusy else {
            CrowMacLog("reminder not spoken: island busy")
            return
        }
        cancelAutoClose()
        cancelContinueListening()
        isVoiceConversationActive = false
        isAwake = true
        isExpanded = true
        lastVoiceUserText = ""
        voiceAgentText = "⏰ " + text
        voiceHint = L("Reminder")
        needsDisplay = true
        playVoiceAgentResponse(text)
    }

    /// Crow is generating or speaking a voice reply.
    var isVoiceReplyActive: Bool { isVoiceAgentBusy || isSpeaking }

    /// Crow is waiting on the model or speaking.
    private var isVoiceAgentBusy: Bool {
        voiceAgentStream != nil
            || voiceResponseSpeaker != nil
            || voiceStreamingSpeaker != nil
            || voiceResponseSynthesizer.isSpeaking
            || !voiceSpeechQueue.isEmpty
    }

    /// Stops the in-flight turn (pending tool steps are skipped) and any speech.
    private func interruptVoiceAgent() {
        CrowMacLog("voice agent interrupted phase=\(voiceAgentPhase)")
        voiceAgentStream?.cancel()
        voiceAgentStream = nil
        cancelAutoClose()
        cancelContinueListening()
        resetVoiceAgentSpeechOutput(stopPlayback: true)
        voiceAgentPhase = ""
        needsDisplay = true
    }

    private func wakeVoicePanel() {
        cancelAutoClose()
        cancelContinueListening()
        cancelNoSpeechClose()
        cancelRetryListening()
        isVoiceConversationActive = true
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
        cancelAutoClose()
        cancelContinueListening()
        cancelNoSpeechClose()
        cancelRetryListening()
        NotificationCenter.default.post(name: .crowVoiceInputStarted, object: nil)
        let keepPreviousResponse = isVoiceConversationActive
            && !lastVoiceUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !voiceAgentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        voiceTranscript = ""
        voiceHint = isVoiceConversationActive ? L("Listening for your reply...") : L("Requesting speech access...")
        isAwaitingVoiceConfirmation = false
        didSubmitVoiceCommand = false
        voiceSubmittedAt = nil
        pendingFinalTranscriptSubmission = false
        didHearSpeechInCurrentCapture = false
        finalTranscriptTimeoutWorkItem?.cancel()
        finalTranscriptTimeoutWorkItem = nil
        if !keepPreviousResponse {
            voiceAgentText = ""
            voiceAgentPhase = ""
        }
        needsDisplay = true

        CrowPermissionBridge.requestSpeech { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.voiceHint = L("Speech recognition denied. No task will be created.")
                    self.needsDisplay = true
                    return
                }

                self.voiceHint = L("Requesting microphone access...")
                self.needsDisplay = true
                CrowPermissionBridge.requestMicrophone { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if granted {
                            self.startStreamingRecognition()
                        } else {
                            self.voiceHint = L("Microphone access denied. No task will be created.")
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

        if let fallbackReason = CrowVoiceProvider.fallbackReason {
            voiceHint = fallbackReason
            needsDisplay = true
        }

        let session = makeVoiceInputSession()
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
            voiceHint = L("Listening...")
            CrowMacLog("voice capture started session=\(session.id) provider=\(type(of: session))")
            scheduleNoSpeechClose()
            needsDisplay = true
        } catch {
            stopStreamingRecognition(cancel: true)
            if session is CrowOpenAITranscriptionSession, Self.sttFallbackProvider() == "system" {
                startSystemRecognitionAfterOpenAIFailure(error)
                return
            }
            if session is CrowOpenAIRealtimeSpeechSession {
                startSystemRecognitionAfterRealtimeFailure(error)
                return
            }
            voiceHint = "Speech capture failed: \(Self.compactHint(error.localizedDescription))"
            NSLog("Crow Island failed to start streaming recognition: \(error.localizedDescription)")
            needsDisplay = true
            scheduleAutoClose(delay: Self.voicePanelIdleCloseDelay())
        }
    }

    private func startSystemRecognitionAfterRealtimeFailure(_ error: Error) {
        realtimeInputDisabledUntil = Date().addingTimeInterval(Self.realtimeFailureCooldownSeconds())
        voiceHint = L("OpenAI Realtime unavailable. Using system voice.")
        NSLog("Crow Island OpenAI Realtime unavailable: \(error.localizedDescription)")
        needsDisplay = true

        let fallback = CrowSystemSpeechSession()
        installStreamingObservers(for: fallback.id)
        do {
            try fallback.start(localeIdentifier: Self.speechLocaleIdentifier())
            streamingSession = fallback
            isRecording = true
            isTranscribing = false
            captureStartedAt = Date()
            silentSince = nil
            noiseFloorPower = -58
            speechPeakPower = -58
            lastSpeechActivityAt = nil
            lastTranscriptUpdateAt = nil
            inputLevel = 0
            voiceHint = L("Listening with system speech...")
            scheduleNoSpeechClose()
            needsDisplay = true
        } catch {
            stopStreamingRecognition(cancel: true)
            voiceHint = "Speech capture failed: \(Self.compactHint(error.localizedDescription))"
            NSLog("Crow Island system speech fallback failed: \(error.localizedDescription)")
            needsDisplay = true
            scheduleAutoClose(delay: Self.voicePanelIdleCloseDelay())
        }
    }

    private func startSystemRecognitionAfterOpenAIFailure(_ error: Error) {
        voiceHint = L("OpenAI STT unavailable. Using system speech.")
        NSLog("Crow Island OpenAI STT unavailable: \(error.localizedDescription)")
        needsDisplay = true

        let fallback = CrowSystemSpeechSession()
        installStreamingObservers(for: fallback.id)
        do {
            try fallback.start(localeIdentifier: Self.speechLocaleIdentifier())
            streamingSession = fallback
            isRecording = true
            isTranscribing = false
            captureStartedAt = Date()
            silentSince = nil
            noiseFloorPower = -58
            speechPeakPower = -58
            lastSpeechActivityAt = nil
            lastTranscriptUpdateAt = nil
            inputLevel = 0
            voiceHint = L("Listening with system speech...")
            scheduleNoSpeechClose()
            needsDisplay = true
        } catch {
            stopStreamingRecognition(cancel: true)
            voiceHint = "Speech capture failed: \(Self.compactHint(error.localizedDescription))"
            NSLog("Crow Island system speech fallback failed: \(error.localizedDescription)")
            needsDisplay = true
            scheduleAutoClose(delay: Self.voicePanelIdleCloseDelay())
        }
    }

    private func makeVoiceInputSession() -> CrowVoiceInputSession {
        let sttProvider = (CrowEnvironment.value("CROW_STT_PROVIDER") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if sttProvider == "cloud" || sttProvider == "crow_cloud" {
            return CrowOpenAITranscriptionSession(useCloudBackend: true)
        }
        if sttProvider == "openai" || sttProvider == "openai_transcribe" {
            return CrowOpenAITranscriptionSession()
        }
        if CrowVoiceProvider.effective == "openai_realtime",
           realtimeInputDisabledUntil.map({ Date() < $0 }) != true {
            return CrowOpenAIRealtimeSpeechSession()
        }
        return CrowSystemSpeechSession()
    }

    private func finishVoiceCapture() {
        if isTranscribing || isFinishingVoiceCapture {
            return
        }

        if isRecording {
            cancelNoSpeechClose()
            isFinishingVoiceCapture = true
            let shouldKeepSessionAlive = streamingSession?.keepsSessionAliveAfterInputStop == true
            if shouldKeepSessionAlive {
                streamingSession?.stopInput()
            } else {
                streamingSession?.stop(cancel: true)
                streamingSession = nil
                removeStreamingObservers()
            }
            isRecording = false
            isTranscribing = true
            voiceHint = L("Finalizing transcript...")
            needsDisplay = true

            if shouldKeepSessionAlive {
                pendingFinalTranscriptSubmission = true
                scheduleFinalTranscriptTimeout()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                self.submitCurrentTranscript()
            }
            return
        }

        voiceHint = missingTranscriptMessage()
        needsDisplay = true
        scheduleRetryListening()
    }

    private func closeVoicePanel(force: Bool = false, reason: String = "programmatic") {
        if !force && shouldKeepVoicePanelOpenForConversation() {
            CrowMacLog("voice panel close blocked reason=\(reason) phase=\(voiceAgentPhase) didSubmit=\(didSubmitVoiceCommand) recording=\(isRecording) transcribing=\(isTranscribing)")
            needsDisplay = true
            return
        }
        CrowMacLog("voice panel close reason=\(reason) force=\(force) phase=\(voiceAgentPhase) didSubmit=\(didSubmitVoiceCommand)")
        cancelAutoClose()
        cancelContinueListening()
        cancelNoSpeechClose()
        cancelRetryListening()
        stopStreamingRecognition(cancel: true)
        voiceAgentStream?.cancel()
        voiceAgentStream = nil
        resetVoiceAgentSpeechOutput(stopPlayback: true)
        voiceResponseSpeaker?.stop()
        voiceResponseSpeaker = nil
        voiceStreamingSpeaker?.stop()
        voiceStreamingSpeaker = nil
        if voiceResponseSynthesizer.isSpeaking {
            voiceResponseSynthesizer.stopSpeaking(at: .immediate)
        }
        isExpanded = false
        isAwake = false
        isRecording = false
        isTranscribing = false
        isFinishingVoiceCapture = false
        isAwaitingVoiceConfirmation = false
        didSubmitVoiceCommand = false
        isVoiceConversationActive = false
        lastVoiceUserText = ""
        voiceTranscript = ""
        voiceAgentText = ""
        voiceAgentPhase = ""
        voiceHint = L("Tap to stop. Auto-creates after silence.")
        inputLevel = 0
        silentSince = nil
        noiseFloorPower = -58
        speechPeakPower = -58
        lastSpeechActivityAt = nil
        lastTranscriptUpdateAt = nil
        didHearSpeechInCurrentCapture = false
        captureStartedAt = nil
        voiceSubmittedAt = nil
        pendingFinalTranscriptSubmission = false
        finalTranscriptTimeoutWorkItem?.cancel()
        finalTranscriptTimeoutWorkItem = nil
        needsDisplay = true
    }

    private func stopStreamingInput() {
        streamingSession?.stopInput()
    }

    private func stopStreamingRecognition(cancel: Bool) {
        if cancel {
            pendingFinalTranscriptSubmission = false
            finalTranscriptTimeoutWorkItem?.cancel()
            finalTranscriptTimeoutWorkItem = nil
        }
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
                CrowMacLog("voice transcript event final=\(isFinal) chars=\(text.trimmingCharacters(in: .whitespacesAndNewlines).count)")
                if text != self.voiceTranscript {
                    self.lastTranscriptUpdateAt = Date()
                    self.lastSpeechActivityAt = Date()
                    self.didHearSpeechInCurrentCapture = true
                    self.silentSince = nil
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.cancelNoSpeechClose()
                    }
                }
                self.voiceTranscript = text
                self.voiceHint = isFinal ? L("Final transcript ready.") : L("Listening...")
                self.needsDisplay = true
                if isFinal, self.pendingFinalTranscriptSubmission {
                    self.pendingFinalTranscriptSubmission = false
                    self.finalTranscriptTimeoutWorkItem?.cancel()
                    self.finalTranscriptTimeoutWorkItem = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        guard let self else { return }
                        self.submitCurrentTranscript()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.stopStreamingRecognition(cancel: false)
                        }
                    }
                }
            }
        }

        let errorToken = center.addObserver(forName: .crowStreamingSpeechError, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  notification.userInfo?["id"] as? String == sessionID else {
                return
            }
            let message = notification.userInfo?["message"] as? String ?? "Speech recognition failed"
            Task { @MainActor in
                CrowMacLog("voice recognition error pendingFinal=\(self.pendingFinalTranscriptSubmission) transcriptChars=\(self.voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count) message=\(message)")
                if self.streamingSession is CrowOpenAIRealtimeSpeechSession,
                   self.isRecording,
                   self.voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.startSystemRecognitionAfterRealtimeFailure(NSError(
                        domain: "CrowOpenAIRealtimeSpeechSession",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                    return
                }
                if self.pendingFinalTranscriptSubmission {
                    self.pendingFinalTranscriptSubmission = false
                    self.finalTranscriptTimeoutWorkItem?.cancel()
                    self.finalTranscriptTimeoutWorkItem = nil
                    if !self.voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.voiceHint = L("Using live transcript...")
                        self.submitCurrentTranscript()
                    } else {
                        self.isTranscribing = false
                        self.isFinishingVoiceCapture = false
                        self.voiceHint = L("Speech recognition failed. Listening again...")
                        self.needsDisplay = true
                        self.scheduleRetryListening()
                    }
                    return
                }
                if self.voiceTranscript.isEmpty {
                    self.voiceHint = L("Speech recognition failed. Listening again...")
                    self.needsDisplay = true
                    self.scheduleRetryListening()
                }
            }
        }

        let playbackStartedToken = center.addObserver(forName: .crowStreamingSpeechPlaybackStarted, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  notification.userInfo?["id"] as? String == sessionID else {
                return
            }
            Task { @MainActor in
                self.voiceAgentPhase = "speaking"
                self.voiceHint = L("Crow is speaking")
                self.needsDisplay = true
            }
        }

        let playbackEndedToken = center.addObserver(forName: .crowStreamingSpeechPlaybackEnded, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  notification.userInfo?["id"] as? String == sessionID else {
                return
            }
            Task { @MainActor in
                if self.didSubmitVoiceCommand {
                    self.scheduleContinueListeningIfNeeded(after: self.lastVoiceUserText)
                }
                self.needsDisplay = true
            }
        }

        streamingObserverTokens = [levelToken, transcriptToken, errorToken, playbackStartedToken, playbackEndedToken]
    }

    private func removeStreamingObservers() {
        let center = NotificationCenter.default
        for token in streamingObserverTokens {
            center.removeObserver(token)
        }
        streamingObserverTokens = []
    }

    private func scheduleFinalTranscriptTimeout() {
        finalTranscriptTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingFinalTranscriptSubmission else {
                return
            }
            CrowMacLog("voice final transcript timeout transcriptChars=\(self.voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count)")
            self.pendingFinalTranscriptSubmission = false
            self.submitCurrentTranscript()
            self.stopStreamingRecognition(cancel: false)
        }
        finalTranscriptTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: item)
    }

    private func submitCurrentTranscript() {
        finalTranscriptTimeoutWorkItem?.cancel()
        finalTranscriptTimeoutWorkItem = nil
        pendingFinalTranscriptSubmission = false
        let cleaned = voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        CrowMacLog("voice submit transcript chars=\(cleaned.count) recording=\(isRecording) transcribing=\(isTranscribing)")
        if cleaned.isEmpty {
            voiceHint = missingTranscriptMessage()
            isTranscribing = false
            isFinishingVoiceCapture = false
            scheduleRetryListening()
        } else {
            cancelNoSpeechClose()
            isVoiceConversationActive = true
            lastVoiceUserText = cleaned
            didSubmitVoiceCommand = true
            isAwaitingVoiceConfirmation = false
            voiceSubmittedAt = Date()
            voiceAgentText = ""
            voiceAgentPhase = "responding"
            voiceHint = L("Crow is thinking")
            resetVoiceAgentSpeechOutput(stopPlayback: true)
            // The agent decides whether to answer or hand off to Codex (delegate_to_codex).
            CrowMacLog("voice submit crow agent chars=\(cleaned.count)")
            respondToVoiceWithCrowAgent(text: cleaned)
        }
        isTranscribing = false
        isFinishingVoiceCapture = false
        inputLevel = 0
        needsDisplay = true
    }

    private func respondToVoiceWithCrowAgent(text: String) {
        // Set once the turn has started; a retry after that could repeat tool side effects.
        let started = VoiceTurnFlag()
        voiceAgentStream?.cancel()
        voiceAgentStream = CrowAgent.respondStream(input: text, onDelta: { [weak self] delta in
            DispatchQueue.main.async {
                guard let self else { return }
                started.value = true
                self.cancelAutoClose()
                self.isAwake = true
                self.isExpanded = true
                self.voiceAgentPhase = "responding"
                self.voiceHint = L("Crow is responding")
                self.voiceAgentText.append(delta)
                self.enqueueVoiceAgentSpeech(delta: delta, flush: false)
                self.needsDisplay = true
            }
        }, onActivity: { [weak self] activity in
            DispatchQueue.main.async {
                started.value = true
                guard let self, self.voiceAgentText.isEmpty else { return }
                self.voiceHint = L(activity.label)
                self.needsDisplay = true
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.voiceAgentStream = nil
                switch result {
                case .success(let response):
                    let answer = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.cancelAutoClose()
                    self.isAwake = true
                    self.isExpanded = true
                    self.voiceAgentText = answer
                    self.voiceAgentPhase = response.needExecutor ? "running" : "speaking"
                    self.voiceHint = response.needExecutor ? L("Delegating task") : L("Crow is speaking")
                    self.needsDisplay = true

                    if response.needExecutor {
                        if self.didStartVoiceSpeechOutput || !self.voiceSpeechQueue.isEmpty || !self.voiceSpeechBuffer.isEmpty {
                            self.finishVoiceAgentStreamingSpeech(continueConversation: false)
                        }
                        self.handOffVoiceCommand(response, originalText: text)
                    } else {
                        if !answer.isEmpty {
                            if self.didStartVoiceSpeechOutput || !self.voiceSpeechQueue.isEmpty || !self.voiceSpeechBuffer.isEmpty {
                                self.finishVoiceAgentStreamingSpeech(continueConversation: true)
                            } else {
                                self.playVoiceAgentResponse(answer)
                            }
                        } else {
                            self.scheduleContinueListeningIfNeeded(after: self.lastVoiceUserText)
                        }
                    }
                case .failure(let error) where started.value:
                    self.showVoiceAgentFailure(error)
                case .failure(let error):
                    CrowMacLog("agent voice stream failed falling back to non-stream \(error.localizedDescription)")
                    self.respondToVoiceWithCrowAgentFallback(text: text)
                }
            }
        })
    }

    /// Submits the executor task written by the agent, falling back to the user's words.
    private func handOffVoiceCommand(_ response: CrowAgentResponse, originalText: String) {
        let task = (response.executorTask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isComputer = response.executorHint == "computer"
        voiceHint = isComputer ? L("Using the computer") : L("Starting Codex")
        CrowMacLog("voice handoff executor=\(response.executorHint ?? "") taskChars=\(task.count)")
        submitVoiceCommand(text: task.isEmpty ? originalText : task, audioURL: nil, mode: isComputer ? "computer" : "agent")
        scheduleAutoClose(delay: Self.voiceConversationNoResponseCloseDelay())
    }

    private func respondToVoiceWithCrowAgentFallback(text: String) {
        CrowAgent.respond(input: text) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let response):
                    let answer = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.cancelAutoClose()
                    self.isAwake = true
                    self.isExpanded = true
                    self.voiceAgentText = answer
                    self.voiceAgentPhase = response.needExecutor ? "running" : "speaking"
                    self.voiceHint = response.needExecutor ? L("Delegating task") : L("Crow is speaking")
                    self.needsDisplay = true

                    if response.needExecutor {
                        self.handOffVoiceCommand(response, originalText: text)
                    } else {
                        if !answer.isEmpty {
                            self.playVoiceAgentResponse(answer)
                        } else {
                            self.scheduleContinueListeningIfNeeded(after: self.lastVoiceUserText)
                        }
                    }
                case .failure(let error):
                    self.showVoiceAgentFailure(error)
                }
            }
        }
    }

    private func showVoiceAgentFailure(_ error: Error) {
        let message = "Crow 暂时无法连接模型：\(Self.compactHint(error.localizedDescription))"
        CrowMacLog("agent voice failed \(error.localizedDescription)")
        resetVoiceAgentSpeechOutput(stopPlayback: true)
        voiceAgentText = message
        voiceAgentPhase = "failed"
        voiceHint = L("Model unavailable")
        needsDisplay = true
        playVoiceAgentSystemFallback(message)
    }

    private func resetVoiceAgentSpeechOutput(stopPlayback: Bool) {
        voiceSpeechBuffer = ""
        voiceSpeechQueue.removeAll()
        isVoiceSpeechInputFinished = false
        didStartVoiceSpeechOutput = false
        shouldContinueAfterVoiceSpeech = false
        if stopPlayback {
            voiceResponseSpeaker?.stop()
            voiceResponseSpeaker = nil
            voiceStreamingSpeaker?.stop()
            voiceStreamingSpeaker = nil
            if voiceResponseSynthesizer.isSpeaking {
                voiceResponseSynthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    private func enqueueVoiceAgentSpeech(delta: String, flush: Bool) {
        guard Self.voiceTTSStreamingEnabled() else {
            return
        }
        let cleaned = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            voiceSpeechBuffer.append(delta)
        }

        let segments = drainVoiceSpeechSegments(flush: flush)
        guard !segments.isEmpty else {
            return
        }
        voiceSpeechQueue.append(contentsOf: segments)
        didStartVoiceSpeechOutput = true
        CrowMacLog("voice tts queued segments=\(segments.count) pending=\(voiceSpeechQueue.count) audioStreaming=\(Self.voiceAudioStreamingEnabled())")
        startNextVoiceSpeechSegmentIfNeeded()
    }

    private func finishVoiceAgentStreamingSpeech(continueConversation: Bool) {
        shouldContinueAfterVoiceSpeech = continueConversation
        isVoiceSpeechInputFinished = true
        enqueueVoiceAgentSpeech(delta: "", flush: true)
        if voiceResponseSpeaker == nil && voiceStreamingSpeaker == nil && !voiceResponseSynthesizer.isSpeaking && voiceSpeechQueue.isEmpty {
            finishVoiceAgentSpeechOutput()
        }
    }

    private func drainVoiceSpeechSegments(flush: Bool) -> [String] {
        var segments: [String] = []
        while true {
            let text = voiceSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                voiceSpeechBuffer = ""
                return segments
            }

            let index = voiceSpeechBoundary(in: text, flush: flush)
            if index <= 0 {
                return segments
            }

            let end = text.index(text.startIndex, offsetBy: index)
            let segment = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remaining = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            voiceSpeechBuffer = remaining
            if !segment.isEmpty {
                segments.append(segment)
            }
        }
    }

    private func voiceSpeechBoundary(in text: String, flush: Bool) -> Int {
        let characters = Array(text)
        let minimum = Self.voiceStreamingTTSMinimumCharacters()
        let maximum = Self.voiceStreamingTTSMaximumCharacters()
        let punctuation = CharacterSet(charactersIn: "。！？!?；;，,、\n")

        for (index, character) in characters.enumerated() {
            guard index + 1 >= minimum else {
                continue
            }
            let scalarSet = String(character).unicodeScalars
            if scalarSet.contains(where: { punctuation.contains($0) }) {
                return index + 1
            }
        }

        if characters.count >= maximum {
            if let spaceIndex = characters.prefix(maximum).lastIndex(where: { $0 == " " }) {
                return max(minimum, spaceIndex + 1)
            }
            return maximum
        }

        return flush ? characters.count : 0
    }

    private func startNextVoiceSpeechSegmentIfNeeded() {
        guard voiceResponseSpeaker == nil, voiceStreamingSpeaker == nil, !voiceResponseSynthesizer.isSpeaking else {
            return
        }
        guard !voiceSpeechQueue.isEmpty else {
            if isVoiceSpeechInputFinished {
                finishVoiceAgentSpeechOutput()
            }
            return
        }

        let text = voiceSpeechQueue.removeFirst()
        CrowMacLog("voice tts start segment chars=\(text.count) remaining=\(voiceSpeechQueue.count) audioStreaming=\(Self.voiceAudioStreamingEnabled())")
        if Self.voiceAudioStreamingEnabled() {
            startStreamingVoiceSpeechSegment(text)
        } else {
            startBufferedVoiceSpeechSegment(text)
        }
    }

    private func startStreamingVoiceSpeechSegment(_ text: String) {
        let speaker = CrowOpenAIStreamingTTSSpeaker(useCloudBackend: true)
        voiceStreamingSpeaker = speaker
        isSpeaking = true
        voiceAgentPhase = "speaking"
        voiceHint = L("Crow is speaking")
        needsDisplay = true
        speaker.speak(
            text,
            onStarted: { [weak self, weak speaker] in
                guard let self, self.voiceStreamingSpeaker === speaker else { return }
                self.isSpeaking = true
                self.voiceAgentPhase = "speaking"
                self.voiceHint = L("Crow is speaking")
                self.needsDisplay = true
            },
            onFinished: { [weak self, weak speaker] in
                guard let self, self.voiceStreamingSpeaker === speaker else { return }
                self.voiceStreamingSpeaker = nil
                self.startNextVoiceSpeechSegmentIfNeeded()
            },
            onFailed: { [weak self, weak speaker] message in
                guard let self, self.voiceStreamingSpeaker === speaker else { return }
                CrowMacLog("voice agent streaming speech failed \(message)")
                self.voiceStreamingSpeaker = nil
                self.startBufferedVoiceSpeechSegment(text)
            }
        )
    }

    private func startBufferedVoiceSpeechSegment(_ text: String) {
        let speaker = CrowOpenAITTSSpeaker(useCloudBackend: true)
        voiceResponseSpeaker = speaker
        isSpeaking = true
        voiceAgentPhase = "speaking"
        voiceHint = L("Crow is speaking")
        needsDisplay = true
        speaker.speak(
            text,
            onStarted: { [weak self, weak speaker] in
                guard let self, self.voiceResponseSpeaker === speaker else { return }
                self.isSpeaking = true
                self.voiceAgentPhase = "speaking"
                self.voiceHint = L("Crow is speaking")
                self.needsDisplay = true
            },
            onFinished: { [weak self, weak speaker] in
                guard let self, self.voiceResponseSpeaker === speaker else { return }
                self.voiceResponseSpeaker = nil
                self.startNextVoiceSpeechSegmentIfNeeded()
            },
            onFailed: { [weak self, weak speaker] message in
                guard let self, self.voiceResponseSpeaker === speaker else { return }
                CrowMacLog("voice agent buffered speech failed \(message)")
                self.voiceResponseSpeaker = nil
                self.startSystemVoiceSpeechSegment(text)
            }
        )
    }

    private func startSystemVoiceSpeechSegment(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: Self.speechLocaleIdentifier())
        isSpeaking = true
        voiceAgentPhase = "speaking"
        voiceHint = L("Crow is speaking")
        needsDisplay = true
        voiceResponseSynthesizer.speak(utterance)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.9, Double(text.count) * 0.14)) { [weak self] in
            guard let self else { return }
            self.startNextVoiceSpeechSegmentIfNeeded()
        }
    }

    private func finishVoiceAgentSpeechOutput() {
        voiceResponseSpeaker = nil
        isSpeaking = false
        if voiceAgentPhase != "running" && voiceAgentPhase != "approval" && voiceAgentPhase != "failed" {
            voiceAgentPhase = "completed"
            voiceHint = shouldContinueAfterVoiceSpeech ? L("Listening again soon") : L("Response complete")
        }
        let shouldContinue = shouldContinueAfterVoiceSpeech
        resetVoiceAgentSpeechOutput(stopPlayback: false)
        if shouldContinue {
            scheduleContinueListeningIfNeeded(after: lastVoiceUserText)
        }
        needsDisplay = true
    }

    private func playVoiceAgentResponse(_ text: String) {
        if Self.voiceAudioStreamingEnabled() {
            voiceStreamingSpeaker?.stop()
            let speaker = CrowOpenAIStreamingTTSSpeaker(useCloudBackend: true)
            voiceStreamingSpeaker = speaker
            isSpeaking = true
            voiceAgentPhase = "speaking"
            voiceHint = L("Crow is speaking")
            needsDisplay = true
            speaker.speak(
                text,
                onStarted: { [weak self, weak speaker] in
                    guard let self, self.voiceStreamingSpeaker === speaker else { return }
                    self.isSpeaking = true
                    self.voiceAgentPhase = "speaking"
                    self.voiceHint = L("Crow is speaking")
                    self.needsDisplay = true
                },
                onFinished: { [weak self, weak speaker] in
                    guard let self, self.voiceStreamingSpeaker === speaker else { return }
                    self.voiceStreamingSpeaker = nil
                    self.isSpeaking = false
                    self.voiceAgentPhase = "completed"
                    self.voiceHint = L("Listening again soon")
                    self.scheduleContinueListeningIfNeeded(after: self.lastVoiceUserText)
                    self.needsDisplay = true
                },
                onFailed: { [weak self, weak speaker] message in
                    guard let self, self.voiceStreamingSpeaker === speaker else { return }
                    CrowMacLog("voice agent streaming speech failed \(message)")
                    self.voiceStreamingSpeaker = nil
                    self.playVoiceAgentBufferedResponse(text)
                }
            )
            return
        }
        playVoiceAgentBufferedResponse(text)
    }

    private func playVoiceAgentBufferedResponse(_ text: String) {
        voiceResponseSpeaker?.stop()
        let speaker = CrowOpenAITTSSpeaker(useCloudBackend: true)
        voiceResponseSpeaker = speaker
        isSpeaking = true
        voiceAgentPhase = "speaking"
        voiceHint = L("Crow is speaking")
        needsDisplay = true
        speaker.speak(
            text,
            onStarted: { [weak self, weak speaker] in
                guard let self, self.voiceResponseSpeaker === speaker else { return }
                self.isSpeaking = true
                self.voiceAgentPhase = "speaking"
                self.voiceHint = L("Crow is speaking")
                self.needsDisplay = true
            },
            onFinished: { [weak self, weak speaker] in
                guard let self, self.voiceResponseSpeaker === speaker else { return }
                self.voiceResponseSpeaker = nil
                self.isSpeaking = false
                self.voiceAgentPhase = "completed"
                self.voiceHint = L("Listening again soon")
                self.scheduleContinueListeningIfNeeded(after: self.lastVoiceUserText)
                self.needsDisplay = true
            },
            onFailed: { [weak self, weak speaker] message in
                guard let self, self.voiceResponseSpeaker === speaker else { return }
                CrowMacLog("voice agent cloud speech failed \(message)")
                self.voiceResponseSpeaker = nil
                self.playVoiceAgentSystemFallback(text)
            }
        )
    }

    private func playVoiceAgentSystemFallback(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: Self.speechLocaleIdentifier())
        isSpeaking = true
        voiceAgentPhase = "speaking"
        voiceHint = L("Crow is speaking")
        needsDisplay = true
        voiceResponseSynthesizer.speak(utterance)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1.5, Double(text.count) * 0.16)) { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.voiceAgentPhase = "completed"
            self.voiceHint = L("Listening again soon")
            self.scheduleContinueListeningIfNeeded(after: self.lastVoiceUserText)
            self.needsDisplay = true
        }
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
            scheduleRetryListening()
            return
        }
        submitVoiceCommand(text: cleaned, audioURL: nil)
        didSubmitVoiceCommand = true
        isAwaitingVoiceConfirmation = false
        voiceSubmittedAt = Date()
        voiceAgentText = ""
        voiceAgentPhase = "waiting"
        voiceHint = L("Waiting for Crow...")
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
            guard let self else { return }
            if self.shouldKeepVoicePanelOpenForConversation() {
                return
            }
            self.closeVoicePanel(reason: "auto-close")
        }
        autoCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func shouldKeepVoicePanelOpenForConversation() -> Bool {
        guard isExpanded, isVoiceConversationActive else {
            return false
        }
        if isRecording || isTranscribing || isFinishingVoiceCapture {
            return true
        }
        if voiceResponseSpeaker != nil || voiceStreamingSpeaker != nil || voiceResponseSynthesizer.isSpeaking {
            return true
        }
        switch voiceAgentPhase {
        case "responding", "speaking", "thinking":
            return true
        default:
            return didSubmitVoiceCommand && !lastVoiceUserText.isEmpty
        }
    }

    private func cancelAutoClose() {
        autoCloseWorkItem?.cancel()
        autoCloseWorkItem = nil
    }

    private func scheduleContinueListeningIfNeeded(after userText: String) {
        cancelAutoClose()
        cancelContinueListening()
        cancelNoSpeechClose()
        guard isExpanded, isVoiceConversationActive, !shouldEndVoiceConversation(after: userText) else {
            scheduleAutoClose(delay: Self.voiceConversationIdleCloseDelay())
            return
        }
        guard !isRecording, !isTranscribing, voiceResponseSpeaker == nil, voiceStreamingSpeaker == nil, !voiceResponseSynthesizer.isSpeaking, !isAwaitingSpeech else {
            return
        }
        voiceHint = L("Listening again soon")
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isExpanded,
                  self.isVoiceConversationActive,
                  !self.isRecording,
                  !self.isTranscribing,
                  self.voiceResponseSpeaker == nil,
                  self.voiceStreamingSpeaker == nil,
                  !self.voiceResponseSynthesizer.isSpeaking,
                  // A task result may be in synthesis or playing through the controller.
                  !self.isAwaitingSpeech,
                  self.voiceAgentPhase != "speaking" else {
                return
            }
            self.beginVoiceCapture()
        }
        continueListeningWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.voiceConversationContinueDelay(), execute: item)
    }

    private func cancelContinueListening() {
        continueListeningWorkItem?.cancel()
        continueListeningWorkItem = nil
    }

    private func scheduleRetryListening() {
        cancelAutoClose()
        cancelContinueListening()
        cancelNoSpeechClose()
        cancelRetryListening()
        guard isExpanded, isVoiceConversationActive, !isRecording, !isTranscribing else {
            return
        }
        voiceHint = L("Didn't catch that. Listening again...")
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isExpanded,
                  self.isVoiceConversationActive,
                  !self.isRecording,
                  !self.isTranscribing else {
                return
            }
            self.beginVoiceCapture()
        }
        retryListeningWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)
    }

    private func cancelRetryListening() {
        retryListeningWorkItem?.cancel()
        retryListeningWorkItem = nil
    }

    private func scheduleNoSpeechClose() {
        cancelNoSpeechClose()
        let delay = Self.voiceConversationNoSpeechCloseDelay()
        guard delay > 0 else {
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isExpanded,
                  self.isRecording,
                  self.voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            self.voiceHint = L("No reply detected")
            if self.didHearSpeechInCurrentCapture {
                CrowMacLog("voice no-speech finalize after detected speech")
                self.finishVoiceCapture()
            } else {
                CrowMacLog("voice no-speech close after idle threshold")
                self.closeVoicePanel(force: true, reason: "no-speech-idle")
            }
        }
        noSpeechCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelNoSpeechClose() {
        noSpeechCloseWorkItem?.cancel()
        noSpeechCloseWorkItem = nil
    }

    private func shouldEndVoiceConversation(after text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return false
        }
        let endPhrases = [
            "不用继续", "不用沟通", "不用再沟通", "不用回复", "不用回答", "先这样", "就这样", "结束对话", "关闭对话", "收起",
            "stop listening", "stop talking", "end conversation", "that's all", "that is all"
        ]
        return endPhrases.contains { normalized.contains($0) }
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
            closeVoicePanel(reason: "runtime-collapse")
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
            voiceHint = L("Crow is speaking")
        case "responding":
            voiceHint = L("Crow is responding")
        case "completed":
            voiceHint = L("Response complete")
            if !isSpeaking && !isAwaitingSpeech {
                scheduleContinueListeningIfNeeded(after: lastVoiceUserText)
            }
        case "failed":
            voiceHint = L("Needs review")
        case "approval":
            voiceHint = L("Approval required")
        case "thinking":
            voiceHint = L("Crow is thinking")
        case "planning":
            voiceHint = L("Crow is planning")
        case "starting", "running":
            voiceHint = L("Crow is working")
        default:
            voiceHint = L("Waiting for Crow...")
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
        let speechIdle = lastSpeechActivityAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let isLikelySpeech = power > speechGate

            if isLikelySpeech {
            lastSpeechActivityAt = Date()
            didHearSpeechInCurrentCapture = true
            speechPeakPower = max(speechPeakPower, power)
            silentSince = nil
        } else if elapsed > minimumDuration, hasTranscript, transcriptIdle > 0.8, power < releaseGate {
            markPotentialSilence(duration: silenceDuration)
        } else if elapsed > minimumDuration, hasTranscript, transcriptIdle > 1.35 {
            markPotentialSilence(duration: silenceDuration + 0.25)
        } else if elapsed > 2.2, speechPeakPower > speechGate, speechIdle > 0.95, power < releaseGate {
            markPotentialSilence(duration: 1.05)
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
        "没识别到内容，正在重新听..."
    }

    private static func compactHint(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 72 else {
            return text
        }
        return String(text.prefix(72)) + "..."
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

    static func voiceConversationContinueDelay() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_ISLAND_VOICE_CONTINUE_DELAY_SECONDS"),
              let value = TimeInterval(raw) else {
            return 0.75
        }
        return max(0.2, value)
    }

    static func voiceConversationNoSpeechCloseDelay() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_ISLAND_VOICE_NO_SPEECH_CLOSE_SECONDS"),
              let value = TimeInterval(raw) else {
            return 12
        }
        return max(10, value)
    }

    static func voiceStreamingTTSMinimumCharacters() -> Int {
        guard let raw = CrowEnvironment.value("CROW_VOICE_STREAMING_TTS_MIN_CHARS"),
              let value = Int(raw) else {
            return 18
        }
        return max(6, value)
    }

    static func voiceStreamingTTSMaximumCharacters() -> Int {
        guard let raw = CrowEnvironment.value("CROW_VOICE_STREAMING_TTS_MAX_CHARS"),
              let value = Int(raw) else {
            return 56
        }
        return max(Self.voiceStreamingTTSMinimumCharacters(), value)
    }

    static func voiceTTSStreamingEnabled() -> Bool {
        let raw = (CrowEnvironment.value("CROW_VOICE_STREAMING_TTS") ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw != "0" && raw != "false" && raw != "off"
    }

    static func voiceAudioStreamingEnabled() -> Bool {
        let raw = (CrowEnvironment.value("CROW_VOICE_AUDIO_STREAMING") ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw != "0" && raw != "false" && raw != "off"
    }

    static func realtimeFailureCooldownSeconds() -> TimeInterval {
        guard let raw = CrowEnvironment.value("CROW_REALTIME_FAILURE_COOLDOWN_SECONDS"),
              let value = TimeInterval(raw) else {
            return 300
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

    /// `mode` routes the task: "agent" (Codex and other executors) or "computer".
    private func submitVoiceCommand(text: String, audioURL: URL?, mode: String = "agent") {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return
        }
        if let voiceCommandHandler {
            voiceCommandHandler(cleaned, mode)
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
        let width = compactBarWidth + proximity * 18
        let baseRect = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.height - geometry.closedHeight - proximity * 2.5,
            width: width,
            height: geometry.closedHeight + proximity * 2.5
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
        let target = finalVoicePanelRect
        let source = scale(rect: baseBarRect, by: max(1, hoverScale), anchorY: baseBarRect.maxY)
        let t = easedExpansionProgress
        let width = source.width + (target.width - source.width) * t
        let height = source.height + (target.height - source.height) * t
        let top = source.maxY + (target.maxY - source.maxY) * t
        return NSRect(
            x: bounds.midX - width / 2,
            y: top - height,
            width: width,
            height: height
        )
    }

    private var finalVoicePanelRect: NSRect {
        let width = min(max(geometry.notchWidth + 230, 400), bounds.width - 28)
        let height = max(78, bounds.height - 14)
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    private var easedExpansionProgress: CGFloat {
        let t = max(0, min(1, expansionProgress))
        return t * t * (3 - 2 * t)
    }

    private var voiceContentAlpha: CGFloat {
        let t = max(0, min(1, (easedExpansionProgress - 0.28) / 0.72))
        return t * t * (3 - 2 * t)
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
            return finalVoicePanelRect
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
        let radius = 14 + easedExpansionProgress * 6
        drawIslandSurface(rect: rect, radius: radius, expanded: easedExpansionProgress > 0.35)

        let headerY = rect.maxY - geometry.closedHeight
        let persona = IslandAvatarStyle.configured
        drawCrowMark(in: NSRect(x: rect.minX + 22, y: headerY + 6, width: 20, height: 20), visualState: renderedVisualState)
        drawFixedHeaderActivity(panel: rect, headerY: headerY)

        let contentAlpha = voiceContentAlpha
        guard contentAlpha > 0.02 else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(contentAlpha)

        let hasLiveText = !voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !voiceAgentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isTranscribing
            || didSubmitVoiceCommand
        if hasLiveText {
            let contentRect = NSRect(x: rect.minX + 26, y: rect.minY + 26, width: rect.width - 52, height: 28)
            drawText(voicePrimaryLine(), in: contentRect, size: 13, weight: .medium, color: NSColor(calibratedWhite: 0.88, alpha: 1))
        } else {
            drawPersonaCenter(style: persona, in: NSRect(x: rect.midX - 34, y: rect.minY + 25, width: 68, height: 42))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFixedHeaderActivity(panel rect: NSRect, headerY: CGFloat) {
        if rect.width > 250 {
            drawVoiceWaveform(in: NSRect(x: rect.maxX - 112, y: headerY + 7, width: 78, height: 22))
        } else {
            drawCompactActivity(in: NSRect(x: rect.maxX - 38, y: headerY + 9, width: 20, height: 14))
        }
    }

    private func drawPersonaCenter(style: IslandAvatarStyle, in rect: NSRect) {
        switch style {
        case .default:
            drawVoicePlaceholder(in: rect)
        case .cute:
            drawCuteCrowMark(in: NSRect(x: rect.midX - 16, y: rect.midY - 14, width: 32, height: 32), visualState: renderedVisualState)
            drawCuteListeningBreath(in: NSRect(x: rect.midX + 18, y: rect.midY - 7, width: 28, height: 14))
        case .robot:
            drawRobotMark(in: NSRect(x: rect.midX - 17, y: rect.midY - 15, width: 34, height: 30), visualState: renderedVisualState)
        case .jarvis:
            drawJarvisCore(in: NSRect(x: rect.midX - 18, y: rect.midY - 18, width: 36, height: 36), visualState: renderedVisualState)
        }
    }

    private func drawIslandSurface(rect: NSRect, radius: CGFloat, expanded: Bool) {
        let path = expanded ? expandedPanelPath(rect: rect, radius: radius) : bottomRoundedPath(rect: rect, radius: radius)
        shadow(color: NSColor.black.withAlphaComponent(expanded ? 0.30 : 0.22), blur: expanded ? 22 : 14, offset: NSSize(width: 0, height: expanded ? -12 : -8)) {
            NSColor(calibratedRed: 0.006, green: 0.006, blue: 0.007, alpha: expanded ? 0.992 : 0.998).setFill()
            path.fill()
        }

        NSColor.white.withAlphaComponent(expanded ? 0.10 : 0.07).setStroke()
        path.lineWidth = expanded ? 1.1 : 0.9
        path.stroke()

        NSColor.white.withAlphaComponent(expanded ? 0.055 : 0.04).setStroke()
        let inner = expanded ? expandedPanelPath(rect: rect.insetBy(dx: 1, dy: 1), radius: max(1, radius - 1)) : bottomRoundedPath(rect: rect.insetBy(dx: 1, dy: 1), radius: max(1, radius - 1))
        inner.lineWidth = 0.6
        inner.stroke()
    }

    private func drawVoicePlaceholder(in rect: NSRect) {
        let accent = visualAccentColor()
        let baseAlpha: CGFloat = isRecording ? 0.62 : 0.34
        let level = max(0.12, min(1, inputLevel))
        let dotCount = 3
        let dotSize: CGFloat = 4
        let gap: CGFloat = 9
        let totalWidth = CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * gap
        let startX = rect.midX - totalWidth / 2
        for index in 0..<dotCount {
            let wave = (sin(phase * (isRecording ? 1.8 : 0.72) + CGFloat(index) * 0.82) + 1) / 2
            let scale = isRecording ? 0.82 + max(wave, level) * 0.55 : 0.78 + wave * 0.28
            let size = dotSize * scale
            let x = startX + CGFloat(index) * (dotSize + gap) + (dotSize - size) / 2
            let y = rect.midY - size / 2
            accent.withAlphaComponent(baseAlpha * (0.55 + wave * 0.45)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
        }
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
        return "Voice input"
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
            return "Crow is working..."
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
            return "正在聆听..."
        }
        return "等待输入..."
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
        drawIslandSurface(rect: rect, radius: 22, expanded: true)
    }

    private func drawBar() {
        let rect = barRect
        drawIslandSurface(rect: rect, radius: min(16, rect.height / 2), expanded: false)

        let centerY = rect.midY
        drawStateIcon(in: NSRect(x: rect.minX + 19, y: centerY - 9, width: 18, height: 18), visualState: renderedVisualState)
        if isSpeaking {
            drawSpeakingActivity(in: NSRect(x: rect.maxX - 48, y: centerY - 9, width: 30, height: 18))
        } else {
            drawCompactActivity(in: NSRect(x: rect.maxX - 38, y: centerY - 7, width: 20, height: 14))
        }
    }

    private func drawApprovalPanel() {
        let rect = approvalPanelRect
        drawIslandSurface(rect: rect, radius: 20, expanded: true)

        let headerY = rect.maxY - geometry.closedHeight
        drawStateIcon(in: NSRect(x: rect.minX + 22, y: headerY + 6, width: 20, height: 20), visualState: .approval)
        drawApprovalPulse(in: NSRect(x: rect.minX + 52, y: headerY + 10, width: 54, height: 12))

        let contentRight = approvalApproveButtonRect.minX - 18
        drawText(approvalSummaryText(), in: NSRect(x: rect.minX + 26, y: rect.minY + 52, width: contentRight - rect.minX - 26, height: 20), size: 14, weight: .bold, color: .white)
        drawText(approvalDetailText(), in: NSRect(x: rect.minX + 26, y: rect.minY + 34, width: contentRight - rect.minX - 26, height: 16), size: 11, weight: .regular, color: NSColor(calibratedWhite: 0.7, alpha: 1))
        drawText(L("Open full details in Crow."), in: NSRect(x: rect.minX + 26, y: rect.minY + 17, width: contentRight - rect.minX - 26, height: 13), size: 10, weight: .regular, color: NSColor(calibratedWhite: 0.52, alpha: 1))
        drawApprovalButton(L("Approve"), rect: approvalApproveButtonRect, primary: true)
        drawApprovalButton(L("Reject"), rect: approvalRejectButtonRect, primary: false)
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
        drawText(L("◆"), in: NSRect(x: rect.midX - 210, y: headerY + 9, width: 18, height: 16), size: 10, weight: .bold, color: accentColor())
        drawText(barLabel(), in: NSRect(x: rect.midX - 166, y: headerY + 5, width: 280, height: 24), size: 14, weight: .semibold, color: .white)
        if isSpeaking {
            drawSpeakingActivity(in: NSRect(x: rect.midX + 184, y: headerY + 5, width: 46, height: 26))
        } else {
            drawEqualizer(in: NSRect(x: rect.midX + 190, y: headerY + 6, width: 34, height: 24))
        }

        let top = rect.maxY - geometry.closedHeight - 26
        let left = NSRect(x: rect.minX + 34, y: rect.minY + 46, width: 290, height: top - rect.minY - 46)
        let center = NSRect(x: rect.midX - 88, y: rect.minY + 48, width: 176, height: top - rect.minY - 48)
        let right = NSRect(x: rect.maxX - 162, y: rect.minY + 46, width: 128, height: top - rect.minY - 46)

        drawTaskPreview(in: left)
        drawExecutionControls(in: center)
        drawAssistantSignal(in: right)
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

    private func drawAssistantSignal(in rect: NSRect) {
        let markSize = min(rect.width, rect.height) * 0.44
        let markRect = NSRect(
            x: rect.midX - markSize / 2,
            y: rect.midY - markSize / 2 + 8,
            width: markSize,
            height: markSize
        )
        drawStateIcon(in: markRect, visualState: renderedVisualState)

        if isSpeaking {
            drawSpeakingActivity(in: NSRect(x: rect.midX - 26, y: rect.minY + 16, width: 52, height: 24))
        } else {
            drawCompactActivity(in: NSRect(x: rect.midX - 16, y: rect.minY + 18, width: 32, height: 18))
        }
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
        switch IslandAvatarStyle.configured {
        case .default:
            drawCrowMark(in: rect, visualState: visualState)
        case .cute:
            drawCuteCrowMark(in: rect, visualState: visualState)
        case .robot:
            drawRobotMark(in: rect, visualState: visualState)
        case .jarvis:
            drawJarvisMark(in: rect, visualState: visualState)
        }
    }

    private func drawCrowMark(in rect: NSRect, visualState: IslandVisualState) {
        let size = min(rect.width, rect.height)
        let mark = NSRect(
            x: rect.midX - size * 0.50,
            y: rect.midY - size * 0.48,
            width: size,
            height: size * 0.96
        )

        let markColor = NSColor.white.withAlphaComponent(visualState == .idle ? 0.74 : 0.9)
        markColor.setFill()

        // Facing-left perched crow: sharp beak, raised head, folded wing, long tail.
        let beak = NSBezierPath()
        beak.move(to: NSPoint(x: mark.minX + mark.width * 0.03, y: mark.minY + mark.height * 0.68))
        beak.line(to: NSPoint(x: mark.minX + mark.width * 0.24, y: mark.minY + mark.height * 0.75))
        beak.line(to: NSPoint(x: mark.minX + mark.width * 0.22, y: mark.minY + mark.height * 0.61))
        beak.close()
        beak.fill()

        let silhouette = NSBezierPath()
        silhouette.move(to: NSPoint(x: mark.minX + mark.width * 0.20, y: mark.minY + mark.height * 0.61))
        silhouette.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.40, y: mark.minY + mark.height * 0.90),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.18, y: mark.minY + mark.height * 0.78),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.28, y: mark.minY + mark.height * 0.91)
        )
        silhouette.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.58, y: mark.minY + mark.height * 0.63),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.53, y: mark.minY + mark.height * 0.89),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.59, y: mark.minY + mark.height * 0.76)
        )
        silhouette.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.86, y: mark.minY + mark.height * 0.22),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.74, y: mark.minY + mark.height * 0.56),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.86, y: mark.minY + mark.height * 0.40)
        )
        silhouette.line(to: NSPoint(x: mark.minX + mark.width * 0.67, y: mark.minY + mark.height * 0.27))
        silhouette.line(to: NSPoint(x: mark.minX + mark.width * 0.82, y: mark.minY + mark.height * 0.08))
        silhouette.line(to: NSPoint(x: mark.minX + mark.width * 0.56, y: mark.minY + mark.height * 0.22))
        silhouette.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.23, y: mark.minY + mark.height * 0.34),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.44, y: mark.minY + mark.height * 0.12),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.25, y: mark.minY + mark.height * 0.18)
        )
        silhouette.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.20, y: mark.minY + mark.height * 0.61),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.14, y: mark.minY + mark.height * 0.43),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.14, y: mark.minY + mark.height * 0.54)
        )
        silhouette.close()
        silhouette.fill()

        let wing = NSBezierPath()
        wing.move(to: NSPoint(x: mark.minX + mark.width * 0.37, y: mark.minY + mark.height * 0.55))
        wing.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.63, y: mark.minY + mark.height * 0.29),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.48, y: mark.minY + mark.height * 0.40),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.58, y: mark.minY + mark.height * 0.31)
        )
        wing.lineWidth = max(0.9, size * 0.06)
        NSColor.black.withAlphaComponent(0.46).setStroke()
        wing.stroke()

        let eyeSize = max(1, size * 0.07)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: mark.minX + mark.width * 0.31,
            y: mark.minY + mark.height * 0.72,
            width: eyeSize,
            height: eyeSize
        )).fill()

        markColor.withAlphaComponent(0.70).setStroke()
        let leg = NSBezierPath()
        leg.move(to: NSPoint(x: mark.minX + mark.width * 0.47, y: mark.minY + mark.height * 0.24))
        leg.line(to: NSPoint(x: mark.minX + mark.width * 0.43, y: mark.minY + mark.height * 0.04))
        leg.move(to: NSPoint(x: mark.minX + mark.width * 0.55, y: mark.minY + mark.height * 0.24))
        leg.line(to: NSPoint(x: mark.minX + mark.width * 0.58, y: mark.minY + mark.height * 0.04))
        leg.lineWidth = max(0.7, size * 0.045)
        leg.stroke()

        statusDotColor(for: visualState).setFill()
        let dotSize = max(2.0, size * 0.13)
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - dotSize * 0.8, y: rect.minY, width: dotSize, height: dotSize)).fill()
    }

    private func drawCuteCrowMark(in rect: NSRect, visualState: IslandVisualState) {
        let size = min(rect.width, rect.height)
        let pulse = (sin(phase * 1.4) + 1) / 2
        let listenLift: CGFloat = visualState == .listening ? inputLevel * size * 0.06 : 0
        let mark = NSRect(
            x: rect.midX - size * 0.54,
            y: rect.midY - size * 0.52 + listenLift,
            width: size * 1.08,
            height: size * 1.02
        )

        let bodyAlpha: CGFloat = visualState == .idle ? 0.86 : 0.98
        let featherColor = NSColor(calibratedWhite: 0.96, alpha: bodyAlpha)
        featherColor.setFill()

        let haloRect = NSRect(
            x: rect.midX - size * 0.54,
            y: rect.midY - size * 0.50,
            width: size * 1.08,
            height: size * 1.00
        )
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(ovalIn: haloRect).fill()

        let body = NSBezierPath(ovalIn: NSRect(
            x: mark.minX + mark.width * 0.18,
            y: mark.minY + mark.height * 0.06,
            width: mark.width * 0.68,
            height: mark.height * 0.68
        ))
        body.fill()

        let head = NSBezierPath(ovalIn: NSRect(
            x: mark.minX + mark.width * 0.12,
            y: mark.minY + mark.height * 0.42,
            width: mark.width * 0.56,
            height: mark.height * 0.52
        ))
        head.fill()

        let crest = NSBezierPath()
        crest.move(to: NSPoint(x: mark.minX + mark.width * 0.34, y: mark.minY + mark.height * 0.88))
        crest.line(to: NSPoint(x: mark.minX + mark.width * 0.43, y: mark.minY + mark.height * 1.00))
        crest.line(to: NSPoint(x: mark.minX + mark.width * 0.50, y: mark.minY + mark.height * 0.84))
        crest.close()
        crest.fill()

        NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.22, alpha: visualState == .idle ? 0.82 : 0.96).setFill()
        let beak = NSBezierPath()
        beak.move(to: NSPoint(x: mark.minX + mark.width * 0.00, y: mark.minY + mark.height * 0.66))
        beak.line(to: NSPoint(x: mark.minX + mark.width * 0.22, y: mark.minY + mark.height * 0.74))
        beak.line(to: NSPoint(x: mark.minX + mark.width * 0.22, y: mark.minY + mark.height * 0.58))
        beak.close()
        beak.fill()

        featherColor.setFill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: mark.minX + mark.width * 0.78, y: mark.minY + mark.height * 0.36))
        tail.line(to: NSPoint(x: mark.minX + mark.width * 1.00, y: mark.minY + mark.height * 0.26))
        tail.line(to: NSPoint(x: mark.minX + mark.width * 0.83, y: mark.minY + mark.height * 0.15))
        tail.close()
        tail.fill()

        let wingPath = NSBezierPath()
        wingPath.move(to: NSPoint(x: mark.minX + mark.width * 0.50, y: mark.minY + mark.height * 0.44))
        wingPath.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.70, y: mark.minY + mark.height * 0.22),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.61, y: mark.minY + mark.height * 0.34),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.66, y: mark.minY + mark.height * 0.25)
        )
        wingPath.lineWidth = max(0.8, size * 0.055)
        NSColor.black.withAlphaComponent(0.42).setStroke()
        wingPath.stroke()

        let eyeWidth = max(1.2, size * 0.075)
        let isBlinking = visualState == .thinking && pulse > 0.88
        NSColor.black.withAlphaComponent(0.86).setFill()
        if isBlinking {
            let blink = NSBezierPath(roundedRect: NSRect(
                x: mark.minX + mark.width * 0.34,
                y: mark.minY + mark.height * 0.70,
                width: eyeWidth * 1.35,
                height: max(0.8, eyeWidth * 0.22)
            ), xRadius: 1, yRadius: 1)
            blink.fill()
        } else {
            NSBezierPath(ovalIn: NSRect(
                x: mark.minX + mark.width * 0.36,
                y: mark.minY + mark.height * 0.67,
                width: eyeWidth,
                height: eyeWidth
            )).fill()
            NSColor.white.withAlphaComponent(0.75).setFill()
            let glint = max(0.6, eyeWidth * 0.32)
            NSBezierPath(ovalIn: NSRect(
                x: mark.minX + mark.width * 0.36 + eyeWidth * 0.52,
                y: mark.minY + mark.height * 0.67 + eyeWidth * 0.56,
                width: glint,
                height: glint
            )).fill()
        }

        NSColor.black.withAlphaComponent(0.34).setStroke()
        let cheek = NSBezierPath()
        cheek.move(to: NSPoint(x: mark.minX + mark.width * 0.43, y: mark.minY + mark.height * 0.58))
        cheek.curve(
            to: NSPoint(x: mark.minX + mark.width * 0.55, y: mark.minY + mark.height * 0.58),
            controlPoint1: NSPoint(x: mark.minX + mark.width * 0.47, y: mark.minY + mark.height * 0.54),
            controlPoint2: NSPoint(x: mark.minX + mark.width * 0.51, y: mark.minY + mark.height * 0.54)
        )
        cheek.lineWidth = max(0.55, size * 0.025)
        cheek.stroke()

        let footColor = NSColor.white.withAlphaComponent(0.58)
        footColor.setStroke()
        let feet = NSBezierPath()
        feet.move(to: NSPoint(x: mark.minX + mark.width * 0.44, y: mark.minY + mark.height * 0.12))
        feet.line(to: NSPoint(x: mark.minX + mark.width * 0.38, y: mark.minY))
        feet.move(to: NSPoint(x: mark.minX + mark.width * 0.56, y: mark.minY + mark.height * 0.12))
        feet.line(to: NSPoint(x: mark.minX + mark.width * 0.60, y: mark.minY))
        feet.lineWidth = max(0.7, size * 0.04)
        feet.stroke()

        if visualState == .speaking {
            visualAccentColor(for: visualState).withAlphaComponent(0.66).setStroke()
            let chirp = NSBezierPath()
            let start = NSPoint(x: mark.minX + mark.width * 0.13, y: mark.minY + mark.height * 0.55)
            chirp.move(to: start)
            chirp.curve(
                to: NSPoint(x: start.x - size * 0.20, y: start.y + size * 0.02),
                controlPoint1: NSPoint(x: start.x - size * 0.08, y: start.y + size * 0.08),
                controlPoint2: NSPoint(x: start.x - size * 0.15, y: start.y + size * 0.08)
            )
            chirp.lineWidth = max(0.8, size * 0.045)
            chirp.stroke()
        }

        statusDotColor(for: visualState).setFill()
        let dotSize = max(2.0, size * 0.13)
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - dotSize * 0.8, y: rect.minY, width: dotSize, height: dotSize)).fill()
    }

    private func drawRobotMark(in rect: NSRect, visualState: IslandVisualState) {
        let size = min(rect.width, rect.height)
        let face = NSRect(x: rect.midX - size * 0.48, y: rect.midY - size * 0.40, width: size * 0.96, height: size * 0.78)
        let bodyPath = NSBezierPath(roundedRect: face, xRadius: size * 0.18, yRadius: size * 0.18)
        NSColor.white.withAlphaComponent(visualState == .idle ? 0.72 : 0.90).setFill()
        bodyPath.fill()

        NSColor.white.withAlphaComponent(0.58).setStroke()
        let antenna = NSBezierPath()
        antenna.move(to: NSPoint(x: rect.midX, y: face.maxY))
        antenna.line(to: NSPoint(x: rect.midX, y: face.maxY + size * 0.16))
        antenna.lineWidth = max(0.7, size * 0.045)
        antenna.stroke()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - size * 0.045, y: face.maxY + size * 0.13, width: size * 0.09, height: size * 0.09)).fill()

        let eyeColor = visualAccentColor(for: visualState).withAlphaComponent(visualState == .idle ? 0.70 : 0.98)
        let eyeY = face.midY + size * 0.04
        switch visualState {
        case .listening:
            drawRobotEyeBars(in: NSRect(x: face.minX + size * 0.18, y: eyeY - size * 0.10, width: size * 0.22, height: size * 0.20), color: eyeColor)
            drawRobotEyeBars(in: NSRect(x: face.maxX - size * 0.40, y: eyeY - size * 0.10, width: size * 0.22, height: size * 0.20), color: eyeColor)
        case .speaking:
            eyeColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: face.minX + size * 0.17, y: eyeY - size * 0.045, width: size * 0.24, height: size * 0.09), xRadius: size * 0.045, yRadius: size * 0.045).fill()
            NSBezierPath(roundedRect: NSRect(x: face.maxX - size * 0.41, y: eyeY - size * 0.045, width: size * 0.24, height: size * 0.09), xRadius: size * 0.045, yRadius: size * 0.045).fill()
        case .thinking, .running:
            let scan = CGFloat((sin(phase * 1.8) + 1) / 2)
            eyeColor.setFill()
            let leftX = face.minX + size * (0.17 + scan * 0.08)
            let rightX = face.maxX - size * (0.41 - scan * 0.08)
            NSBezierPath(ovalIn: NSRect(x: leftX, y: eyeY - size * 0.055, width: size * 0.11, height: size * 0.11)).fill()
            NSBezierPath(ovalIn: NSRect(x: rightX, y: eyeY - size * 0.055, width: size * 0.11, height: size * 0.11)).fill()
        default:
            eyeColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: face.minX + size * 0.22, y: eyeY - size * 0.055, width: size * 0.11, height: size * 0.11)).fill()
            NSBezierPath(ovalIn: NSRect(x: face.maxX - size * 0.33, y: eyeY - size * 0.055, width: size * 0.11, height: size * 0.11)).fill()
        }

        NSColor.black.withAlphaComponent(0.36).setStroke()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: face.minX + size * 0.34, y: face.minY + size * 0.18))
        mouth.line(to: NSPoint(x: face.maxX - size * 0.34, y: face.minY + size * 0.18))
        mouth.lineWidth = max(0.7, size * 0.035)
        mouth.stroke()

        statusDotColor(for: visualState).setFill()
        let dotSize = max(2.0, size * 0.12)
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - dotSize * 0.72, y: rect.minY, width: dotSize, height: dotSize)).fill()
    }

    private func drawRobotEyeBars(in rect: NSRect, color: NSColor) {
        let bars = 3
        let gap: CGFloat = 1.5
        let width = max(1, (rect.width - CGFloat(bars - 1) * gap) / CGFloat(bars))
        let boost = max(0.20, inputLevel)
        for index in 0..<bars {
            let wave = (sin(phase * 2.0 + CGFloat(index) * 0.8) + 1) / 2
            let height = rect.height * (0.36 + max(wave, boost) * 0.64)
            let x = rect.minX + CGFloat(index) * (width + gap)
            color.withAlphaComponent(0.42 + boost * 0.58).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    private func drawJarvisMark(in rect: NSRect, visualState: IslandVisualState) {
        drawJarvisCore(in: rect, visualState: visualState)
    }

    private func drawJarvisCore(in rect: NSRect, visualState: IslandVisualState) {
        let size = min(rect.width, rect.height)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let pulse = (sin(phase * 1.7) + 1) / 2
        let accent = visualAccentColor(for: visualState)

        for index in 0..<3 {
            let inset = CGFloat(index) * size * 0.15 + pulse * CGFloat(index) * 0.5
            let alpha = max(0.10, 0.42 - CGFloat(index) * 0.12)
            accent.withAlphaComponent(alpha).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            ring.lineWidth = max(0.6, size * (index == 0 ? 0.035 : 0.025))
            ring.stroke()
        }

        accent.withAlphaComponent(visualState == .idle ? 0.52 : 0.90).setFill()
        let coreSize = size * (0.20 + pulse * 0.07)
        NSBezierPath(ovalIn: NSRect(x: center.x - coreSize / 2, y: center.y - coreSize / 2, width: coreSize, height: coreSize)).fill()

        if visualState == .listening || visualState == .speaking {
            let sweep = fmod(phase * (visualState == .speaking ? 0.08 : 0.05), 1)
            accent.withAlphaComponent(0.74).setStroke()
            let path = NSBezierPath()
            let radius = size * 0.40
            let start = sweep * CGFloat.pi * 2
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: start * 180 / CGFloat.pi,
                endAngle: (start + CGFloat.pi * 0.68) * 180 / CGFloat.pi,
                clockwise: false
            )
            path.lineWidth = max(0.8, size * 0.045)
            path.stroke()
        }

        statusDotColor(for: visualState).setFill()
        let dotSize = max(2.0, size * 0.11)
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - dotSize * 0.72, y: rect.minY, width: dotSize, height: dotSize)).fill()
    }

    private func drawCuteListeningBreath(in rect: NSRect) {
        let accent = visualAccentColor(for: .listening)
        let dots = 3
        for index in 0..<dots {
            let wave = (sin(phase * 1.7 + CGFloat(index) * 0.75) + 1) / 2
            let size = 2.5 + max(wave, inputLevel) * 3.5
            let x = rect.minX + CGFloat(index) * 8
            accent.withAlphaComponent(0.24 + max(wave, inputLevel) * 0.46).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - size / 2, width: size, height: size)).fill()
        }
    }

    private func drawRobotStatusRail(in rect: NSRect) {
        let segments = 5
        let gap: CGFloat = 4
        let width = max(3, (rect.width - CGFloat(segments - 1) * gap) / CGFloat(segments))
        let accent = visualAccentColor()
        for index in 0..<segments {
            let wave = (sin(phase * 1.45 + CGFloat(index) * 0.72) + 1) / 2
            let activeBoost: CGFloat
            switch renderedVisualState {
            case .listening:
                activeBoost = max(CGFloat(index + 1) / CGFloat(segments), inputLevel)
            case .speaking:
                activeBoost = wave
            case .thinking, .running:
                activeBoost = index == Int(fmod(phase * 1.4, CGFloat(segments))) ? 1 : 0.25
            default:
                activeBoost = 0.28
            }
            let height = rect.height * (0.28 + activeBoost * 0.72)
            let x = rect.minX + CGFloat(index) * (width + gap)
            accent.withAlphaComponent(0.22 + activeBoost * 0.56).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    private func statusDotColor(for visualState: IslandVisualState) -> NSColor {
        switch visualState {
        case .idle:
            return NSColor.white.withAlphaComponent(0.42)
        default:
            return visualAccentColor(for: visualState).withAlphaComponent(0.9)
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
        switch renderedVisualState {
        case .speaking:
            drawOutputFlow(in: rect)
        case .thinking, .running:
            drawThinkingDots(in: rect)
        default:
            drawInputMeter(in: rect)
        }
    }

    private func drawInputMeter(in rect: NSRect) {
        let bars = 9
        let gap: CGFloat = 4
        let barWidth = max(3, (rect.width - CGFloat(bars - 1) * gap) / CGFloat(bars))
        let liveBoost = max(0.16, inputLevel)
        let baseColor = visualAccentColor()
        for index in 0..<bars {
            let wave = (sin(phase * 1.7 + CGFloat(index) * 0.72) + 1) / 2
            let levelShape = max(wave * 0.42, liveBoost)
            let height = 3.5 + levelShape * liveBoost * (rect.height - 3.5)
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let y = rect.midY - height / 2
            let bar = NSRect(x: x, y: y, width: barWidth, height: height)
            let alpha = 0.36 + liveBoost * 0.64
            baseColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func drawOutputFlow(in rect: NSRect) {
        let rows = 3
        let baseColor = visualAccentColor()
        for row in 0..<rows {
            let rowY = rect.midY + CGFloat(row - 1) * 6
            let segments = 3
            for index in 0..<segments {
                let wave = (sin(phase * 1.35 + CGFloat(index) * 1.1 + CGFloat(row) * 0.7) + 1) / 2
                let width = 12 + wave * 18
                let travel = max(1, rect.width - width)
                let offset = CGFloat(index) / CGFloat(segments)
                let x = rect.minX + travel * fmod((phase * 0.045 + offset + CGFloat(row) * 0.11), 1)
                let line = NSRect(x: x, y: rowY - 1, width: width, height: 2)
                baseColor.withAlphaComponent(0.34 + wave * 0.36).setFill()
                NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    private func drawThinkingDots(in rect: NSRect) {
        let baseColor = visualAccentColor()
        let dotSize: CGFloat = 3.4
        let gap: CGFloat = 9
        let startX = rect.midX - (dotSize * 3 + gap * 2) / 2
        for index in 0..<3 {
            let wave = (sin(phase * 1.0 + CGFloat(index) * 0.9) + 1) / 2
            let size = dotSize * (0.8 + wave * 0.45)
            let x = startX + CGFloat(index) * (dotSize + gap) + (dotSize - size) / 2
            let y = rect.midY - size / 2
            baseColor.withAlphaComponent(0.28 + wave * 0.38).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
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

        drawText(L("C"), in: NSRect(x: rect.midX - 8, y: rect.midY - 12, width: 20, height: 24), size: 20, weight: .bold, color: .white)
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
        if let approvalHandler {
            approvalHandler(approvalId, type == "approval.approve")
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

    private func drawText(_ english: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        // Status labels are English; L leaves anything without a translation as is.
        let value = L(english)
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
        return visualAccentColor()
    }

    private func visualAccentColor() -> NSColor {
        visualAccentColor(for: renderedVisualState)
    }

    private func visualAccentColor(for state: IslandVisualState) -> NSColor {
        switch state {
        case .listening:
            return NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.63, alpha: 1)
        case .speaking:
            return NSColor(calibratedRed: 0.18, green: 0.68, blue: 0.98, alpha: 1)
        case .thinking:
            return NSColor(calibratedRed: 0.43, green: 0.60, blue: 1.00, alpha: 1)
        case .running:
            return NSColor(calibratedRed: 0.68, green: 0.54, blue: 0.96, alpha: 1)
        case .approval:
            return NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.20, alpha: 1)
        case .failed:
            return NSColor(calibratedRed: 0.96, green: 0.32, blue: 0.34, alpha: 1)
        case .idle:
            break
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

    /// The action being approved, e.g. "Allow: Use the computer" or "Allow: Clicking".
    private func approvalSummaryText() -> String {
        let action = firstNonEmptyText(state.approvalAction, state.approvalTitle, state.title)
        let lower = action.lowercased()
        if lower.contains("/bin/zsh") || lower.contains("local command") {
            return L("Allow: run a local command")
        }
        // Chinese punctuation already carries its own spacing.
        return action.isEmpty ? L("Allow Crow to continue?") : L("Allow:") + (CrowUILanguage.isChinese ? "" : " ") + L(action)
    }

    /// What exactly will happen: the task, the click target or the text to type.
    private func approvalDetailText() -> String {
        let preview = firstNonEmptyText(state.approvalPreview, state.detail)
        if !preview.isEmpty {
            return preview.replacingOccurrences(of: "\n", with: " ")
        }
        return L("Review required before continuing.")
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

/// Main-thread-only flag shared between a voice turn's stream callbacks.
private final class VoiceTurnFlag: @unchecked Sendable {
    var value = false
}
