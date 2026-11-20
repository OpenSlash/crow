import Foundation

/// Where conversation requests go. `local` (default) uses the crowd daemon with the
/// user's own API key; `cloud` uses a Crow Cloud server. Both speak the same protocol.
enum CrowAgentMode: String {
    case local
    case cloud

    static var configured: CrowAgentMode {
        let raw = (CrowEnvironment.value("CROW_AGENT_MODE") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return CrowAgentMode(rawValue: raw) ?? .local
    }
}

struct CrowAgentResponse: Decodable {
    let text: String
    let model: String
    let provider: String
    let needExecutor: Bool
    let executorHint: String?
    /// Self-contained instruction for the executor, written by the model.
    let executorTask: String?

    enum CodingKeys: String, CodingKey {
        case text
        case model
        case provider
        case needExecutor = "need_executor"
        case executorHint = "executor_hint"
        case executorTask = "executor_task"
    }
}

/// What Crow is doing during a turn, e.g. kind "thinking" / label "Thinking".
struct CrowAgentActivity: Decodable {
    let kind: String
    let label: String
}

enum CrowAgent {
    typealias Completion = @Sendable (Result<CrowAgentResponse, Error>) -> Void

    static func respond(input: String, completion: @escaping Completion) {
        let endpoint: Endpoint
        do {
            endpoint = try Endpoint.resolve(path: "/v1/agent/respond")
        } catch {
            completion(.failure(error))
            return
        }

        var request = endpoint.request
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "input": input,
            "mode": "voice",
            "max_tokens": 220
        ])
        CrowMacLog("agent request mode=\(endpoint.mode.rawValue) url=\(endpoint.url.absoluteString) chars=\(input.count)")

        URLSession(configuration: endpoint.sessionConfiguration).dataTask(with: request) { data, response, error in
            if let error {
                CrowMacLog("agent request error \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(status) else {
                let message = CrowOpenAIHTTP.errorMessage(from: data) ?? "Crow agent failed with status \(status)"
                CrowMacLog("agent request failed status=\(status) bytes=\(data?.count ?? 0)")
                completion(.failure(agentError(code: status, message)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(CrowAgentResponse.self, from: data)
                CrowMacLog("agent request ok provider=\(decoded.provider) model=\(decoded.model) needExecutor=\(decoded.needExecutor)")
                completion(.success(decoded))
            } catch {
                CrowMacLog("agent decode error \(error.localizedDescription)")
                completion(.failure(error))
            }
        }.resume()
    }

    /// Streams a turn. Cancelling the returned handle stops the turn on the server
    /// (pending tool steps are skipped) and suppresses the completion.
    @discardableResult
    static func respondStream(
        input: String,
        onDelta: @escaping @Sendable (String) -> Void,
        onActivity: @escaping @Sendable (CrowAgentActivity) -> Void = { _ in },
        completion: @escaping Completion
    ) -> CrowAgentStream {
        let endpoint: Endpoint
        do {
            endpoint = try Endpoint.resolve(path: "/v1/agent/respond-stream")
        } catch {
            completion(.failure(error))
            return CrowAgentStream(delegate: nil)
        }

        var request = endpoint.request
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "input": input,
            "mode": "voice",
            "max_tokens": 220,
            "stream": true
        ])
        CrowMacLog("agent stream request mode=\(endpoint.mode.rawValue) url=\(endpoint.url.absoluteString) chars=\(input.count)")

        let delegate = StreamDelegate(onDelta: onDelta, onActivity: onActivity, completion: completion)
        let session = URLSession(configuration: endpoint.sessionConfiguration, delegate: delegate, delegateQueue: nil)
        delegate.attach(session: session)
        session.dataTask(with: request).resume()
        return CrowAgentStream(delegate: delegate)
    }

