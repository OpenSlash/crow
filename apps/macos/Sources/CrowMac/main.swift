import AppKit
import Combine
import Foundation

func CrowMacLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return
    }
    let dir = support.appendingPathComponent("Crow", isDirectory: true)
    let url = dir.appendingPathComponent("CrowMac.log")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else {
        return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    if let data = line.data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
}

struct CrowSession: Decodable {
    let pid: Int
    let baseURL: String
    let token: String
    let startedAt: String
}

struct RuntimeSnapshot: Decodable {
    let state: RuntimeState?
    let recentTasks: [CrowTask]
    let pendingApprovals: [Approval]

    enum CodingKeys: String, CodingKey {
        case state
        case recentTasks
        case pendingApprovals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(RuntimeState.self, forKey: .state)
        recentTasks = try container.decodeIfPresent([CrowTask].self, forKey: .recentTasks) ?? []
        pendingApprovals = try container.decodeIfPresent([Approval].self, forKey: .pendingApprovals) ?? []
    }
}

struct RuntimeState: Decodable {
    let status: String
    let phase: String
    let title: String
    let message: String
    let activeTaskId: String
    let pendingApprovals: Int
    let voiceListening: Bool
    let voiceSpeaking: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case phase
        case title
        case message
        case activeTaskId
        case pendingApprovals
        case voiceListening
        case voiceSpeaking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        activeTaskId = try container.decodeIfPresent(String.self, forKey: .activeTaskId) ?? ""
        pendingApprovals = try container.decodeIfPresent(Int.self, forKey: .pendingApprovals) ?? 0
        voiceListening = try container.decodeIfPresent(Bool.self, forKey: .voiceListening) ?? false
        voiceSpeaking = try container.decodeIfPresent(Bool.self, forKey: .voiceSpeaking) ?? false
    }
}

struct CrowTask: Decodable {
    let id: String
    let title: String
    let kind: String
    let status: String
    let subtitle: String
    let createdAt: String
    let updatedAt: String
}

struct TaskDetail: Decodable {
    let task: CrowTask?
    let events: [TaskEvent]
    let pendingApproval: Approval?

    enum CodingKeys: String, CodingKey {
        case task
        case events
        case pendingApproval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decodeIfPresent(CrowTask.self, forKey: .task)
        events = try container.decodeIfPresent([TaskEvent].self, forKey: .events) ?? []
        pendingApproval = try container.decodeIfPresent(Approval.self, forKey: .pendingApproval)
    }
}

struct TaskEvent: Decodable {
    let id: String
    let taskId: String
    let type: String
    let title: String
    let message: String
    let createdAt: String
}

struct Approval: Decodable {
    let id: String
    let taskId: String
    let title: String
    let description: String
    let riskLevel: Int
    let proposedAction: String
    let preview: String
    let status: String
    let createdAt: String
    let decidedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskId
        case title
        case description
        case riskLevel
        case proposedAction
        case preview
        case status
        case createdAt
        case decidedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        riskLevel = try container.decodeIfPresent(Int.self, forKey: .riskLevel) ?? 0
        proposedAction = try container.decodeIfPresent(String.self, forKey: .proposedAction) ?? ""
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        decidedAt = try container.decodeIfPresent(String.self, forKey: .decidedAt) ?? ""
    }
}

struct RuntimeSettings: Codable {
    var sttLanguage: String = ""
    var ttsProvider: String = ""
    var ttsVoice: String = ""
    var ttsStreaming: Bool = true
    var islandScreen: String = ""
    var islandHotkey: String = ""
    var islandIdleCloseSeconds: String = ""
    var islandAvatarStyle: String = ""

    enum CodingKeys: String, CodingKey {
        case sttLanguage
        case ttsProvider
        case ttsVoice
        case ttsStreaming
        case islandScreen
        case islandHotkey
        case islandIdleCloseSeconds
        case islandAvatarStyle
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sttLanguage = try container.decodeIfPresent(String.self, forKey: .sttLanguage) ?? ""
        ttsProvider = try container.decodeIfPresent(String.self, forKey: .ttsProvider) ?? ""
        ttsVoice = try container.decodeIfPresent(String.self, forKey: .ttsVoice) ?? ""
        ttsStreaming = try container.decodeIfPresent(Bool.self, forKey: .ttsStreaming) ?? true
        islandScreen = try container.decodeIfPresent(String.self, forKey: .islandScreen) ?? ""
        islandHotkey = try container.decodeIfPresent(String.self, forKey: .islandHotkey) ?? ""
        islandIdleCloseSeconds = try container.decodeIfPresent(String.self, forKey: .islandIdleCloseSeconds) ?? ""
        islandAvatarStyle = try container.decodeIfPresent(String.self, forKey: .islandAvatarStyle) ?? ""
    }

    func requestBody() -> [String: Any] {
        [
            "settings": [
                "sttLanguage": sttLanguage,
                "ttsProvider": ttsProvider,
                "ttsVoice": ttsVoice,
                "ttsStreaming": ttsStreaming,
                "islandScreen": islandScreen,
                "islandHotkey": islandHotkey,
                "islandIdleCloseSeconds": islandIdleCloseSeconds
            ]
        ]
    }

