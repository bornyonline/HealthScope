import Foundation

nonisolated enum UnslothError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case offline
    case connectionRefused
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from the Unsloth service."
        case .httpStatus(let code, let body):
            if body.isEmpty { return "Unsloth request failed with HTTP \(code)." }
            return "Unsloth request failed with HTTP \(code): \(body)"
        case .offline:
            return "No network connection. Connect to the Unsloth server's network."
        case .connectionRefused:
            return "Unable to reach the Unsloth service. Verify its LAN address and port."
        case .requestFailed(let message):
            return message
        }
    }
}

actor UnslothClient {
    private let session: URLSession
    private let maximumErrorCharacters = 16_384
    private let maximumStreamLineBytes = 1_048_576

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
                        messages: [UnslothChatMessage(role: "system", content: systemPrompt)] + messages.map {
                            UnslothChatMessage(role: $0.role.rawValue, content: $0.content)
                        },
                        settings: settings,
                        maxTokens: nil
                    )
                    try await self.consumeSSE(request: request) { continuation.yield($0) }
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
        let request = try makeRequest(
            messages: [UnslothChatMessage(role: "user", content: "Reply with OK.")],
            settings: settings,
            maxTokens: 16
        )
        do {
            try await consumeSSE(request: request) { _ in }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    private func makeRequest(
        messages: [UnslothChatMessage],
        settings: ChatAISettings,
        maxTokens: Int?
    ) throws -> URLRequest {
        try settings.validate()
        let baseURL = try settings.validatedBaseURL(for: .unslothLAN)
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let key = settings.unslothAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(UnslothChatRequest(
            model: settings.unslothModel.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: messages,
            stream: true,
            maxTokens: maxTokens
        ))
        return request
    }

    private func consumeSSE(
        request: URLRequest,
        yield: @escaping @Sendable (AIStreamingEvent) -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UnslothError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            var body = ""
            try await BoundedLineStream.consume(bytes, maximumLineBytes: maximumStreamLineBytes) { line in
                let remaining = maximumErrorCharacters - body.count
                guard remaining > 0 else { return true }
                body += String(line.prefix(remaining))
                return body.count >= maximumErrorCharacters
            }
            throw UnslothError.httpStatus(http.statusCode, body)
        }

        var completed = false
        try await BoundedLineStream.consume(bytes, maximumLineBytes: maximumStreamLineBytes) { line in
            guard line.hasPrefix("data:") else { return false }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                yield(.completed)
                completed = true
                return true
            }
            guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return false }

            let chunk: UnslothStreamChunk
            do {
                chunk = try JSONDecoder().decode(UnslothStreamChunk.self, from: data)
            } catch {
                throw UnslothError.requestFailed("The Unsloth service sent malformed SSE data: \(error.localizedDescription)")
            }
            if let message = chunk.error?.message, !message.isEmpty {
                throw UnslothError.requestFailed(message)
            }
            for choice in chunk.choices ?? [] {
                if let delta = choice.delta.content, !delta.isEmpty {
                    yield(.textDelta(delta))
                }
            }
            return false
        }

        if !completed {
            throw AIConfigurationError.incompleteStream("Unsloth")
        }
    }

    private func mapURLError(_ error: URLError) -> UnslothError {
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

nonisolated private struct UnslothChatRequest: Encodable, Sendable {
    let model: String
    let messages: [UnslothChatMessage]
    let stream: Bool
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case maxTokens = "max_tokens"
    }
}

nonisolated private struct UnslothChatMessage: Encodable, Sendable {
    let role: String
    let content: String
}

nonisolated private struct UnslothStreamChunk: Decodable, Sendable {
    let choices: [UnslothStreamChoice]?
    let error: UnslothAPIError?
}

nonisolated private struct UnslothStreamChoice: Decodable, Sendable {
    let delta: UnslothDelta
}

nonisolated private struct UnslothDelta: Decodable, Sendable {
    let content: String?
}

nonisolated private struct UnslothAPIError: Decodable, Sendable {
    let message: String
}
