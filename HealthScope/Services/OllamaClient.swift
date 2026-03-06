import Foundation

enum OllamaError: LocalizedError {
    case invalidBaseURL
    case httpStatus(Int, String)
    case connectionRefused
    case offline
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid Ollama base URL."
        case .httpStatus(let code, let body):
            if body.isEmpty { return "Ollama request failed with HTTP \(code)." }
            return "Ollama request failed with HTTP \(code): \(body)"
        case .connectionRefused:
            return "Connection refused. Verify Ollama is running and reachable from your iPhone."
        case .offline:
            return "No network connection. Connect your iPhone to the same network as Ollama."
        case .requestFailed(let message):
            return message
        }
    }
}

actor OllamaClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateReply(
        messages: [ChatMessage],
        systemPrompt: String,
        settings: ChatAISettings,
        onToken: @escaping (String) async -> Void
    ) async throws -> String {
        guard let baseURL = settings.normalizedOllamaBaseURL else {
            throw OllamaError.invalidBaseURL
        }

        do {
            return try await callChatEndpoint(
                baseURL: baseURL,
                model: settings.ollamaModel,
                stream: settings.effectiveStreamResponses,
                timeoutSeconds: settings.timeoutSeconds,
                systemPrompt: systemPrompt,
                messages: messages,
                onToken: onToken,
                maxTokens: settings.effectiveMaxTokens,
                maxResponseChars: settings.effectiveMaxResponseChars,
                callbackChunkSize: settings.effectiveCallbackChunkSize
            )
        } catch OllamaError.httpStatus(let code, _) where code == 404 {
            return try await callGenerateEndpoint(
                baseURL: baseURL,
                model: settings.ollamaModel,
                stream: settings.effectiveStreamResponses,
                timeoutSeconds: settings.timeoutSeconds,
                systemPrompt: systemPrompt,
                messages: messages,
                onToken: onToken,
                maxTokens: settings.effectiveMaxTokens,
                maxResponseChars: settings.effectiveMaxResponseChars,
                callbackChunkSize: settings.effectiveCallbackChunkSize
            )
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    private func callChatEndpoint(
        baseURL: URL,
        model: String,
        stream: Bool,
        timeoutSeconds: Double,
        systemPrompt: String,
        messages: [ChatMessage],
        onToken: @escaping (String) async -> Void,
        maxTokens: Int,
        maxResponseChars: Int,
        callbackChunkSize: Int
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ChatRequest(
            model: model,
            stream: stream,
            options: ["num_predict": maxTokens],
            messages: [ChatRequestMessage(role: "system", content: systemPrompt)] + messages.map {
                ChatRequestMessage(role: $0.role.rawValue, content: $0.content)
            }
        )
        request.httpBody = try JSONEncoder().encode(payload)

        if stream {
            return try await streamChat(
                request: request,
                onToken: onToken,
                maxResponseChars: maxResponseChars,
                callbackChunkSize: callbackChunkSize
            )
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return String(decoded.message.content.prefix(maxResponseChars))
    }

    private func callGenerateEndpoint(
        baseURL: URL,
        model: String,
        stream: Bool,
        timeoutSeconds: Double,
        systemPrompt: String,
        messages: [ChatMessage],
        onToken: @escaping (String) async -> Void,
        maxTokens: Int,
        maxResponseChars: Int,
        callbackChunkSize: Int
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GenerateRequest(
            model: model,
            prompt: makePrompt(systemPrompt: systemPrompt, messages: messages),
            stream: stream,
            options: ["num_predict": maxTokens]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        if stream {
            return try await streamGenerate(
                request: request,
                onToken: onToken,
                maxResponseChars: maxResponseChars,
                callbackChunkSize: callbackChunkSize
            )
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        return String(decoded.response.prefix(maxResponseChars))
    }

    func warmUpModel(settings: ChatAISettings) async throws {
        guard let baseURL = settings.normalizedOllamaBaseURL else {
            throw OllamaError.invalidBaseURL
        }

        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GenerateRequest(
            model: settings.ollamaModel,
            prompt: "Reply with OK.",
            stream: false,
            options: ["num_predict": 32]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    private func streamChat(
        request: URLRequest,
        onToken: @escaping (String) async -> Void,
        maxResponseChars: Int,
        callbackChunkSize: Int
    ) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.requestFailed("Invalid response from Ollama server.")
        }
        if !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw OllamaError.httpStatus(http.statusCode, body)
        }

        var fullResponse = ""
        var buffered = ""
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(ChatStreamChunk.self, from: data)
            if let error = chunk.error, !error.isEmpty {
                throw OllamaError.requestFailed(error)
            }
            let token = chunk.message?.content ?? ""
            if !token.isEmpty {
                fullResponse += token
                if fullResponse.count >= maxResponseChars {
                    let clipped = String(fullResponse.prefix(maxResponseChars))
                    if !buffered.isEmpty {
                        await onToken(buffered)
                    }
                    return clipped
                }
                buffered += token
                if buffered.count >= callbackChunkSize {
                    await onToken(buffered)
                    buffered = ""
                }
            }
        }
        if !buffered.isEmpty {
            await onToken(buffered)
        }
        return fullResponse
    }

    private func streamGenerate(
        request: URLRequest,
        onToken: @escaping (String) async -> Void,
        maxResponseChars: Int,
        callbackChunkSize: Int
    ) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.requestFailed("Invalid response from Ollama server.")
        }
        if !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw OllamaError.httpStatus(http.statusCode, body)
        }

        var fullResponse = ""
        var buffered = ""
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(GenerateStreamChunk.self, from: data)
            if let error = chunk.error, !error.isEmpty {
                throw OllamaError.requestFailed(error)
            }
            let token = chunk.response ?? ""
            if !token.isEmpty {
                fullResponse += token
                if fullResponse.count >= maxResponseChars {
                    let clipped = String(fullResponse.prefix(maxResponseChars))
                    if !buffered.isEmpty {
                        await onToken(buffered)
                    }
                    return clipped
                }
                buffered += token
                if buffered.count >= callbackChunkSize {
                    await onToken(buffered)
                    buffered = ""
                }
            }
        }
        if !buffered.isEmpty {
            await onToken(buffered)
        }
        return fullResponse
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.requestFailed("Invalid response from Ollama server.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
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

    private func makePrompt(systemPrompt: String, messages: [ChatMessage]) -> String {
        var lines: [String] = ["SYSTEM:", systemPrompt, ""]
        for message in messages {
            lines.append("\(message.role.rawValue.uppercased()):")
            lines.append(message.content)
            lines.append("")
        }
        lines.append("ASSISTANT:")
        return lines.joined(separator: "\n")
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let stream: Bool
    let options: [String: Int]?
    let messages: [ChatRequestMessage]
}

private struct ChatRequestMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let message: ChatResponseMessage
}

private struct ChatResponseMessage: Decodable {
    let content: String
}

private struct ChatStreamChunk: Decodable {
    let message: ChatResponseMessage?
    let done: Bool?
    let error: String?
}

private struct GenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let options: [String: Int]?
}

private struct GenerateResponse: Decodable {
    let response: String
}

private struct GenerateStreamChunk: Decodable {
    let response: String?
    let done: Bool?
    let error: String?
}