    func runtimeEnvironmentValues() -> [String: String] {
        [
            "CROW_STT_LANGUAGE": sttLanguage,
            "CROW_TTS_PROVIDER": ttsProvider,
            "CROW_TTS_VOICE": ttsVoice,
            "CROW_OPENAI_TTS_VOICE": ttsVoice,
            "CROW_TTS_STREAMING": ttsStreaming ? "true" : "false",
            "CROW_ISLAND_SCREEN": islandScreen,
            "CROW_ISLAND_HOTKEY": islandHotkey,
            "CROW_ISLAND_IDLE_CLOSE_SECONDS": islandIdleCloseSeconds,
            "CROW_ISLAND_AVATAR_STYLE": islandAvatarStyle
        ].filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct ExecutorDescriptor: Decodable {
    let id: String
    let name: String
    let description: String?
    let version: String?
    let publisher: String?
    let homepage: String?
    let adapter: String
    let kinds: [String]?
    let source: String?
    let command: String?
    let enabled: Bool
    let configured: Bool
    let healthy: Bool
    let healthStatus: String
    let healthMessage: String?
    let supportsStreaming: Bool
    let supportsApproval: Bool
    let fallback: Bool?
}

struct ExecutorsSnapshot: Decodable {
    let executors: [ExecutorDescriptor]
    let configDirs: [String]
    let warnings: [String]?
}

@MainActor
final class CrowDaemonSupervisor {
    private var process: Process?
    private let fileManager = FileManager.default

    func ensureRunning() {
        CrowMacLog("daemon ensureRunning")
        if let session = readSession(), isProcessRunning(session.pid) {
            CrowMacLog("daemon already running pid=\(session.pid)")
            return
        }
        removeSession()
        launchDaemon()
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func readSession() -> CrowSession? {
        let url = sessionURL()
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(CrowSession.self, from: data)
    }

    func waitForSession(timeout: TimeInterval = 8) async -> CrowSession? {
        ensureRunning()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let session = readSession(), isProcessRunning(session.pid) {
                return session
            }
            try? await Swift.Task.sleep(nanoseconds: 200_000_000)
        }
        return readSession()
    }

    private func launchDaemon() {
        CrowMacLog("daemon launch requested")
        guard let daemonDir = findRepoRoot()?.appendingPathComponent("apps/daemon", isDirectory: true) else {
            CrowMacLog("daemon launch failed repo root not found")
            NSLog("Crow daemon launch failed: repo root not found")
            return
        }
        guard let goExecutable = findGoExecutable() else {
            CrowMacLog("daemon launch failed go not found")
            NSLog("Crow daemon launch failed: go executable not found")
            return
        }
        CrowMacLog("daemon launch go=\(goExecutable.path) dir=\(daemonDir.path)")

        let process = Process()
        process.executableURL = goExecutable
        process.arguments = ["run", "./cmd/crowd"]
        process.currentDirectoryURL = daemonDir
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            environment["PATH"],
            "/usr/local/go/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ].compactMap { $0 }.joined(separator: ":")
        process.environment = environment

        let log = daemonLogHandle()
        process.standardOutput = log
        process.standardError = log

        do {
            try process.run()
            self.process = process
            CrowMacLog("daemon process started pid=\(process.processIdentifier)")
        } catch {
            CrowMacLog("daemon launch failed \(error.localizedDescription)")
            NSLog("Crow daemon launch failed: \(error.localizedDescription)")
        }
    }

    private func findGoExecutable() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["CROW_GO_PATH"],
            "/usr/local/go/bin/go",
            "/opt/homebrew/bin/go",
            "/usr/local/bin/go",
            "/usr/bin/go"
        ].compactMap { $0 }
        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func daemonLogHandle() -> FileHandle? {
        let url = applicationSupportURL().appendingPathComponent("crowd.log")
        try? fileManager.createDirectory(at: applicationSupportURL(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        _ = try? handle.seekToEnd()
        return handle
    }

    private func sessionURL() -> URL {
        applicationSupportURL()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    private func removeSession() {
        try? fileManager.removeItem(at: sessionURL())
    }

    private func applicationSupportURL() -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crow", isDirectory: true)
    }

    private func isProcessRunning(_ pid: Int) -> Bool {
        pid > 0 && kill(pid_t(pid), 0) == 0
    }

    private func findRepoRoot() -> URL? {
        var url = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        for _ in 0..<8 {
            if fileManager.fileExists(atPath: url.appendingPathComponent("apps/daemon/go.mod").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            if fileManager.fileExists(atPath: source.appendingPathComponent("apps/daemon/go.mod").path) {
                return source
            }
            source.deleteLastPathComponent()
        }
        return nil
    }
}

@MainActor
final class CrowRPCClient {
    private let session: CrowSession
    private let decoder: JSONDecoder

    init(session: CrowSession) {
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func getSnapshot() async throws -> RuntimeSnapshot {
        try await unary("/crow.v1.CrowRuntimeService/GetSnapshot", body: [:])
    }

    func createTask(command: String, mode: String = "agent") async throws -> CrowTask {
        try await unary("/crow.v1.TaskService/CreateTask", body: [
            "command": command,
            "mode": mode
        ])
    }

    func getTask(taskId: String) async throws -> TaskDetail {
        try await unary("/crow.v1.TaskService/GetTask", body: [
            "taskId": taskId
        ])
    }

    func watchTask(taskId: String) throws -> AsyncThrowingStream<TaskEvent, Error> {
        guard let url = URL(string: session.baseURL + "/crow.v1.TaskService/WatchTask") else {
            throw NSError(domain: "CrowRPCClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid daemon URL"])
        }
        let token = session.token
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let requestBody = try JSONSerialization.data(withJSONObject: ["taskId": taskId], options: [])
        let envelopedBody = connectEnvelope(payload: requestBody)

        return AsyncThrowingStream { continuation in
            let task = Swift.Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/connect+json", forHTTPHeaderField: "Accept")
                    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
                    request.setValue(token, forHTTPHeaderField: "x-crow-session-token")
                    request.httpBody = envelopedBody

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw NSError(domain: "CrowRPCClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid daemon stream response"])
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw NSError(domain: "CrowRPCClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Task stream failed with HTTP \(http.statusCode)"])
                    }

                    var iterator = bytes.makeAsyncIterator()
                    while !Swift.Task.isCancelled {
                        guard let flags = try await iterator.next() else {
                            break
                        }
                        var lengthBytes: [UInt8] = []
                        lengthBytes.reserveCapacity(4)
                        for _ in 0..<4 {
                            guard let byte = try await iterator.next() else {
                                throw NSError(domain: "CrowRPCClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Truncated Connect stream frame"])
                            }
                            lengthBytes.append(byte)
                        }
                        let length = (UInt32(lengthBytes[0]) << 24)
                            | (UInt32(lengthBytes[1]) << 16)
                            | (UInt32(lengthBytes[2]) << 8)
                            | UInt32(lengthBytes[3])
                        var payload = Data()
                        payload.reserveCapacity(Int(length))
                        for _ in 0..<Int(length) {
                            guard let byte = try await iterator.next() else {
                                throw NSError(domain: "CrowRPCClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "Truncated Connect stream payload"])
                            }
                            payload.append(byte)
                        }
                        if flags & 0x02 != 0 {
                            break
                        }
                        continuation.yield(try decoder.decode(TaskEvent.self, from: payload))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func decideApproval(approvalId: String, approved: Bool, reason: String = "") async throws -> Approval {
        try await unary("/crow.v1.ApprovalService/DecideApproval", body: [
            "approvalId": approvalId,
            "approved": approved,
            "reason": reason
        ])
    }

    func getSettings() async throws -> RuntimeSettings {
        try await unary("/crow.v1.SettingsService/GetSettings", body: [:])
    }

    func saveSettings(_ settings: RuntimeSettings) async throws -> RuntimeSettings {
        try await unary("/crow.v1.SettingsService/SaveSettings", body: settings.requestBody())
    }

    func getExecutors(deep: Bool = false) async throws -> ExecutorsSnapshot {
        let path = deep ? "/v1/executors?deep=1" : "/v1/executors"
        guard let url = URL(string: session.baseURL + path) else {
            throw NSError(domain: "CrowRPCClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid daemon URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.token, forHTTPHeaderField: "x-crow-session-token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Executor request failed"
            throw NSError(domain: "CrowRPCClient", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try decoder.decode(ExecutorsSnapshot.self, from: data)
    }

    private func unary<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: session.baseURL + path) else {
            throw NSError(domain: "CrowRPCClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid daemon URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(session.token, forHTTPHeaderField: "x-crow-session-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CrowRPCClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid daemon response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CrowRPCClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try decoder.decode(T.self, from: data)
    }

    private func connectEnvelope(payload: Data) -> Data {
        var data = Data()
        data.append(0)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            data.append(contentsOf: bytes)
        }
        data.append(payload)
        return data
    }
}

@MainActor
final class CrowAppModel: ObservableObject {
    @Published var statusText = "Starting Crow..."
    @Published var detailText = "Preparing daemon"
    @Published var tasks: [CrowTask] = []
    @Published var pendingApprovals = 0
    @Published var commandText = ""
    @Published var isBusy = false
    @Published var activeTask: CrowTask?
    @Published var activeEvents: [TaskEvent] = []
    @Published var activeOutput = "No active task."
    @Published var activeIslandOutput = "Crow is ready."
    @Published var activeApproval: Approval?
    @Published var approvalError = ""
    @Published var settings = RuntimeSettings()
    @Published var settingsStatus = "Settings not loaded"
    @Published var executorsSnapshot = ExecutorsSnapshot(executors: [], configDirs: [], warnings: nil)
    @Published var executorsStatus = "Executors not loaded"

    private let supervisor = CrowDaemonSupervisor()
    private var client: CrowRPCClient?
    private var refreshTimer: Timer?
    private var activeTaskTimer: Timer?
    private var activeTaskID: String?
    private var isRefreshingActiveTask = false
    private var activeTaskWatch: Swift.Task<Void, Never>?
    private var watchedTaskID: String?
    private let islandStateEncoder = JSONEncoder()
    private let islandStateDateFormatter = ISO8601DateFormatter()

    func start() {
        Swift.Task {
            await connect()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Swift.Task { await self?.refresh() }
            }
            activeTaskTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                Swift.Task { @MainActor in
                    self?.refreshActiveTask()
                }
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        activeTaskTimer?.invalidate()
        activeTaskWatch?.cancel()
        supervisor.stop()
    }

    func refresh() async {
        do {
            if client == nil {
                await connect()
                return
            }
            guard let client else { return }
            let snapshot = try await client.getSnapshot()
            apply(snapshot)
            if settingsStatus == "Settings not loaded" {
                await loadSettings()
            }
        } catch {
            statusText = "Crow disconnected"
            detailText = error.localizedDescription
            client = nil
        }
    }

    func createTask() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        createTask(command: command, mode: "agent")
    }

    func createTask(command: String, mode: String = "agent") {
        guard !command.isEmpty, !isBusy else { return }
        isBusy = true
        Swift.Task {
            do {
                if client == nil {
                    await connect()
                }
                guard let client else { throw NSError(domain: "CrowAppModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Daemon is not connected"]) }
                let task = try await client.createTask(command: command, mode: mode)
                activeTaskID = task.id
                activeTask = task
                watchActiveTask()
                commandText = ""
                statusText = "Task started"
                detailText = task.title
                await refresh()
            } catch {
                statusText = "Task failed"
                detailText = error.localizedDescription
            }
            isBusy = false
        }
    }

    func decideActiveApproval(approved: Bool) {
        guard let approval = activeApproval, !isBusy else { return }
        isBusy = true
        approvalError = ""
        Swift.Task {
            do {
                guard let client else { throw NSError(domain: "CrowAppModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Daemon is not connected"]) }
                _ = try await client.decideApproval(
                    approvalId: approval.id,
                    approved: approved,
                    reason: approved ? "Approved from Crow macOS" : "Rejected from Crow macOS"
                )
                activeApproval = nil
                writeIslandState()
                await refresh()
            } catch {
                approvalError = error.localizedDescription
            }
            isBusy = false
        }
    }

    func loadSettings() async {
        do {
            if client == nil {
                await connect()
            }
            guard let client else { return }
            settings = try await client.getSettings()
            settings.islandAvatarStyle = CrowEnvironment.value("CROW_ISLAND_AVATAR_STYLE") ?? settings.islandAvatarStyle
            await loadExecutors()
            settingsStatus = "Settings loaded"
        } catch {
            settingsStatus = error.localizedDescription
        }
    }

    func loadExecutors(deep: Bool = false) async {
        do {
            if client == nil {
                await connect()
            }
            guard let client else { return }
            executorsStatus = deep ? "Checking executors..." : executorsStatus
            executorsSnapshot = try await client.getExecutors(deep: deep)
            let enabled = executorsSnapshot.executors.filter { $0.enabled && !$0.id.isEmpty }.count
            executorsStatus = "\(enabled) executor\(enabled == 1 ? "" : "s") available"
        } catch {
            executorsStatus = error.localizedDescription
        }
    }

    func saveSettings(_ nextSettings: RuntimeSettings) {
        guard !isBusy else { return }
        isBusy = true
        settingsStatus = "Saving settings..."
        Swift.Task {
            do {
                guard let client else { throw NSError(domain: "CrowAppModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Daemon is not connected"]) }
                settings = try await client.saveSettings(nextSettings)
                settings.islandAvatarStyle = nextSettings.islandAvatarStyle
                try persistRuntimeSettings(settings)
                CrowHotKeyCenter.shared.reload()
                settingsStatus = "Settings saved"
            } catch {
                settingsStatus = error.localizedDescription
            }
            isBusy = false
        }
    }

    func persistRuntimeSettings(_ settings: RuntimeSettings) throws {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "CrowAppModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable"])
        }
        let dir = support.appendingPathComponent("Crow", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("runtime-settings.json")
        let data = try JSONEncoder().encode(settings.runtimeEnvironmentValues())
        try data.write(to: url, options: [.atomic])
    }

