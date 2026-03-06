import Foundation

enum XAIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpStatus(Int, String)
    case offline
    case connectionRefused
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing xAI API key. Add it in Analysis Settings."
        case .invalidResponse:
            return "Invalid response from xAI API."
        case .httpStatus(let code, let body):
            if body.isEmpty { return "xAI request failed with HTTP \(code)." }
            return "xAI request failed with HTTP \(code): \(body)"
        case .offline:
            return "No network connection."
        case .connectionRefused:
            return "Unable to reach xAI API."
        case .requestFailed(let message):
            return message
        }
    }
}

actor XAIClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateReply(
        messages: [ChatMessage],
        systemPrompt: String,
        settings: ChatAISettings,
        onToken: @escaping (String) async -> Void
    ) async throws -> String {
        let key = settings.xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw XAIError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let payload = XAIChatRequest(
            model: settings.selectedModel,
            messages: [XAIChatMessage(role: "system", content: systemPrompt)] + messages.map {
                XAIChatMessage(role: $0.role.rawValue, content: $0.content)
            },
            stream: settings.effectiveStreamResponses,
            maxTokens: settings.effectiveMaxTokens
        )
        request.httpBody = try JSONEncoder().encode(payload)

        if settings.effectiveStreamResponses {
            return try await streamResponse(
                request: request,
                onToken: onToken,
                maxResponseChars: settings.effectiveMaxResponseChars,
                callbackChunkSize: settings.effectiveCallbackChunkSize
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(XAIChatResponse.self, from: data)
            return String((decoded.choices.first?.message.content ?? "").prefix(settings.effectiveMaxResponseChars))
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    func warmUpModel(settings: ChatAISettings) async throws {
        let key = settings.xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw XAIError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let payload = XAIChatRequest(
            model: settings.selectedModel,
            messages: [
                XAIChatMessage(role: "system", content: "Respond with OK."),
                XAIChatMessage(role: "user", content: "ping")
            ],
            stream: false,
            maxTokens: 16
        )
        request.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    private func streamResponse(
        request: URLRequest,
        onToken: @escaping (String) async -> Void,
        maxResponseChars: Int,
        callbackChunkSize: Int
    ) async throws -> String {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw XAIError.invalidResponse
            }
            if !(200...299).contains(http.statusCode) {
                var body = ""
                for try await line in bytes.lines {
                    body += line
                }
                throw XAIError.httpStatus(http.statusCode, body)
            }

            var full = ""
            var buffered = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8) else { continue }

                if let chunk = try? JSONDecoder().decode(XAIStreamChunk.self, from: data),
                   let delta = chunk.choices.first?.delta.content,
                   !delta.isEmpty {
                    full += delta
                    let clipped = String(full.prefix(maxResponseChars))
                    buffered += delta
                    if buffered.count >= callbackChunkSize {
                        await onToken(buffered)
                        buffered = ""
                    }
                    if clipped.count >= maxResponseChars {
                        if !buffered.isEmpty {
                            await onToken(buffered)
                        }
                        return clipped
                    }
                }
            }

            if !buffered.isEmpty {
                await onToken(buffered)
            }
            return String(full.prefix(maxResponseChars))
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw XAIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw XAIError.httpStatus(http.statusCode, body)
        }
    }

    private func mapURLError(_ error: URLError) -> XAIError {
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

private struct XAIChatRequest: Encodable {
    let model: String
    let messages: [XAIChatMessage]
    let stream: Bool
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case maxTokens = "max_tokens"
    }
}

private struct XAIChatMessage: Encodable {
    let role: String
    let content: String
}

private struct XAIChatResponse: Decodable {
    let choices: [XAIChoice]
}

private struct XAIChoice: Decodable {
    let message: XAIMessage
}

private struct XAIMessage: Decodable {
    let content: String
}

private struct XAIStreamChunk: Decodable {
    let choices: [XAIStreamChoice]
}

private struct XAIStreamChoice: Decodable {
    let delta: XAIDelta
}

private struct XAIDelta: Decodable {
    let content: String?
}
