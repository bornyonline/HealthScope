import SwiftUI

struct AnalysisChatView: View {
    @EnvironmentObject private var healthViewModel: HealthDashboardViewModel
    @StateObject private var chatViewModel = AnalysisChatViewModel()

    @State private var showSettings = false

    @AppStorage("ai_provider") private var providerRaw = AIProviderOption.ollamaLocal.rawValue
    @AppStorage("ollama_base_url") private var baseURL = "http://127.0.0.1:11434"
    @AppStorage("ollama_model") private var modelName = "llama3.1:8b"
    @AppStorage("xai_api_key") private var xaiAPIKey = ""
    @AppStorage("ollama_stream") private var streamResponses = true
    @AppStorage("analysis_device_safe_mode") private var deviceSafeMode = true
    @AppStorage("ollama_timeout_seconds") private var timeoutSeconds = 90.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if chatViewModel.isWarmingUp, let status = chatViewModel.warmupStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                ScrollViewReader { proxy in
                    List {
                        ForEach(displayedMessages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        if chatViewModel.isSending {
                            TypingIndicatorBubble()
                                .id("typing")
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemBackground))
                    .onChange(of: chatViewModel.messages.count) {
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: chatViewModel.isSending) {
                        scrollToBottom(proxy: proxy)
                    }
                }

                if let error = chatViewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }

                ComposerBar(isSending: chatViewModel.isSending) { userText in
                    sendMessage(userText: userText)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("Analysis & Advice")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        chatViewModel.clearConversation()
                    }
                    .disabled(chatViewModel.messages.isEmpty || chatViewModel.isSending)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Section("Provider") {
                            Picker("Model Provider", selection: $providerRaw) {
                                ForEach(AIProviderOption.allCases) { option in
                                    Text(option.label).tag(option.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        if selectedProvider == .ollamaLocal {
                            Section("Ollama") {
                                TextField("Base URL", text: $baseURL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .keyboardType(.URL)

                                TextField("Model", text: $modelName)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                            }
                        } else {
                            Section("xAI") {
                                Text("Model: \(selectedProvider.modelName)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                SecureField("xAI API Key", text: $xaiAPIKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                            }
                        }

                        Section("Response") {
                            Toggle("Stream responses", isOn: $streamResponses)
                            Toggle("Device Safe Mode (iPhone)", isOn: $deviceSafeMode)
                            if deviceSafeMode {
                                Text("Safe Mode forces lower-overhead replies and can ignore streaming to prevent freezes.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("Timeout")
                                Spacer()
                                TextField("Seconds", value: $timeoutSeconds, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 90)
                            }
                        }
                    }
                    .navigationTitle("Analysis Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showSettings = false
                            }
                        }
                    }
                }
            }
            .task(id: providerRaw) {
                await chatViewModel.warmUpIfNeeded(settings: currentSettings)
            }
        }
    }

    private var selectedProvider: AIProviderOption {
        AIProviderOption(rawValue: providerRaw) ?? .ollamaLocal
    }

    private func sendMessage(userText: String) {
        Task {
            await chatViewModel.send(
                userText: userText,
                healthSummary: healthViewModel.aiSummaryContext(),
                settings: currentSettings
            )
        }
    }

    private var currentSettings: ChatAISettings {
        ChatAISettings(
            provider: selectedProvider,
            baseURLString: baseURL,
            ollamaModel: modelName,
            xaiAPIKey: xaiAPIKey,
            streamResponses: streamResponses,
            deviceSafeMode: deviceSafeMode,
            timeoutSeconds: max(5, timeoutSeconds)
        )
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if chatViewModel.isSending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = displayedMessages.last?.id {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private var displayedMessages: [ChatMessage] {
        Array(chatViewModel.messages.suffix(6))
    }
}

private struct ComposerBar: View {
    let isSending: Bool
    let onSend: (String) -> Void
    @State private var inputText = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your trends...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit {
                    sendIfPossible()
                }

            Button("Send") {
                sendIfPossible()
            }
            .buttonStyle(.borderedProminent)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
    }

    private func sendIfPossible() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        onSend(trimmed)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(verbatim: message.content)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(foregroundColor)
    }

    private var backgroundColor: Color {
        message.role == .assistant ? Color(.secondarySystemBackground) : Color.accentColor
    }

    private var foregroundColor: Color {
        message.role == .assistant ? .primary : .white
    }
}

private struct TypingIndicatorBubble: View {
    var body: some View {
        HStack {
            Text("Analyzing...")
                .font(.footnote)
                .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer(minLength: 48)
        }
    }
}
