import Foundation

nonisolated enum OllamaError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case connectionRefused
    case offline
    case requestFailed(String)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from the Ollama server."
        case .httpStatus(let code, let body):
            if body.isEmpty { return "Ollama request failed with HTTP \(code)." }
            return "Ollama request failed with HTTP \(code): \(body)"
        case .connectionRefused:
            return "Connection refused. Verify Ollama is running and reachable from your iPhone."
        case .offline:
            return "No network connection. Connect your iPhone to the same network as Ollama."
        case .requestFailed(let message):
            return message
        case .responseTooLarge:
            return "The Ollama response was too large to process safely in non-streaming mode. Enable streaming and ask the model to continue."
        }
    }
}

actor OllamaClient {
    private let session: URLSession
    private let maximumErrorCharacters = 16_384
    private let maximumStreamLineBytes = 1_048_576
    private let maximumSingleResponseBytes = 1_048_576

    init(session: URLSession = .shared) {
        self.session = session
    }

    func replyEvents(
        messages: [ChatMessage],
        systemPrompt: String,
        settings: ChatAISettings
    ) -> AIEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.makeRequest(
                        messages: [OllamaChatRequestMessage(role: "system", content: systemPrompt)] + messages.map {
                            OllamaChatRequestMessage(role: $0.role.rawValue, content: $0.content)
                        },
                        settings: settings
                    )
                    if settings.effectiveStreamResponses {
                        try await self.consumeJSONLines(request: request) { continuation.yield($0) }
                    } else {
                        try await self.consumeSingleResponse(request: request) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError {
                    continuation.finish(throwing: self.mapURLError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func warmUpModel(settings: ChatAISettings) async throws {
        try settings.validate()
        let request = try makeRequest(
            messages: [OllamaChatRequestMessage(role: "user", content: "Reply with OK.")],
            settings: settings,
            stream: false,
            options: ["num_predict": 32]
        )
        do {
            try await consumeSingleResponse(request: request) { _ in }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    private func makeRequest(
        messages: [OllamaChatRequestMessage],
        settings: ChatAISettings,
        stream: Bool? = nil,
        options: [String: Int]? = nil
    ) throws -> URLRequest {
        try settings.validate()
        let baseURL = try settings.validatedBaseURL(for: .ollamaLocal)
        let endpoint = baseURL.appendingPathComponent("api").appendingPathComponent("chat")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaChatRequest(
            model: settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines),
            stream: stream ?? settings.effectiveStreamResponses,
            options: options,
            messages: messages
        ))
        return request
    }

    private func consumeJSONLines(
        request: URLRequest,
        yield: @escaping @Sendable (AIStreamingEvent) -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            var body = ""
            try await BoundedLineStream.consume(bytes, maximumLineBytes: maximumStreamLineBytes) { line in
                let remaining = maximumErrorCharacters - body.count
                guard remaining > 0 else { return true }
                body += String(line.prefix(remaining))
                return body.count >= maximumErrorCharacters
            }
            throw OllamaError.httpStatus(http.statusCode, body)
        }

        var completed = false
        try await BoundedLineStream.consume(bytes, maximumLineBytes: maximumStreamLineBytes) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
            let chunk: OllamaChatResponse
            do {
                chunk = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            } catch {
                throw OllamaError.requestFailed("Ollama sent malformed JSON-lines data: \(error.localizedDescription)")
            }
            if let error = chunk.error, !error.isEmpty {
                throw OllamaError.requestFailed(error)
            }
            if let delta = chunk.message?.content, !delta.isEmpty {
                yield(.textDelta(delta))
            }
            if chunk.done == true {
                yield(.completed)
                completed = true
                return true
            }
            return false
        }

        if !completed {
            throw AIConfigurationError.incompleteStream("Ollama")
        }
    }

    private func consumeSingleResponse(
        request: URLRequest,
        yield: @escaping @Sendable (AIStreamingEvent) -> Void
    ) async throws {
        let (fileURL, response) = try await session.download(for: request)
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= maximumSingleResponseBytes else {
            throw OllamaError.responseTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        if let error = decoded.error, !error.isEmpty {
            throw OllamaError.requestFailed(error)
        }
        guard decoded.done == true else {
            throw AIConfigurationError.incompleteStream("Ollama")
        }
        if let content = decoded.message?.content, !content.isEmpty {
            yield(.textDelta(content))
        }
        yield(.completed)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(maximumErrorCharacters), encoding: .utf8) ?? ""
            throw OllamaError.httpStatus(http.statusCode, body)
        }
    }

    private func mapURLError(_ error: URLError) -> OllamaError {
        switch error.code {
        case .notConnectedToInternet:
            return .offline
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return .connectionRefused
        default:
            return .requestFailed(error.localizedDescription)
        }
    }
}

nonisolated private struct OllamaChatRequest: Encodable, Sendable {
    let model: String
    let stream: Bool
    let options: [String: Int]?
    let messages: [OllamaChatRequestMessage]
}

nonisolated private struct OllamaChatRequestMessage: Encodable, Sendable {
    let role: String
    let content: String
}

nonisolated private struct OllamaChatResponse: Decodable, Sendable {
    let message: OllamaChatResponseMessage?
    let done: Bool?
    let error: String?
}

nonisolated private struct OllamaChatResponseMessage: Decodable, Sendable {
    let content: String
}