    private func connect() async {
        statusText = "Connecting to Crow..."
        detailText = "Starting daemon if needed"
        guard let session = await supervisor.waitForSession() else {
            statusText = "Daemon unavailable"
            detailText = "Could not read runtime session"
            return
        }
        client = CrowRPCClient(session: session)
        await refresh()
    }

    private func apply(_ snapshot: RuntimeSnapshot) {
        if let state = snapshot.state {
            statusText = state.title.isEmpty ? "Crow" : state.title
            detailText = state.message.isEmpty ? state.phase : state.message
            pendingApprovals = state.pendingApprovals
        } else {
            statusText = "Crow"
            detailText = "Ready"
            pendingApprovals = snapshot.pendingApprovals.count
        }
        if activeApproval == nil || !snapshot.pendingApprovals.contains(where: { $0.id == activeApproval?.id }) {
            activeApproval = snapshot.pendingApprovals.first
        }
        tasks = snapshot.recentTasks
        if let runtimeActiveTaskID = snapshot.state?.activeTaskId, !runtimeActiveTaskID.isEmpty, runtimeActiveTaskID != activeTaskID {
            activeTaskID = runtimeActiveTaskID
            activeTask = snapshot.recentTasks.first(where: { $0.id == runtimeActiveTaskID })
            activeEvents = []
            activeOutput = "Waiting for task events."
            activeIslandOutput = stateMessageForIsland(snapshot.state)
            activeApproval = snapshot.pendingApprovals.first(where: { $0.taskId == runtimeActiveTaskID }) ?? activeApproval
            activeTaskWatch?.cancel()
            watchedTaskID = nil
            isRefreshingActiveTask = false
        } else if activeTaskID == nil {
            activeTaskID = snapshot.recentTasks.first?.id
        } else if let activeTaskID, !snapshot.recentTasks.contains(where: { $0.id == activeTaskID }) {
            self.activeTaskID = snapshot.recentTasks.first?.id
        }
        writeIslandState()
        watchActiveTask()
        refreshActiveTask()
    }

    func selectTask(_ task: CrowTask) {
        activeTaskID = task.id
        activeTask = task
        watchActiveTask()
        refreshActiveTask()
    }

    private func watchActiveTask() {
        guard let client, let activeTaskID else { return }
        guard watchedTaskID != activeTaskID else { return }
        activeTaskWatch?.cancel()
        watchedTaskID = activeTaskID

        do {
            let stream = try client.watchTask(taskId: activeTaskID)
            activeTaskWatch = Swift.Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run {
                            self?.applyTaskEvent(event)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    await MainActor.run {
                        guard self?.watchedTaskID == activeTaskID else { return }
                        self?.detailText = "Task stream disconnected"
                        self?.refreshActiveTask()
                    }
                }
            }
        } catch {
            detailText = error.localizedDescription
        }
    }

    private func applyTaskEvent(_ event: TaskEvent) {
        guard event.taskId == activeTaskID else { return }
        if !activeEvents.contains(where: { $0.id == event.id }) {
            activeEvents.append(event)
        }
        activeOutput = summarizeOutput(events: activeEvents)
        activeIslandOutput = summarizeIslandOutput(events: activeEvents)
        if isUserVisibleTaskEvent(event), !event.title.isEmpty {
            statusText = event.title
        }
        if isUserVisibleTaskEvent(event), !event.message.isEmpty {
            detailText = event.message
        }
        writeIslandState()
        switch event.type {
        case "approval.required", "task.completed", "task.failed":
            refreshActiveTask()
        default:
            break
        }
    }

    private func refreshActiveTask() {
        guard let client, let activeTaskID, !isRefreshingActiveTask else { return }
        isRefreshingActiveTask = true
        Swift.Task {
            defer {
                Task { @MainActor in
                    self.isRefreshingActiveTask = false
                }
            }
            do {
                let detail = try await client.getTask(taskId: activeTaskID)
                activeTask = detail.task
                activeEvents = detail.events
                activeOutput = summarizeOutput(events: detail.events)
                activeIslandOutput = summarizeIslandOutput(events: detail.events)
                activeApproval = detail.pendingApproval ?? activeApproval
                writeIslandState()
            } catch {
                activeOutput = error.localizedDescription
                activeIslandOutput = error.localizedDescription
                writeIslandState()
            }
        }
    }

    private func summarizeOutput(events: [TaskEvent]) -> String {
        if let completed = events.last(where: { $0.type == "task.completed" }) {
            return completed.message.isEmpty ? completed.title : completed.message
        }
        if let output = events.last(where: { $0.type == "voice.output.segment" || $0.type == "executor.output" }) {
            return output.message.isEmpty ? output.title : output.message
        }
        if let latest = events.last(where: isUserVisibleTaskEvent) {
            return latest.message.isEmpty ? latest.title : latest.message
        }
        return "Waiting for task events."
    }

    private func summarizeIslandOutput(events: [TaskEvent]) -> String {
        if let completed = events.last(where: { $0.type == "task.completed" || $0.type == "task.failed" }) {
            return completed.message.isEmpty ? completed.title : completed.message
        }
        if let voice = events.last(where: { $0.type == "voice.output.segment" }) {
            return voice.message.isEmpty ? voice.title : voice.message
        }
        if let output = events.last(where: { $0.type == "executor.output" }) {
            return output.message.isEmpty ? output.title : output.message
        }
        if let latest = events.last(where: isIslandVisibleTaskEvent) {
            return latest.message.isEmpty ? latest.title : latest.message
        }
        return "Crow is ready."
    }

    private func stateMessageForIsland(_ state: RuntimeState?) -> String {
        guard let state else { return "Crow is ready." }
        if !state.message.isEmpty {
            return state.message
        }
        if !state.title.isEmpty {
            return state.title
        }
        return "Crow is ready."
    }

    func currentIslandState() -> IslandState {
        let task = activeTask
        let approval = activeApproval
        let latestEvent = activeEvents.last(where: isIslandVisibleTaskEvent)
        let phase = islandPhase(task: task, approval: approval, latestEvent: latestEvent)
        let title = islandTitle(task: task, approval: approval, latestEvent: latestEvent)
        let message = approval == nil ? activeIslandOutput : approval?.proposedAction ?? detailText
        return IslandState(
            status: approval == nil ? (task?.status ?? "idle") : "waiting_approval",
            title: title,
            message: message,
            kind: task?.kind ?? "assistant",
            phase: phase,
            action: approval?.proposedAction ?? task?.subtitle,
            detail: approval?.preview ?? activeIslandOutput,
            executor: islandExecutor(task: task),
            pendingApprovals: pendingApprovals,
            approvalId: approval?.id,
            approvalTitle: approval?.title,
            approvalAction: approval?.proposedAction,
            approvalPreview: approval?.preview,
            approvalRisk: approval?.riskLevel,
            updatedAt: islandUpdatedAt(task: task, approval: approval, latestEvent: latestEvent)
        )
    }

    private func isUserVisibleTaskEvent(_ event: TaskEvent) -> Bool {
        !isInternalTaskEventType(event.type)
    }

    private func isIslandVisibleTaskEvent(_ event: TaskEvent) -> Bool {
        !isInternalTaskEventType(event.type)
    }

    private func isInternalTaskEventType(_ type: String) -> Bool {
        switch type {
        case "executor.stderr", "debug", "debug.log":
            return true
        default:
            return type.hasSuffix(".stderr") || type.contains(".debug")
        }
    }

    private func islandTitle(task: CrowTask?, approval: Approval?, latestEvent: TaskEvent?) -> String {
        if approval != nil {
            return "Approval Required"
        }
        if let latestEvent, latestEvent.type == "task.completed" || latestEvent.type == "task.failed" {
            return latestEvent.title.isEmpty ? (task?.subtitle ?? statusText) : latestEvent.title
        }
        if let latestEvent, latestEvent.type == "voice.output.segment" {
            return "Crow speaking"
        }
        return task?.subtitle.isEmpty == false ? task?.subtitle ?? "Crow" : statusText
    }

    private func islandExecutor(task: CrowTask?) -> String? {
        switch task?.kind {
        case "agent", "code":
            return "acp"
        default:
            return nil
        }
    }

    private func islandUpdatedAt(task: CrowTask?, approval: Approval?, latestEvent: TaskEvent?) -> String {
        if let latestEvent, !latestEvent.createdAt.isEmpty {
            return latestEvent.createdAt
        }
        if let approval, !approval.createdAt.isEmpty {
            return approval.createdAt
        }
        if let task, !task.updatedAt.isEmpty {
            return task.updatedAt
        }
        return islandStateDateFormatter.string(from: Date())
    }

    private func writeIslandState() {
        let state = currentIslandState()
        do {
            let directory = try islandStateDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try islandStateEncoder.encode(state)
            try data.write(to: directory.appendingPathComponent("island-state.json"), options: .atomic)
        } catch {
            NSLog("Crow island state write failed: \(error.localizedDescription)")
        }
    }

    private func islandStateDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "CrowAppModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable"])
        }
        return support.appendingPathComponent("Crow", isDirectory: true)
    }

    private func islandPhase(task: CrowTask?, approval: Approval?, latestEvent: TaskEvent?) -> String {
        if approval != nil {
            return "approval"
        }
        switch latestEvent?.type {
        case "voice.output.segment":
            return "speaking"
        case "executor.output":
            return "responding"
        case "executor.plan":
            return "planning"
        case "executor.thought", "step.started":
            return "thinking"
        case "tool.started", "tool.completed":
            return "tool"
        case "task.completed":
            return "completed"
        case "task.failed":
            return "failed"
        default:
            break
        }
        switch task?.status {
        case "running":
            return "running"
        case "waiting_approval":
            return "approval"
        case "completed":
            return "completed"
        case "failed", "cancelled":
            return "failed"
        default:
            return "idle"
        }
    }
}

