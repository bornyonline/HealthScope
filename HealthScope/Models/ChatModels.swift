import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatRole
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

enum AIProviderOption: String, CaseIterable, Identifiable {
    case ollamaLocal
    case xaiReasoning
    case xaiNonReasoning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollamaLocal:
            return "Local Ollama"
        case .xaiReasoning:
            return "xAI Grok 4.1 Fast Reasoning"
        case .xaiNonReasoning:
            return "xAI Grok 4.1 Fast Non-Reasoning"
        }
    }

    var modelName: String {
        switch self {
        case .ollamaLocal:
            return ""
        case .xaiReasoning:
            return "grok-4-1-fast-reasoning"
        case .xaiNonReasoning:
            return "grok-4-1-fast-non-reasoning"
        }
    }
}

struct ChatAISettings {
    let provider: AIProviderOption
    let baseURLString: String
    let ollamaModel: String
    let xaiAPIKey: String
    let streamResponses: Bool
    let deviceSafeMode: Bool
    let timeoutSeconds: Double

    var normalizedOllamaBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "http://\(trimmed)")
    }

    var selectedModel: String {
        switch provider {
        case .ollamaLocal:
            return ollamaModel
        case .xaiReasoning, .xaiNonReasoning:
            return provider.modelName
        }
    }

    var effectiveStreamResponses: Bool {
        streamResponses && !deviceSafeMode
    }

    var effectiveMaxTokens: Int {
        deviceSafeMode ? 160 : 320
    }

    var effectiveMaxResponseChars: Int {
        deviceSafeMode ? 2200 : 6000
    }

    var effectiveCallbackChunkSize: Int {
        deviceSafeMode ? 320 : 160
    }
}
