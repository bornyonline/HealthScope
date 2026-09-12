import Foundation
import Network

nonisolated enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

nonisolated struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date
    let containsClinicalContext: Bool

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = Date(),
        containsClinicalContext: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.containsClinicalContext = containsClinicalContext
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, containsClinicalContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        containsClinicalContext = try container.decodeIfPresent(Bool.self, forKey: .containsClinicalContext) ?? false
    }
}

nonisolated enum AIProviderOption: String, CaseIterable, Identifiable, Sendable {
    case ollamaLocal
    case unslothLAN

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollamaLocal:
            return "Local Ollama"
        case .unslothLAN:
            return "Unsloth LAN (OpenAI-compatible)"
        }
    }
}

nonisolated enum HealthDataSharingPreference: Int, Sendable {
    case ask = -1
    case disabled = 0
    case enabled = 1
}

nonisolated struct ChatAISettings: Sendable {
    let provider: AIProviderOption
    let ollamaBaseURLString: String
    let ollamaModel: String
    let unslothBaseURLString: String
    let unslothModel: String
    let unslothAPIKey: String
    let streamResponses: Bool
    let deviceSafeMode: Bool
    let timeoutSeconds: Double

    func validatedBaseURL(for provider: AIProviderOption) throws -> URL {
        let rawValue = provider == .ollamaLocal ? ollamaBaseURLString : unslothBaseURLString
        let providerName = provider == .ollamaLocal ? "Ollama" : "Unsloth"
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              components.path.isEmpty || components.path == "/" else {
            throw AIConfigurationError.invalidBaseURL(providerName)
        }

        components.scheme = scheme
        components.path = ""
        if scheme == "http", !AIEndpointPolicy.isLocalHost(host) {
            throw AIConfigurationError.insecureHTTP(providerName)
        }
        guard let url = components.url else {
            throw AIConfigurationError.invalidBaseURL(providerName)
        }
        return url
    }

    var selectedModel: String {
        provider == .ollamaLocal ? ollamaModel : unslothModel
    }

    func validate() throws {
        _ = try validatedBaseURL(for: provider)

        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+/:@")
        guard !model.isEmpty,
              model.count <= 200,
              model.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AIConfigurationError.invalidModel
        }

        guard timeoutSeconds.isFinite, (5...600).contains(timeoutSeconds) else {
            throw AIConfigurationError.invalidTimeout
        }

        if provider == .unslothLAN,
           (unslothAPIKey.count > 4_096 || unslothAPIKey.rangeOfCharacter(from: .newlines) != nil) {
            throw AIConfigurationError.invalidAPIKey
        }
    }

    var effectiveStreamResponses: Bool {
        streamResponses
    }

    var effectiveCallbackChunkSize: Int {
        deviceSafeMode ? 320 : 160
    }
}

nonisolated enum AIEndpointPolicy {
    static func isLocalHost(_ host: String) -> Bool {
        var normalized = host
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") {
            return true
        }

        if let address = IPv4Address(normalized) {
            let octets = [UInt8](address.rawValue)
            return octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }

        let ipv6 = normalized.split(separator: "%", maxSplits: 1).first.map(String.init) ?? normalized
        guard let address = IPv6Address(ipv6) else { return false }
        let bytes = [UInt8](address.rawValue)
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isUniqueLocal = bytes[0] & 0xfe == 0xfc
        let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        return isLoopback || isUniqueLocal || isLinkLocal
    }

    static func allowsRedirect(from originalURL: URL?, to redirectedURL: URL?) -> Bool {
        guard let originalURL,
              let redirectedURL,
              let original = origin(of: originalURL),
              let redirected = origin(of: redirectedURL) else {
            return false
        }
        return original == redirected
    }

    private static func origin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

nonisolated final class AISameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AISameOriginRedirectDelegate()

    private override init() {}

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let permitted = AIEndpointPolicy.allowsRedirect(
            from: task.originalRequest?.url,
            to: request.url
        )
        completionHandler(permitted ? request : nil)
    }
}

nonisolated enum AIStreamingEvent: Sendable {
    case textDelta(String)
    case completed
}

typealias AIEventStream = AsyncThrowingStream<AIStreamingEvent, Error>

nonisolated enum AIConfigurationError: LocalizedError {
    case invalidBaseURL(String)
    case invalidModel
    case invalidTimeout
    case invalidAPIKey
    case insecureHTTP(String)
    case incompleteStream(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let provider):
            return "Enter a valid \(provider) base URL with an explicit http:// or https:// scheme and no path, query, credentials, or fragment."
        case .invalidModel:
            return "Enter a model ID using only letters, numbers, '.', '_', '-', '+', '/', ':', or '@'."
        case .invalidTimeout:
            return "Timeout must be between 5 and 600 seconds."
        case .invalidAPIKey:
            return "The API key must be at most 4,096 characters and cannot contain line breaks."
        case .insecureHTTP(let provider):
            return "Plaintext HTTP for \(provider) is limited to loopback, private-network, link-local, and .local hosts. Use HTTPS for other endpoints."
        case .incompleteStream(let provider):
            return "\(provider) disconnected before confirming that the response was complete."
        }
    }
}