final class HotKeyRecorderButton: NSButton {
    var hotKeyValue: String = "" {
        didSet {
            if !isRecording {
                title = Self.displayText(for: hotKeyValue)
            }
        }
    }
    var onChange: ((String) -> Void)?
    private var isRecording = false
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleKeyEvent(event)
    }

    private func beginRecording() {
        removeEventMonitor()
        isRecording = true
        title = "Press shortcut"
        window?.makeFirstResponder(self)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else {
                return event
            }
            self.handleKeyEvent(event)
            return nil
        }
    }

    private func endRecording(commit: Bool) {
        isRecording = false
        title = Self.displayText(for: hotKeyValue)
        removeEventMonitor()
        if !commit {
            window?.makeFirstResponder(nil)
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if event.keyCode == 53 {
            endRecording(commit: false)
            return
        }
        guard let value = Self.hotKeyString(from: event) else {
            NSSound.beep()
            return
        }
        hotKeyValue = value
        onChange?(value)
        endRecording(commit: true)
    }

    static func displayText(for value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "Record shortcut"
        }
        return normalized
            .replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "command", with: "⌘")
            .replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "control", with: "⌃")
            .replacingOccurrences(of: "option", with: "⌥")
            .replacingOccurrences(of: "opt", with: "⌥")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "space", with: "Space")
    }

    private static func hotKeyString(from event: NSEvent) -> String? {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        guard !parts.isEmpty else {
            return nil
        }
        guard let key = keyName(for: event) else {
            return nil
        }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static func keyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 49:
            return "space"
        case 36:
            return "return"
        case 48:
            return "tab"
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard chars.count == 1,
                  let scalar = chars.unicodeScalars.first,
                  CharacterSet.alphanumerics.contains(scalar) else {
                return nil
            }
            return chars
        }
    }
}

final class CrowWindowController: NSWindowController {
    private enum MainView: Int {
        case subscription = 0
        case settings = 1
        case executors = 2
    }

    private let model: CrowAppModel
    private let statusLabel = NSTextField(labelWithString: "Crow")
    private let detailLabel = NSTextField(labelWithString: "Starting")
    private var navRows: [MainView: ClickableStackView] = [:]
    private let viewControl = NSSegmentedControl(labels: ["Account", "Settings", "Executors"], trackingMode: .selectOne, target: nil, action: nil)
    private let contentStack = NSStackView()
    private let historyPage = NSStackView()
    private let settingsPage = NSStackView()
    private let executorsPage = NSStackView()
    private let subscriptionPage = NSStackView()
    private let commandField = NSTextField(string: "")
    private let taskStack = NSStackView()
    private let outputTitleLabel = NSTextField(labelWithString: "Current Task")
    private let outputTextView = NSTextView()
    private let eventStack = NSStackView()
    private let approvalContainer = NSStackView()
    private let approvalTitleLabel = NSTextField(labelWithString: "")
    private let approvalPreviewLabel = NSTextField(labelWithString: "")
    private let sttLanguageField = NSTextField(string: "")
    private let ttsProviderField = NSTextField(string: "")
    private let ttsVoiceField = NSTextField(string: "")
    private let ttsVoicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let islandAvatarPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let islandScreenField = NSTextField(string: "")
    private let islandHotkeyField = NSTextField(string: "")
    private let islandHotkeyRecorder = HotKeyRecorderButton(title: "Record shortcut", target: nil, action: nil)
    private let islandIdleCloseField = NSTextField(string: "")
    private let streamTTSButton = NSButton(checkboxWithTitle: "Stream TTS output", target: nil, action: nil)
    private let settingsStatusLabel = NSTextField(labelWithString: "")
    private let executorSummaryLabel = NSTextField(labelWithString: "")
    private let executorDetailLabel = NSTextField(labelWithString: "")
    private let executorListStack = NSStackView()
    private let openExecutorsFolderButton = NSButton(title: "Open Folder", target: nil, action: nil)
    private let installCodexConnectorButton = NSButton(title: "Add Codex", target: nil, action: nil)
    private let runExecutorHealthCheckButton = NSButton(title: "Run Check", target: nil, action: nil)
    private let subscriptionSummaryLabel = NSTextField(labelWithString: "")
    private let usageSummaryLabel = NSTextField(labelWithString: "")
    private let voiceMinutesValueLabel = NSTextField(labelWithString: "0 min")
    private let tasksRunValueLabel = NSTextField(labelWithString: "0")
    private let approvalsHandledValueLabel = NSTextField(labelWithString: "0")
    private var currentView: MainView = .subscription
    private var pendingIslandAvatarStyle: String?
    private var isRenderingSettings = false

    init(model: CrowAppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Crow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.minSize = NSSize(width: 560, height: 420)
        window.maxSize = NSSize(width: 560, height: 620)
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.contentMaxSize = NSSize(width: 560, height: 620)
        window.center()
        super.init(window: window)
        buildUI()
        bindModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let material = NSVisualEffectView()
        material.material = .windowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(material)

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 42, left: 28, bottom: 16, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(root)

        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            material.topAnchor.constraint(equalTo: contentView.topAnchor),
            material.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            root.topAnchor.constraint(equalTo: material.topAnchor),
            root.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        header.addArrangedSubview(makeCrowIcon())
        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 3
        titleStack.addArrangedSubview(statusLabel)
        titleStack.addArrangedSubview(detailLabel)
        header.addArrangedSubview(titleStack)
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleStack.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        root.addArrangedSubview(header)

        let navWrapper = NSStackView()
        navWrapper.orientation = .horizontal
        navWrapper.alignment = .centerY
        navWrapper.addArrangedSubview(NSView())
        viewControl.target = self
        viewControl.action = #selector(switchMainView)
        viewControl.selectedSegment = MainView.subscription.rawValue
        viewControl.controlSize = .regular
        viewControl.setWidth(76, forSegment: MainView.subscription.rawValue)
        viewControl.setWidth(78, forSegment: MainView.settings.rawValue)
        viewControl.setWidth(86, forSegment: MainView.executors.rawValue)
        viewControl.setContentHuggingPriority(.required, for: .horizontal)
        navWrapper.addArrangedSubview(viewControl)
        navWrapper.addArrangedSubview(NSView())
        root.addArrangedSubview(navWrapper)

        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(contentStack)
        contentStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

        buildSettingsPage()
        buildExecutorsPage()
        buildSubscriptionPage()
        contentStack.addArrangedSubview(settingsPage)
        contentStack.addArrangedSubview(executorsPage)
        contentStack.addArrangedSubview(subscriptionPage)
        updateVisiblePage()
    }