    fileprivate static func agentError(code: Int, _ message: String) -> NSError {
        NSError(domain: "CrowAgent", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private struct Endpoint {
        let mode: CrowAgentMode
        let url: URL
        let request: URLRequest
        let sessionConfiguration: URLSessionConfiguration

        static func resolve(path: String) throws -> Endpoint {
            let mode = CrowAgentMode.configured
            switch mode {
            case .cloud:
                guard let url = CrowCloudHTTP.url(path: path) else {
                    throw agentError(code: 1, "Invalid Crow Cloud URL")
                }
                return Endpoint(
                    mode: mode,
                    url: url,
                    request: CrowCloudHTTP.request(url: url),
                    sessionConfiguration: CrowProxySettings.urlSessionConfiguration()
                )
            case .local:
                guard let session = readDaemonSession() else {
                    throw agentError(code: 2, "Crow daemon is not running")
                }
                guard let url = URL(string: session.baseURL + path) else {
                    throw agentError(code: 1, "Invalid Crow daemon URL")
                }
                var request = URLRequest(url: url)
                request.setValue(session.token, forHTTPHeaderField: "x-crow-session-token")
                // Loopback traffic must bypass any configured proxy.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = [:]
                configuration.timeoutIntervalForRequest = 120
                return Endpoint(mode: mode, url: url, request: request, sessionConfiguration: configuration)
            }
        }

        private static func readDaemonSession() -> CrowSession? {
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Crow/runtime/session.json")
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? JSONDecoder().decode(CrowSession.self, from: data)
        }
    }
}

final class CrowAgentStream: @unchecked Sendable {
    private let delegate: StreamDelegate?

    fileprivate init(delegate: StreamDelegate?) {
        self.delegate = delegate
    }

    func cancel() {
        delegate?.cancel()
    }
}

/// Parses the SSE stream: `delta` {text}, `activity` {kind, label}, `done` CrowAgentResponse, `error` {code, message}.
private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onDelta: @Sendable (String) -> Void
    private let onActivity: @Sendable (CrowAgentActivity) -> Void
    private let completion: CrowAgent.Completion
    private var buffer = ""
    private var finished = false
    private let lock = NSLock()
    private var session: URLSession?

    init(
        onDelta: @escaping @Sendable (String) -> Void,
        onActivity: @escaping @Sendable (CrowAgentActivity) -> Void,
        completion: @escaping CrowAgent.Completion
    ) {
        self.onDelta = onDelta
        self.onActivity = onActivity
        self.completion = completion
    }

    func attach(session: URLSession) {
        self.session = session
    }

    /// Closing the connection cancels the request context in the daemon.
    func cancel() {
        lock.lock()
        finished = true
        lock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            finish(.failure(CrowAgent.agentError(code: status, "Crow agent stream failed with status \(status)")))
            completionHandler(.cancel)
            session.invalidateAndCancel()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return
        }
        buffer.append(chunk.replacingOccurrences(of: "\r\n", with: "\n"))
        drainBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        drainBuffer(force: true)
        defer { session.invalidateAndCancel() }
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(CrowAgent.agentError(code: -1, "Crow agent stream ended without a final response")))
        }
    }

    private func finish(_ result: Result<CrowAgentResponse, Error>) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        completion(result)
    }

    private func drainBuffer(force: Bool = false) {
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            consume(block: block)
        }
        if force, !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consume(block: buffer)
            buffer.removeAll()
        }
    }

    private func consume(block: String) {
        lock.lock()
        let isFinished = finished
        lock.unlock()
        guard !isFinished else { return }
        var event = "message"
        var dataLines: [String] = []
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("event:") {
                event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        guard let data = dataLines.joined(separator: "\n").data(using: .utf8) else {
            return
        }

        switch event {
        case "delta":
            if let decoded = try? JSONDecoder().decode(DeltaPayload.self, from: data), !decoded.text.isEmpty {
                onDelta(decoded.text)
            }
        case "activity":
            if let decoded = try? JSONDecoder().decode(CrowAgentActivity.self, from: data) {
                onActivity(decoded)
            }
        case "done":
            do {
                finish(.success(try JSONDecoder().decode(CrowAgentResponse.self, from: data)))
            } catch {
                finish(.failure(error))
            }
        case "error":
            let decoded = try? JSONDecoder().decode(ErrorPayload.self, from: data)
            finish(.failure(CrowAgent.agentError(code: -2, decoded?.message ?? "Crow agent stream failed")))
        default:
            break
        }
    }

    private struct DeltaPayload: Decodable {
        let text: String
    }

    private struct ErrorPayload: Decodable {
        let message: String
    }
}
