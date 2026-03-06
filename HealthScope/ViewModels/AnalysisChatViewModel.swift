import Foundation
import Combine

@MainActor
final class AnalysisChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var isSending = false
    @Published var isWarmingUp = false
    @Published var warmupStatus: String?
    @Published var errorMessage: String?

    private let store: ConversationStore
    private let ollamaClient: OllamaClient
    private let xaiClient: XAIClient
    private var lastWarmupKey: String?
    private let maxStoredMessages = 16
    private let modelContextMessages = 4
    private let maxCharsPerContextMessage = 300
    private var activeRenderCharLimit = 2200
    private let maxHealthSummaryChars = 2000
    private var pendingTokenBuffers: [UUID: String] = [:]
    private var flushTasks: [UUID: Task<Void, Never>] = [:]

    private let systemPrompt = """
You are a health data analyst assistant inside a personal health tracking app. Your name Louise.
Provide non-medical, educational guidance based on user-provided trends.
Do not diagnose diseases or provide emergency/critical medical instructions.
Use cautious language, include uncertainty when data is limited, and encourage consulting a qualified clinician for medical decisions.
Focus on practical lifestyle suggestions (sleep routine, activity consistency, hydration, stress management, adherence to clinician plans).
"""

    init(store: ConversationStore, ollamaClient: OllamaClient, xaiClient: XAIClient) {
        self.store = store
        self.ollamaClient = ollamaClient
        self.xaiClient = xaiClient
        self.messages = sanitizeLoadedMessages(store.load())
    }

    convenience init() {
        self.init(store: ConversationStore(), ollamaClient: OllamaClient(), xaiClient: XAIClient())
    }

    func send(userText: String, healthSummary: String, settings: ChatAISettings) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isSending else { return }

        errorMessage = nil
        isSending = true
        activeRenderCharLimit = settings.effectiveMaxResponseChars

        let userMessage = ChatMessage(role: .user, content: trimmed)
        messages.append(userMessage)
        trimStoredMessagesIfNeeded()

        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        saveMessages()

        do {
            let fullResponse: String
            switch settings.provider {
            case .ollamaLocal:
                fullResponse = try await ollamaClient.generateReply(
                    messages: modelInputMessages(),
                    systemPrompt: effectiveSystemPrompt(healthSummary: healthSummary),
                    settings: settings,
                    onToken: { [weak self] token in
                        guard let self else { return }
                        await self.handleStreamToken(token, for: assistantID)
                    }
                )
            case .xaiReasoning, .xaiNonReasoning:
                fullResponse = try await xaiClient.generateReply(
                    messages: modelInputMessages(),
                    systemPrompt: effectiveSystemPrompt(healthSummary: healthSummary),
                    settings: settings,
                    onToken: { [weak self] token in
                        guard let self else { return }
                        await self.handleStreamToken(token, for: assistantID)
                    }
                )
            }

            flushBufferedTokens(for: assistantID)

            if !settings.effectiveStreamResponses {
                setMessage(content: fullResponse, for: assistantID)
            } else if messageContent(for: assistantID).isEmpty {
                setMessage(content: fullResponse, for: assistantID)
            }

            trimStoredMessagesIfNeeded()
            saveMessages()
            clearStreamingState(for: assistantID)
            isSending = false
        } catch {
            clearStreamingState(for: assistantID)
            removeMessage(id: assistantID)
            saveMessages()
            isSending = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearConversation() {
        messages.removeAll()
        saveMessages()
    }

    func warmUpIfNeeded(settings: ChatAISettings) async {
        let key = "\(settings.provider.rawValue)|\(settings.selectedModel)|\(settings.baseURLString)"
        guard lastWarmupKey != key else { return }
        lastWarmupKey = key
        isWarmingUp = true
        warmupStatus = "Activating \(settings.selectedModel)..."

        do {
            switch settings.provider {
            case .ollamaLocal:
                try await ollamaClient.warmUpModel(settings: settings)
            case .xaiReasoning, .xaiNonReasoning:
                try await xaiClient.warmUpModel(settings: settings)
            }
            warmupStatus = nil
            isWarmingUp = false
        } catch {
            warmupStatus = nil
            isWarmingUp = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func appendToken(_ token: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let next = messages[index].content + token
        let clipped = String(next.prefix(activeRenderCharLimit))
        let updated = ChatMessage(id: id, role: .assistant, content: clipped, createdAt: messages[index].createdAt)
        messages[index] = updated
    }

    private func enqueueToken(_ token: String, for id: UUID) {
        pendingTokenBuffers[id, default: ""] += token
        if flushTasks[id] == nil {
            flushTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                await MainActor.run {
                    self?.flushBufferedTokens(for: id)
                }
            }
        }
    }

    private func handleStreamToken(_ token: String, for id: UUID) async {
        enqueueToken(token, for: id)
    }

    private func flushBufferedTokens(for id: UUID) {
        if let task = flushTasks[id] {
            task.cancel()
            flushTasks[id] = nil
        }
        guard let buffered = pendingTokenBuffers[id], !buffered.isEmpty else { return }
        pendingTokenBuffers[id] = nil
        appendToken(buffered, to: id)
    }

    private func setMessage(content: String, for id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let clipped = String(content.prefix(activeRenderCharLimit))
        messages[index] = ChatMessage(id: id, role: .assistant, content: clipped, createdAt: messages[index].createdAt)
    }

    private func messageContent(for id: UUID) -> String {
        messages.first(where: { $0.id == id })?.content ?? ""
    }

    private func removeMessage(id: UUID) {
        messages.removeAll(where: { $0.id == id })
    }

    private func clearStreamingState(for id: UUID) {
        if let task = flushTasks[id] {
            task.cancel()
            flushTasks[id] = nil
        }
        pendingTokenBuffers[id] = nil
    }

    private func saveMessages() {
        let snapshot = messages
        store.saveAsync(snapshot) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func sanitizeLoadedMessages(_ input: [ChatMessage]) -> [ChatMessage] {
        let sanitized = input.map { message in
            guard message.role == .user,
                  let markerRange = message.content.range(of: "Health metrics summary:") else {
                return message
            }
            let trimmed = String(message.content[..<markerRange.lowerBound]).replacingOccurrences(of: "User question:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatMessage(id: message.id, role: message.role, content: trimmed, createdAt: message.createdAt)
        }
        return Array(sanitized.suffix(maxStoredMessages))
    }

    private func effectiveSystemPrompt(healthSummary: String) -> String {
        let trimmedSummary = String(healthSummary.prefix(maxHealthSummaryChars))
        let sections = [
            systemPrompt,
            "",
            "Current user metrics summary:",
            trimmedSummary
        ]
        return sections.joined(separator: "\n")
    }

    private func modelInputMessages() -> [ChatMessage] {
        let window = Array(messages.suffix(modelContextMessages))
        return window.map { message in
            let clipped = String(message.content.prefix(maxCharsPerContextMessage))
            return ChatMessage(id: message.id, role: message.role, content: clipped, createdAt: message.createdAt)
        }
    }

    private func trimStoredMessagesIfNeeded() {
        if messages.count > maxStoredMessages {
            messages = Array(messages.suffix(maxStoredMessages))
        }
    }
}