    private func makeSidebarNavRow(_ view: MainView, title: String, symbol: String) -> ClickableStackView {
        let row = ClickableStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        row.toolTip = title
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.cornerCurve = .continuous
        row.onClick = { [weak self] in
            self?.currentView = view
            if view == .settings {
                Swift.Task { await self?.model.loadSettings() }
            }
            self?.updateVisiblePage()
            self?.render()
        }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        row.addArrangedSubview(icon)
        navRows[view] = row
        return row
    }

    private func buildHistoryPage() {
        historyPage.orientation = .vertical
        historyPage.alignment = .centerX
        historyPage.spacing = 14

        let split = NSStackView()
        split.orientation = .vertical
        split.alignment = .centerX
        split.spacing = 14
        split.distribution = .fill
        historyPage.addArrangedSubview(split)

        let historyColumn = NSStackView()
        historyColumn.orientation = .vertical
        historyColumn.alignment = .width
        historyColumn.spacing = 0
        historyColumn.addArrangedSubview(settingsSectionHeader(symbol: "clock", title: "Recent activity", subtitle: "A lightweight record of completed and running tasks"))
        historyColumn.addArrangedSubview(makeSeparator())

        taskStack.orientation = .vertical
        taskStack.spacing = 6
        taskStack.alignment = .width
        taskStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let taskScroll = NSScrollView()
        taskScroll.borderType = .noBorder
        taskScroll.drawsBackground = false
        taskScroll.hasVerticalScroller = true
        taskScroll.documentView = taskStack
        taskScroll.heightAnchor.constraint(equalToConstant: 118).isActive = true
        historyColumn.addArrangedSubview(taskScroll)
        let historyCard = makeCard(historyColumn)
        historyCard.widthAnchor.constraint(equalToConstant: 500).isActive = true

        let detailColumn = NSStackView()
        detailColumn.orientation = .vertical
        detailColumn.alignment = .width
        detailColumn.spacing = 0
        detailColumn.addArrangedSubview(settingsSectionHeader(symbol: "doc.text.magnifyingglass", title: "Selected task", subtitle: "Summary and trace"))
        detailColumn.addArrangedSubview(makeSeparator())

        approvalContainer.orientation = .vertical
        approvalContainer.spacing = 8
        approvalContainer.alignment = .leading
        approvalContainer.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        approvalContainer.wantsLayer = true
        approvalContainer.layer?.cornerRadius = 14
        approvalContainer.layer?.cornerCurve = .continuous
        approvalContainer.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        approvalTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        approvalTitleLabel.lineBreakMode = .byTruncatingTail
        approvalPreviewLabel.font = .systemFont(ofSize: 12)
        approvalPreviewLabel.textColor = .secondaryLabelColor
        approvalPreviewLabel.maximumNumberOfLines = 4
        approvalPreviewLabel.lineBreakMode = .byWordWrapping
        approvalContainer.addArrangedSubview(approvalTitleLabel)
        approvalContainer.addArrangedSubview(approvalPreviewLabel)

        let approvalActions = NSStackView()
        approvalActions.orientation = .horizontal
        approvalActions.spacing = 8
        let approve = NSButton(title: "Approve", target: self, action: #selector(approveActiveApproval))
        approve.bezelStyle = .rounded
        approve.controlSize = .large
        let reject = NSButton(title: "Reject", target: self, action: #selector(rejectActiveApproval))
        reject.bezelStyle = .rounded
        reject.controlSize = .large
        approvalActions.addArrangedSubview(approve)
        approvalActions.addArrangedSubview(reject)
        approvalContainer.addArrangedSubview(approvalActions)
        detailColumn.addArrangedSubview(approvalContainer)

        outputTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        outputTitleLabel.textColor = .secondaryLabelColor
        outputTitleLabel.lineBreakMode = .byTruncatingTail
        outputTitleLabel.alignment = .left
        outputTitleLabel.drawsBackground = false
        detailColumn.addArrangedSubview(outputTitleLabel)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.drawsBackground = true
        outputTextView.backgroundColor = NSColor.white.withAlphaComponent(0.38)
        outputTextView.font = .systemFont(ofSize: 13)
        outputTextView.textContainerInset = NSSize(width: 12, height: 12)
        outputTextView.isHorizontallyResizable = false
        outputTextView.textContainer?.widthTracksTextView = true
        scroll.documentView = outputTextView
        detailColumn.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 138).isActive = true

        eventStack.orientation = .vertical
        eventStack.spacing = 4
        eventStack.alignment = .width
        eventStack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        detailColumn.addArrangedSubview(eventStack)
        let detailCard = makeCard(detailColumn)
        detailCard.widthAnchor.constraint(equalToConstant: 500).isActive = true
        detailCard.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailCard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        split.addArrangedSubview(historyCard)
        split.addArrangedSubview(detailCard)
    }

    private func buildSettingsPage() {
        settingsPage.orientation = .vertical
        settingsPage.spacing = 14
        settingsPage.alignment = .centerX

        let mainCard = NSStackView()
        mainCard.orientation = .vertical
        mainCard.spacing = 0
        mainCard.alignment = .width

        mainCard.addArrangedSubview(settingsSectionHeader(symbol: "waveform", title: "Voice", subtitle: "Audio output"))
        mainCard.addArrangedSubview(makeSeparator())
        configureTTSVoicePopUp()
        mainCard.addArrangedSubview(settingsPopUpRow(symbol: "speaker.wave.2", title: "Voice", popUp: ttsVoicePopUp))
        mainCard.addArrangedSubview(makeSeparator())
        configureIslandAvatarPopUp()
        mainCard.addArrangedSubview(settingsPopUpRow(symbol: "bird", title: "Island appearance", popUp: islandAvatarPopUp))
        mainCard.addArrangedSubview(makeSeparator())
        configureHotKeyRecorder()
        mainCard.addArrangedSubview(settingsButtonRow(symbol: "keyboard", title: "Shortcut", button: islandHotkeyRecorder))
        mainCard.addArrangedSubview(makeSeparator())
        mainCard.addArrangedSubview(settingsFieldRow(symbol: "timer", title: "Idle close seconds", field: islandIdleCloseField))
        mainCard.addArrangedSubview(makeSeparator())
        settingsPage.addArrangedSubview(makeLargeCard(mainCard, showsBorder: false))

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let reload = NSButton(title: "Reload", target: self, action: #selector(loadSettings))
        reload.bezelStyle = .rounded
        reload.controlSize = .large
        let save = NSButton(title: "Save Settings", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.controlSize = .large
        actions.addArrangedSubview(reload)
        actions.addArrangedSubview(save)
        settingsStatusLabel.textColor = .secondaryLabelColor
        settingsStatusLabel.font = .systemFont(ofSize: 12)
        settingsStatusLabel.lineBreakMode = .byTruncatingTail
        settingsStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(settingsStatusLabel)
        actions.widthAnchor.constraint(equalToConstant: 500).isActive = true
        settingsPage.addArrangedSubview(actions)
    }

    private func buildExecutorsPage() {
        executorsPage.orientation = .vertical
        executorsPage.spacing = 14
        executorsPage.alignment = .centerX

        let mainCard = NSStackView()
        mainCard.orientation = .vertical
        mainCard.spacing = 0
        mainCard.alignment = .width

        mainCard.addArrangedSubview(settingsSectionHeader(symbol: "point.3.connected.trianglepath.dotted", title: "Executors", subtitle: "Plugin connectors Crow can delegate to"))
        mainCard.addArrangedSubview(makeSeparator())
        executorListStack.orientation = .vertical
        executorListStack.spacing = 0
        executorListStack.alignment = .width
        mainCard.addArrangedSubview(executorListStack)
        mainCard.addArrangedSubview(makeSeparator())
        configureExecutorButtons()
        mainCard.addArrangedSubview(settingsActionsRow(symbol: "folder", title: "Adapter configs", buttons: [openExecutorsFolderButton, installCodexConnectorButton, runExecutorHealthCheckButton]))
        executorsPage.addArrangedSubview(makeLargeCard(mainCard, showsBorder: false))

        let hint = NSTextField(labelWithString: "Executors are installed as local connector manifests. Crow does not bundle Codex, Claude Code, OpenClaw, or MCP tools.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.widthAnchor.constraint(equalToConstant: 500).isActive = true
        executorsPage.addArrangedSubview(hint)
    }

    private func buildSubscriptionPage() {
        subscriptionPage.orientation = .vertical
        subscriptionPage.spacing = 12
        subscriptionPage.alignment = .centerX

        let mainCard = NSStackView()
        mainCard.orientation = .vertical
        mainCard.spacing = 0
        mainCard.alignment = .width

        let planHeader = NSStackView()
        planHeader.orientation = .horizontal
        planHeader.alignment = .centerY
        planHeader.spacing = 16
        planHeader.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        planHeader.addArrangedSubview(makeBadgeIcon(symbol: "crown.fill", tint: .systemBlue))

        let planText = NSStackView()
        planText.orientation = .vertical
        planText.spacing = 4
        let planTitleRow = NSStackView()
        planTitleRow.orientation = .horizontal
        planTitleRow.alignment = .centerY
        planTitleRow.spacing = 8
        let planTitle = NSTextField(labelWithString: "Developer Preview")
        planTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        planTitleRow.addArrangedSubview(planTitle)
        planTitleRow.addArrangedSubview(makeSmallBadge("Local mode"))
        planText.addArrangedSubview(planTitleRow)
        let planSubtitle = NSTextField(labelWithString: "Crow is running locally. The notch voice interface is the primary workspace.")
        planSubtitle.font = .systemFont(ofSize: 12)
        planSubtitle.textColor = .secondaryLabelColor
        planSubtitle.maximumNumberOfLines = 2
        planSubtitle.lineBreakMode = .byWordWrapping
        planText.addArrangedSubview(planSubtitle)
        planHeader.addArrangedSubview(planText)
        mainCard.addArrangedSubview(planHeader)

        mainCard.addArrangedSubview(makeSeparator())
        mainCard.addArrangedSubview(accountRow(symbol: "terminal", title: "Daemon (local runtime)", status: "Connected", color: .systemGreen))
        mainCard.addArrangedSubview(makeSeparator())
        mainCard.addArrangedSubview(accountRow(symbol: "rectangle.topthird.inset.filled", title: "Island voice interface", status: "Enabled", color: .systemGreen))
        subscriptionPage.addArrangedSubview(makeLargeCard(mainCard, showsBorder: false))

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        let privacyIcon = NSImageView()
        privacyIcon.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "Privacy")
        privacyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        privacyIcon.contentTintColor = .secondaryLabelColor
        privacyIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        footer.addArrangedSubview(privacyIcon)
        let privacy = NSTextField(labelWithString: "Local data stays on your Mac.")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        footer.addArrangedSubview(privacy)
        footer.addArrangedSubview(NSView())
        footer.widthAnchor.constraint(equalToConstant: 500).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 22).isActive = true
        subscriptionPage.addArrangedSubview(footer)

        let build = NSStackView()
        build.orientation = .horizontal
        build.alignment = .centerY
        let dev = NSTextField(labelWithString: "</>  Developer Preview Build · v0.1.0 (47)")
        dev.font = .systemFont(ofSize: 11)
        dev.textColor = .secondaryLabelColor
        build.addArrangedSubview(dev)
        build.addArrangedSubview(NSView())
        build.widthAnchor.constraint(equalToConstant: 500).isActive = true
        build.heightAnchor.constraint(equalToConstant: 20).isActive = true
        subscriptionPage.addArrangedSubview(build)
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func settingsGrid(_ rows: [(String, NSTextField)]) -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        for (labelText, field) in rows {
            let label = NSTextField(labelWithString: labelText)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.alignment = .right
            field.font = .systemFont(ofSize: 13)
            field.controlSize = .large
            field.lineBreakMode = .byTruncatingTail
            field.widthAnchor.constraint(equalToConstant: 170).isActive = true
            grid.addRow(with: [label, field])
        }
        return grid
    }

    private func makeCard(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10), showsBorder: Bool = true) -> NSStackView {
        let card = NSStackView()
        card.orientation = .vertical
        card.spacing = 0
        card.edgeInsets = insets
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.masksToBounds = true
        card.layer?.cornerRadius = 13
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.50).cgColor
        card.layer?.borderColor = showsBorder ? NSColor.separatorColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        card.layer?.borderWidth = showsBorder ? 0.5 : 0
        card.addArrangedSubview(view)
        return card
    }

    private func makeFixedCard(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)) -> NSStackView {
        let card = makeCard(view, insets: insets)
        card.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return card
    }

    private func makeLargeCard(_ view: NSView, showsBorder: Bool = true) -> NSStackView {
        let card = makeCard(view, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), showsBorder: showsBorder)
        card.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return card
    }

    private func makeCrowIcon() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        box.layer?.borderWidth = 0.5
        box.widthAnchor.constraint(equalToConstant: 42).isActive = true
        box.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Crow")
            ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Crow")
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .semibold)
        imageView.contentTintColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.16, alpha: 1)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28)
        ])
        return box
    }

    private func makeBadgeIcon(symbol: String, tint: NSColor) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 22
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = tint.withAlphaComponent(0.10).cgColor
        box.widthAnchor.constraint(equalToConstant: 52).isActive = true
        box.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        imageView.contentTintColor = tint
        imageView.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28)
        ])
        return box
    }

    private func makeSmallBadge(_ text: String) -> NSTextField {
        let badge = NSTextField(labelWithString: text)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .controlAccentColor
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.cornerCurve = .continuous
        badge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        badge.widthAnchor.constraint(equalToConstant: 72).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return badge
    }

    private func settingsSectionHeader(symbol: String, title: String, subtitle: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        row.addArrangedSubview(makeRoundIcon(symbol))

        let text = NSStackView()
        text.orientation = .vertical
        text.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        text.addArrangedSubview(titleLabel)
        text.addArrangedSubview(subtitleLabel)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        return row
    }

    private func settingsFieldRow(symbol: String, title: String, field: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.addArrangedSubview(rowIcon(symbol))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .regular
        field.lineBreakMode = .byTruncatingTail
        field.widthAnchor.constraint(equalToConstant: 230).isActive = true
        row.addArrangedSubview(field)
        return row
    }

    private func configureTTSVoicePopUp() {
        guard ttsVoicePopUp.numberOfItems == 0 else {
            return
        }
        let voices: [(String, String)] = [
            ("Marin", "marin"),
            ("Alloy", "alloy"),
            ("Ash", "ash"),
            ("Ballad", "ballad"),
            ("Coral", "coral"),
            ("Echo", "echo"),
            ("Fable", "fable"),
            ("Nova", "nova"),
            ("Onyx", "onyx"),
            ("Sage", "sage"),
            ("Shimmer", "shimmer"),
            ("Verse", "verse")
        ]
        for voice in voices {
            let item = NSMenuItem(title: voice.0, action: nil, keyEquivalent: "")
            item.representedObject = voice.1
            ttsVoicePopUp.menu?.addItem(item)
        }
        ttsVoicePopUp.controlSize = .regular
        ttsVoicePopUp.bezelStyle = .rounded
    }

    private func configureIslandAvatarPopUp() {
        guard islandAvatarPopUp.numberOfItems == 0 else {
            return
        }
        addPopUpItems([
            ("Default Crow", "default"),
            ("Cute Crow", "cute"),
            ("Robot", "robot"),
            ("Jarvis Core", "jarvis")
        ], to: islandAvatarPopUp)
        islandAvatarPopUp.target = self
        islandAvatarPopUp.action = #selector(islandAvatarStyleChanged)
    }

    private func addPopUpItems(_ items: [(String, String)], to popUp: NSPopUpButton) {
        for itemValue in items {
            let item = NSMenuItem(title: itemValue.0, action: nil, keyEquivalent: "")
            item.representedObject = itemValue.1
            popUp.menu?.addItem(item)
        }
        popUp.controlSize = .regular
        popUp.bezelStyle = .rounded
    }

    private func configureHotKeyRecorder() {
        islandHotkeyRecorder.bezelStyle = .rounded
        islandHotkeyRecorder.controlSize = .regular
        islandHotkeyRecorder.alignment = .center
        islandHotkeyRecorder.onChange = { [weak self] value in
            self?.islandHotkeyField.stringValue = value
        }
    }

    private func configureExecutorButtons() {
        openExecutorsFolderButton.target = self
        openExecutorsFolderButton.action = #selector(openExecutorsFolder)
        openExecutorsFolderButton.bezelStyle = .rounded
        openExecutorsFolderButton.controlSize = .regular
        installCodexConnectorButton.target = self
        installCodexConnectorButton.action = #selector(installCodexConnector)
        installCodexConnectorButton.bezelStyle = .rounded
        installCodexConnectorButton.controlSize = .regular
        runExecutorHealthCheckButton.target = self
        runExecutorHealthCheckButton.action = #selector(runExecutorHealthCheck)
        runExecutorHealthCheckButton.bezelStyle = .rounded
        runExecutorHealthCheckButton.controlSize = .regular
    }

    private func settingsPopUpRow(symbol: String, title: String, popUp: NSPopUpButton) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.addArrangedSubview(rowIcon(symbol))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())
        popUp.widthAnchor.constraint(equalToConstant: 230).isActive = true
        row.addArrangedSubview(popUp)
        return row
    }

    private func settingsButtonRow(symbol: String, title: String, button: NSButton) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.addArrangedSubview(rowIcon(symbol))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())
        button.widthAnchor.constraint(equalToConstant: 230).isActive = true
        row.addArrangedSubview(button)
        return row
    }

    private func settingsInfoRow(symbol: String, title: String, primary: NSTextField, secondary: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.addArrangedSubview(rowIcon(symbol))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())

        let valueStack = NSStackView()
        valueStack.orientation = .vertical
        valueStack.alignment = .trailing
        valueStack.spacing = 2
        primary.font = .systemFont(ofSize: 13, weight: .medium)
        primary.textColor = .labelColor
        primary.lineBreakMode = .byTruncatingTail
        primary.alignment = .right
        secondary.font = .systemFont(ofSize: 11)
        secondary.textColor = .secondaryLabelColor
        secondary.lineBreakMode = .byTruncatingMiddle
        secondary.alignment = .right
        valueStack.addArrangedSubview(primary)
        valueStack.addArrangedSubview(secondary)
        valueStack.widthAnchor.constraint(equalToConstant: 260).isActive = true
        row.addArrangedSubview(valueStack)
        return row
    }

    private func settingsActionsRow(symbol: String, title: String, buttons: [NSButton]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.addArrangedSubview(rowIcon(symbol))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let buttonWidth: CGFloat = buttons.count > 2 ? 92 : 112
        for button in buttons {
            button.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
            actions.addArrangedSubview(button)
        }
        row.addArrangedSubview(actions)
        return row
    }

    private func settingsToggleRow(symbol: String, title: String, button: NSButton) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.addArrangedSubview(rowIcon(symbol))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())
        button.title = ""
        row.addArrangedSubview(button)
        return row
    }

    private func accountRow(symbol: String, title: String, status: String, color: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
        let icon = rowIcon(symbol)
        row.addArrangedSubview(icon)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = color.cgColor
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        row.addArrangedSubview(dot)
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        row.addArrangedSubview(statusLabel)
        let chevron = rowIcon("chevron.right")
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
        row.addArrangedSubview(chevron)
        return row
    }

    private func usageRow(symbol: String, title: String, valueLabel: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 5, right: 0)
        row.addArrangedSubview(makeRoundIcon(symbol))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NSView())
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func rowIcon(_ symbol: String) -> NSImageView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return icon
    }

    private func makeRoundIcon(_ symbol: String) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 11
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = NSColor.controlColor.withAlphaComponent(0.45).cgColor
        box.widthAnchor.constraint(equalToConstant: 24).isActive = true
        box.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let icon = rowIcon(symbol)
        icon.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func bindModel() {
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Swift.Task { @MainActor in self?.render() }
        }
    }

    @objc private func sendTask() {
        model.commandText = commandField.stringValue
        model.createTask()
    }

    @objc private func switchMainView() {
        currentView = MainView(rawValue: viewControl.selectedSegment) ?? .subscription
        if currentView == .settings {
            Swift.Task { await model.loadSettings() }
        } else if currentView == .executors {
            Swift.Task { await model.loadExecutors() }
        }
        updateVisiblePage()
        render()
    }

    @objc private func loadSettings() {
        Swift.Task {
            await model.loadSettings()
            await model.loadExecutors()
        }
    }

    @objc private func saveSettings() {
        var settings = model.settings
        settings.sttLanguage = sttLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.ttsProvider = ttsProviderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.ttsVoice = selectedTTSVoice()
        settings.ttsStreaming = streamTTSButton.state == .on
        settings.islandScreen = islandScreenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.islandHotkey = islandHotkeyRecorder.hotKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.islandIdleCloseSeconds = islandIdleCloseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.islandAvatarStyle = selectedIslandAvatarStyle()
        pendingIslandAvatarStyle = settings.islandAvatarStyle
        model.saveSettings(settings)
    }

    @objc private func islandAvatarStyleChanged() {
        guard !isRenderingSettings else { return }
        let style = selectedIslandAvatarStyle()
        pendingIslandAvatarStyle = style
        var settings = model.settings
        settings.islandAvatarStyle = style
        try? model.persistRuntimeSettings(settings)
    }

    @objc private func openExecutorsFolder() {
        do {
            let dir = try executorConfigDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
            model.executorsStatus = "Executor folder opened"
        } catch {
            model.executorsStatus = error.localizedDescription
        }
    }

    @objc private func installCodexConnector() {
        do {
            let dir = try executorConfigDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("codex.json")
            if FileManager.default.fileExists(atPath: url.path) {
                model.executorsStatus = "Codex connector already installed"
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
            let data = try JSONSerialization.data(withJSONObject: codexConnectorManifest(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: [.atomic])
            model.executorsStatus = "Codex connector installed"
            NSWorkspace.shared.activateFileViewerSelecting([url])
            Swift.Task { await model.loadExecutors() }
        } catch {
            model.executorsStatus = error.localizedDescription
        }
    }

    @objc private func runExecutorHealthCheck() {
        model.executorsStatus = "Checking executors..."
        renderSettings()
        Swift.Task {
            await model.loadExecutors(deep: true)
        }
    }

    private func executorConfigDirectory() throws -> URL {
        if let first = model.executorsSnapshot.configDirs.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
            return URL(fileURLWithPath: NSString(string: first).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".crow", isDirectory: true)
            .appendingPathComponent("executors", isDirectory: true)
    }

    private func codexConnectorManifest() -> [String: Any] {
        [
            "id": "codex",
            "name": "Codex",
            "description": "Delegates code and agent tasks to a user-installed Codex CLI.",
            "version": "0.1.0",
            "publisher": "Crow",
            "homepage": "https://github.com/openai/codex",
            "adapter": "acp",
            "enabled": true,
            "kinds": ["code", "agent"],
            "command": "codex acp",
            "supportsStreaming": true,
            "supportsApproval": true
        ]
    }

    @objc private func approveActiveApproval() {
        model.decideActiveApproval(approved: true)
    }

    @objc private func rejectActiveApproval() {
        model.decideActiveApproval(approved: false)
    }

    private func render() {
        if currentView == .settings {
            statusLabel.stringValue = "Settings"
            detailLabel.stringValue = "Voice, island, and assistant preferences"
        } else if currentView == .executors {
            statusLabel.stringValue = "Executors"
            detailLabel.stringValue = "Local connectors Crow can delegate to"
        } else {
            statusLabel.stringValue = "Crow"
            detailLabel.stringValue = "Account, subscription, and usage"
        }
        if commandField.stringValue != model.commandText && model.commandText.isEmpty {
            commandField.stringValue = ""
        }
        renderSettings()
        renderExecutors()
        renderSubscription()

        taskStack.arrangedSubviews.forEach { view in
            taskStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if model.tasks.isEmpty {
            let empty = NSTextField(labelWithString: "No tasks yet")
            empty.textColor = .tertiaryLabelColor
            empty.font = .systemFont(ofSize: 13, weight: .medium)
            empty.alignment = .center
            empty.widthAnchor.constraint(equalToConstant: 460).isActive = true
            taskStack.addArrangedSubview(empty)
        } else {
            for task in model.tasks.prefix(8) {
                taskStack.addArrangedSubview(taskRow(task))
            }
        }
        renderApproval()
        renderActiveTask()
    }

    private func updateVisiblePage() {
        historyPage.isHidden = true
        settingsPage.isHidden = currentView != .settings
        executorsPage.isHidden = currentView != .executors
        subscriptionPage.isHidden = currentView != .subscription
        for (view, row) in navRows {
            let selected = view == currentView
            row.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
            for arranged in row.arrangedSubviews {
                if let imageView = arranged as? NSImageView {
                    imageView.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
                } else if let label = arranged as? NSTextField {
                    label.textColor = selected ? .labelColor : .secondaryLabelColor
                }
            }
        }
    }

    private func taskRow(_ task: CrowTask) -> NSView {
        let stack = ClickableStackView()
        stack.onClick = { [weak self] in
            self?.model.selectTask(task)
        }
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 11
        stack.layer?.cornerCurve = .continuous
        stack.layer?.backgroundColor = task.id == model.activeTask?.id
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.controlColor.withAlphaComponent(0.22).cgColor

        let title = NSTextField(labelWithString: task.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let meta = NSTextField(labelWithString: "\(task.status) · \(task.kind) · \(task.subtitle)")
        meta.font = .systemFont(ofSize: 12)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(meta)
        stack.widthAnchor.constraint(equalToConstant: 456).isActive = true
        return stack
    }

    private func renderActiveTask() {
        if let task = model.activeTask {
            outputTitleLabel.stringValue = compactWindowText("\(task.status.uppercased()) · \(task.title)", limit: 58)
        } else {
            outputTitleLabel.stringValue = "Current Task"
        }
        outputTextView.string = model.activeOutput

        eventStack.arrangedSubviews.forEach { view in
            eventStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for event in model.activeEvents.suffix(6) {
            let label = NSTextField(labelWithString: "\(event.type) · \(event.title)")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            eventStack.addArrangedSubview(label)
        }
    }

    private func compactWindowText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return String(text[..<end]) + "..."
    }

    private func renderApproval() {
        guard let approval = model.activeApproval else {
            approvalContainer.isHidden = true
            return
        }
        approvalContainer.isHidden = false
        approvalTitleLabel.stringValue = "Approval · Risk \(approval.riskLevel) · \(approval.proposedAction)"
        let preview = approval.preview.isEmpty ? approval.description : approval.preview
        approvalPreviewLabel.stringValue = preview
    }

    private func renderSettings() {
        guard currentView == .settings else { return }
        isRenderingSettings = true
        defer { isRenderingSettings = false }
        let settings = model.settings
        if !sttLanguageField.currentEditorExists {
            sttLanguageField.stringValue = settings.sttLanguage
        }
        if !ttsProviderField.currentEditorExists {
            ttsProviderField.stringValue = settings.ttsProvider
        }
        selectTTSVoice(settings.ttsVoice)
        selectIslandAvatarStyle(pendingIslandAvatarStyle ?? settings.islandAvatarStyle)
        if !islandScreenField.currentEditorExists {
            islandScreenField.stringValue = settings.islandScreen
        }
        if !islandHotkeyField.currentEditorExists {
            islandHotkeyField.stringValue = settings.islandHotkey
        }
        islandHotkeyRecorder.hotKeyValue = settings.islandHotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ctrl+option+space"
            : settings.islandHotkey
        if !islandIdleCloseField.currentEditorExists {
            islandIdleCloseField.stringValue = settings.islandIdleCloseSeconds
        }
        streamTTSButton.state = settings.ttsStreaming ? .on : .off
        settingsStatusLabel.stringValue = model.settingsStatus
    }

    private func renderExecutors() {
        guard currentView == .executors else { return }
        executorSummaryLabel.stringValue = executorSummaryText()
        executorDetailLabel.stringValue = executorDetailText()
        executorListStack.arrangedSubviews.forEach { view in
            executorListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let executors = model.executorsSnapshot.executors.filter { !$0.fallbackValue }
        if executors.isEmpty {
            executorListStack.addArrangedSubview(settingsInfoRow(symbol: "puzzlepiece.extension", title: "Installed", primary: executorSummaryLabel, secondary: executorDetailLabel))
            return
        }
        for (index, descriptor) in executors.enumerated() {
            if index > 0 {
                executorListStack.addArrangedSubview(makeSeparator())
            }
            executorListStack.addArrangedSubview(executorRow(descriptor))
        }
    }

    private func executorRow(_ descriptor: ExecutorDescriptor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        row.addArrangedSubview(makeRoundIcon(executorSymbol(descriptor.adapter)))

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let title = NSTextField(labelWithString: executorDisplayName(descriptor))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let meta = NSTextField(labelWithString: executorMetaText(descriptor))
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingMiddle
        text.addArrangedSubview(title)
        text.addArrangedSubview(meta)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(text)

        row.addArrangedSubview(NSView())
        row.addArrangedSubview(makeSmallBadge(descriptor.adapter.uppercased()))

        let status = NSTextField(labelWithString: descriptor.healthy ? "Ready" : "Needs setup")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = descriptor.healthy ? .systemGreen : .systemOrange
        status.alignment = .right
        status.widthAnchor.constraint(equalToConstant: 84).isActive = true
        row.addArrangedSubview(status)
        return row
    }

    private func executorDisplayName(_ descriptor: ExecutorDescriptor) -> String {
        let name = descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? descriptor.id : name
    }

    private func executorMetaText(_ descriptor: ExecutorDescriptor) -> String {
        let kinds = (descriptor.kinds ?? []).joined(separator: ", ")
        let publisher = (descriptor.publisher ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (descriptor.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (descriptor.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let health = firstNonEmptyText(descriptor.healthMessage, descriptor.healthStatus)
        return [
            kinds.isEmpty ? nil : "kinds: \(kinds)",
            publisher.isEmpty ? nil : publisher,
            version.isEmpty ? nil : "v\(version)",
            source.isEmpty ? nil : "source: \(source)",
            health.isEmpty ? nil : health
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func executorSymbol(_ adapter: String) -> String {
        switch adapter.lowercased() {
        case "codex":
            return "terminal"
        case "acp":
            return "point.3.connected.trianglepath.dotted"
        case "command":
            return "chevron.left.forwardslash.chevron.right"
        case "mcp":
            return "point.3.connected.trianglepath.dotted"
        default:
            return "puzzlepiece.extension"
        }
    }

    private func executorSummaryText() -> String {
        let visible = model.executorsSnapshot.executors.filter { $0.enabled && !$0.fallbackValue }
        if visible.isEmpty {
            return model.executorsStatus == "Executors not loaded" ? "Not loaded" : "No executor configured"
        }
        let healthy = visible.filter { $0.healthy }.count
        let names = visible.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.id : $0.name }
        let status = healthy == visible.count ? "Ready" : "\(healthy)/\(visible.count) ready"
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")
            + " · " + status
    }

    private func executorDetailText() -> String {
        if let warning = model.executorsSnapshot.warnings?.first, !warning.isEmpty {
            return warning
        }
        if let unhealthy = model.executorsSnapshot.executors.first(where: { $0.enabled && !$0.fallbackValue && !$0.healthy }) {
            return firstNonEmptyText(unhealthy.healthMessage, unhealthy.healthStatus)
        }
        if let dir = model.executorsSnapshot.configDirs.first {
            return dir
        }
        return model.executorsStatus
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

    private func selectedTTSVoice() -> String {
        selectedPopUpValue(ttsVoicePopUp, fallback: "marin")
    }

    private func selectTTSVoice(_ value: String) {
        selectPopUp(ttsVoicePopUp, value: value, fallback: "marin")
    }

    private func selectedIslandAvatarStyle() -> String {
        selectedPopUpValue(islandAvatarPopUp, fallback: "default")
    }

    private func selectIslandAvatarStyle(_ value: String) {
        selectPopUp(islandAvatarPopUp, value: value, fallback: "default")
    }

    private func selectedPopUpValue(_ popUp: NSPopUpButton, fallback: String) -> String {
        if let value = popUp.selectedItem?.representedObject as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return fallback
    }

    private func selectPopUp(_ popUp: NSPopUpButton, value: String, fallback: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = normalized.isEmpty ? fallback : normalized
        for item in popUp.itemArray {
            if (item.representedObject as? String)?.lowercased() == target {
                popUp.select(item)
                return
            }
        }
        if let fallbackItem = popUp.itemArray.first(where: { ($0.representedObject as? String)?.lowercased() == fallback.lowercased() }) {
            popUp.select(fallbackItem)
        }
    }

    private func renderSubscription() {
        guard currentView == .subscription else { return }
    }
}

private extension NSTextField {
    var currentEditorExists: Bool {
        window?.firstResponder === currentEditor()
    }
}

private extension ExecutorDescriptor {
    var fallbackValue: Bool {
        fallback ?? false
    }
}

final class ClickableStackView: NSStackView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
final class CrowAppDelegate: NSObject, NSApplicationDelegate {
    private let model = CrowAppModel()
    private var windowController: CrowWindowController?
    private var islandController: CrowIslandController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrowMacLog("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        CrowMacLog("install status item")
        installStatusItem()
        CrowMacLog("create window controller")
        windowController = CrowWindowController(model: model)
        CrowMacLog("create island controller")
        islandController = CrowIslandController()
        CrowMacLog("configure island controller")
        islandController?.stateProvider = { [weak model] in
            model?.currentIslandState()
        }
        islandController?.approvalHandler = { [weak model] _, approved in
            model?.decideActiveApproval(approved: approved)
        }
        islandController?.voiceCommandHandler = { [weak model] text in
            model?.createTask(command: text, mode: "agent")
        }
        CrowMacLog("island applicationDidFinishLaunching")
        islandController?.applicationDidFinishLaunching(notification)
        CrowMacLog("show window")
        showWindow()
        CrowMacLog("model start")
        model.start()
        CrowMacLog("cloud activation skipped at startup")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◈ Crow"
        item.button?.toolTip = "Crow"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Crow", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Run Agent Smoke", action: #selector(runAgentSmoke), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Crow", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func showWindow() {
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        windowController?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refresh() {
        Swift.Task { await model.refresh() }
    }

    @objc private func runAgentSmoke() {
        showWindow()
        model.createTask(command: "用一句话回答：8+9 等于几", mode: "agent")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = CrowAppDelegate()
app.delegate = delegate
app.run()
