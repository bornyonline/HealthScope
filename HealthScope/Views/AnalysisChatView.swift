import SwiftUI

struct AnalysisChatView: View {
    @EnvironmentObject private var healthViewModel: HealthDashboardViewModel
    @EnvironmentObject private var preferences: AppPreferences
    @StateObject private var chatViewModel = AnalysisChatViewModel()

    @Binding var showSettings: Bool
    let isActive: Bool
    let onShowProfile: () -> Void
    let onShowConfiguration: () -> Void
    let onExport: () -> Void

    @State private var showHealthDataConsent = false
    @State private var inputText = ""
    @State private var unslothAPIKey = ""
    @State private var credentialError: String?
    @State private var credentialLoaded = false
    @State private var isPreparingHealthContext = false
    @State private var clinicalPreparationTask: Task<Void, Never>?
    @State private var pendingConsentProvider: AIProviderOption?
    @State private var pendingConsentRequest: ChatRequest?
    @State private var automaticOpeningGeneration = 0
    @State private var attemptedAutomaticOpeningGeneration: Int?

    @AppStorage("ai_provider") private var providerRaw = AIProviderOption.ollamaLocal.rawValue
    @AppStorage("ollama_base_url") private var ollamaBaseURL = "http://127.0.0.1:11434"
    @AppStorage("ollama_model") private var ollamaModel = "llama3.1:8b"
    @AppStorage("unsloth_base_url") private var unslothBaseURL = ""
    @AppStorage("unsloth_model") private var unslothModel = ""
    @AppStorage("ollama_stream") private var streamResponses = true
    @AppStorage("analysis_device_safe_mode") private var deviceSafeMode = true
    @AppStorage("analysis_include_clinical_records") private var includeClinicalRecords = false
    @AppStorage("analysis_health_data_ollama") private var ollamaHealthDataPreferenceRaw = HealthDataSharingPreference.ask.rawValue
    @AppStorage("analysis_health_data_unsloth") private var unslothHealthDataPreferenceRaw = HealthDataSharingPreference.ask.rawValue
    @AppStorage("ollama_timeout_seconds") private var timeoutSeconds = 90.0

    private let credentialStore = AICredentialStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showsPlaintextHTTPWarning {
                    PlaintextHTTPWarning(endpoint: selectedBaseURL)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

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

                if isPreparingHealthContext {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing your clinical record summary...")
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

                ComposerBar(
                    inputText: $inputText,
                    isSending: chatViewModel.isSending,
                    isPreparing: isPreparingHealthContext,
                    onSend: requestSend,
                    onStop: chatViewModel.stopGenerating
                )
                .padding()
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("Analysis & Advice")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        if chatViewModel.clearConversation() {
                            automaticOpeningGeneration &+= 1
                        }
                    }
                    .disabled(chatViewModel.messages.isEmpty || chatViewModel.isSending)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    MainMenuButton(
                        exportDisabled: healthViewModel.csvDocument.content.isEmpty,
                        onShowProfile: onShowProfile,
                        onShowConfiguration: onShowConfiguration,
                        onExport: onExport
                    )
                    .disabled(isPreparingHealthContext)
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
                    .interactiveDismissDisabled()
            }
            .alert(healthConsentTitle, isPresented: $showHealthDataConsent) {
                Button(healthSummaryButtonTitle) {
                    resolveHealthDataConsent(.enabled)
                }
                Button("Don't Send Health Data") {
                    resolveHealthDataConsent(.disabled)
                }
                Button("Cancel", role: .cancel) {
                    clearPendingConsent()
                }
            } message: {
                Text(healthConsentMessage)
            }
            .task {
                UserDefaults.standard.removeObject(forKey: "xai_api_key")
                if AIProviderOption(rawValue: providerRaw) == nil {
                    providerRaw = AIProviderOption.unslothLAN.rawValue
                    showSettings = true
                }
                loadAPIKey()
            }
            .task(id: providerPreparationID) {
                await prepareProviderAndStartConversationIfNeeded()
            }
            .onChange(of: includeClinicalRecords) {
                if !includeClinicalRecords {
                    healthViewModel.clearClinicalRecordsFromMemory()
                }
            }
            .onDisappear {
                clinicalPreparationTask?.cancel()
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Measurement Units") {
                    Picker("Units", selection: $preferences.measurementSystem) {
                        ForEach(MeasurementSystemPreference.allCases) { system in
                            Text(system.title).tag(system)
                        }
                    }
                    .pickerStyle(.segmented)
                }

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
                        providerTextField("Base URL", text: $ollamaBaseURL, keyboardType: .URL)
                        providerTextField("Model", text: $ollamaModel)

                        if showsPlaintextHTTPWarning {
                            PlaintextHTTPWarning(endpoint: ollamaBaseURL)
                        }
                    }
                } else {
                    Section("Unsloth LAN") {
                        providerTextField("Base URL", text: $unslothBaseURL, keyboardType: .URL)
                        providerTextField("Model ID", text: $unslothModel)

                        SecureField("Bearer API Key (optional)", text: $unslothAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                        Text("The bearer API key is stored in Keychain, not app preferences.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if showsPlaintextHTTPWarning {
                            PlaintextHTTPWarning(endpoint: unslothBaseURL)
                        }
                    }
                }

                Section("Response") {
                    if selectedProvider == .ollamaLocal {
                        Toggle("Stream responses", isOn: $streamResponses)
                    } else {
                        Text("Unsloth responses always use SSE streaming and must end with [DONE].")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Device Safe Mode (iPhone)", isOn: $deviceSafeMode)
                    if deviceSafeMode {
                        Text("Safe Mode batches larger response updates to reduce UI overhead without shortening replies.")
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

                Section("Health Data") {
                    if selectedHealthDataPreference == .ask {
                        LabeledContent("Send Health Data with Messages") {
                            Text("Ask on First Send")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle("Send Health Data with Messages", isOn: selectedProviderHealthDataBinding)
                    }

                    Text(healthDataPreferenceDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if selectedHealthDataPreference == .disabled {
                        Text("Clinical records are not sent while health-data sharing is off for this provider.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Include Clinical Records in AI", isOn: $includeClinicalRecords)
                            .disabled(clinicalRecordsToggleDisabled)

                        if healthViewModel.supportsClinicalRecords {
                            Text("Off by default. When enabled, permission is requested on the first message that includes clinical records. Only bounded summaries of allergies, conditions, immunizations, labs, medications, procedures, and vital signs are included; raw records are never sent.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Clinical Health Records are unavailable on this device or in this region. Standard HealthKit summaries remain available.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let credentialError {
                    Section {
                        Text(credentialError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Analysis Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAPIKeyAndClose()
                    }
                }
            }
        }
    }

    private var selectedProvider: AIProviderOption {
        AIProviderOption(rawValue: providerRaw) ?? .ollamaLocal
    }

    private var selectedHealthDataPreference: HealthDataSharingPreference {
        healthDataPreference(for: selectedProvider)
    }

    private var selectedProviderHealthDataBinding: Binding<Bool> {
        Binding(
            get: { selectedHealthDataPreference == .enabled },
            set: { isEnabled in
                setHealthDataPreference(isEnabled ? .enabled : .disabled, for: selectedProvider)
            }
        )
    }

    private var healthDataPreferenceDescription: String {
        switch selectedHealthDataPreference {
        case .ask:
            return "Not configured for \(selectedProvider.label). You will be asked once when you send the first message to this provider."
        case .enabled:
            return "Saved for \(selectedProvider.label). HealthScope will automatically include your current health summary with messages."
        case .disabled:
            return "Saved for \(selectedProvider.label). Only your current question will be sent, without health data or conversation history."
        }
    }

    private var clinicalRecordsToggleDisabled: Bool {
        guard !includeClinicalRecords else { return false }
        return !healthViewModel.supportsClinicalRecords
    }

    private func healthDataPreference(for provider: AIProviderOption) -> HealthDataSharingPreference {
        let rawValue: Int
        switch provider {
        case .ollamaLocal:
            rawValue = ollamaHealthDataPreferenceRaw
        case .unslothLAN:
            rawValue = unslothHealthDataPreferenceRaw
        }
        return HealthDataSharingPreference(rawValue: rawValue) ?? .ask
    }

    private func setHealthDataPreference(
        _ preference: HealthDataSharingPreference,
        for provider: AIProviderOption
    ) {
        switch provider {
        case .ollamaLocal:
            ollamaHealthDataPreferenceRaw = preference.rawValue
        case .unslothLAN:
            unslothHealthDataPreferenceRaw = preference.rawValue
        }
    }

    private var showsPlaintextHTTPWarning: Bool {
        selectedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    private var selectedBaseURL: String {
        baseURL(for: selectedProvider)
    }

    private func baseURL(for provider: AIProviderOption) -> String {
        provider == .ollamaLocal ? ollamaBaseURL : unslothBaseURL
    }

    private var warmupID: String {
        "\(credentialLoaded)|\(providerRaw)|\(currentSettings.selectedModel)|\(selectedProvider == .ollamaLocal ? ollamaBaseURL : unslothBaseURL)"
    }

    private var providerPreparationID: String {
        [
            warmupID,
            String(isActive),
            String(showSettings),
            String(chatViewModel.messages.isEmpty),
            String(healthViewModel.hasRequestedAuthorization),
            String(healthViewModel.isLoading),
            String(selectedHealthDataPreference.rawValue),
            String(automaticOpeningGeneration)
        ].joined(separator: "|")
    }

    private func providerTextField(
        _ title: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default
    ) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(keyboardType)
    }

    private func prepareProviderAndStartConversationIfNeeded() async {
        guard credentialLoaded, isActive, !showSettings else { return }

        if selectedProvider == .ollamaLocal {
            await chatViewModel.warmUpIfNeeded(settings: currentSettings)
        }

        guard !Task.isCancelled,
              chatViewModel.canStartConversationAutomatically,
              attemptedAutomaticOpeningGeneration != automaticOpeningGeneration else {
            return
        }

        do {
            try currentSettings.validate()
        } catch {
            chatViewModel.errorMessage = error.localizedDescription
            return
        }

        if selectedHealthDataPreference != .disabled {
            guard healthViewModel.hasRequestedAuthorization, !healthViewModel.isLoading else { return }
        }

        attemptedAutomaticOpeningGeneration = automaticOpeningGeneration
        routeRequest(.automaticOpening)
    }

    private func requestSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPreparingHealthContext, !text.isEmpty else { return }
        routeRequest(.user(text))
    }

    private func routeRequest(_ request: ChatRequest) {
        guard !isPreparingHealthContext else { return }
        switch selectedHealthDataPreference {
        case .ask:
            pendingConsentProvider = selectedProvider
            pendingConsentRequest = request
            showHealthDataConsent = true
        case .enabled:
            sendHealthSummary(request: request)
        case .disabled:
            sendMessage(
                request: request,
                includeHealthSummary: false,
                includesClinicalContext: false
            )
        }
    }

    private func resolveHealthDataConsent(_ preference: HealthDataSharingPreference) {
        guard let provider = pendingConsentProvider,
              let request = pendingConsentRequest else {
            return
        }
        setHealthDataPreference(preference, for: provider)
        clearPendingConsent()

        guard provider == selectedProvider else { return }
        switch preference {
        case .enabled:
            sendHealthSummary(request: request)
        case .disabled:
            sendMessage(
                request: request,
                includeHealthSummary: false,
                includesClinicalContext: false
            )
        case .ask:
            break
        }
    }

    private func clearPendingConsent() {
        pendingConsentProvider = nil
        pendingConsentRequest = nil
    }

    private func sendHealthSummary(request: ChatRequest) {
        let shouldIncludeClinicalRecords = includeClinicalRecords

        guard shouldIncludeClinicalRecords else {
            sendMessage(
                request: request,
                includeHealthSummary: true,
                includesClinicalContext: false
            )
            return
        }

        isPreparingHealthContext = true
        clinicalPreparationTask = Task {
            defer {
                isPreparingHealthContext = false
                clinicalPreparationTask = nil
            }
            do {
                try await healthViewModel.prepareClinicalRecordsForAnalysis()
                try Task.checkCancellation()
                guard selectedHealthDataPreference == .enabled, includeClinicalRecords else {
                    healthViewModel.clearClinicalRecordsFromMemory()
                    return
                }
                sendMessage(
                    request: request,
                    includeHealthSummary: true,
                    includesClinicalContext: true
                )
            } catch is CancellationError {
                healthViewModel.clearClinicalRecordsFromMemory()
                return
            } catch {
                healthViewModel.clearClinicalRecordsFromMemory()
                chatViewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func sendMessage(
        request: ChatRequest,
        includeHealthSummary: Bool,
        includesClinicalContext: Bool
    ) {
        let healthSummary = includeHealthSummary
            ? healthViewModel.aiSummaryContext(
                includeClinicalRecords: includesClinicalContext,
                measurementSystem: preferences.measurementSystem
            )
            : nil
        if includesClinicalContext {
            healthViewModel.clearClinicalRecordsFromMemory()
        }

        let started: Bool
        switch request {
        case .user(let text):
            started = chatViewModel.send(
                userText: text,
                healthSummary: healthSummary,
                includesClinicalContext: includesClinicalContext,
                settings: currentSettings
            )
        case .automaticOpening:
            started = chatViewModel.startConversation(
                healthSummary: healthSummary,
                includesClinicalContext: includesClinicalContext,
                settings: currentSettings
            )
        }

        if started, case .user(_) = request {
            inputText = ""
        }
    }

    private var currentSettings: ChatAISettings {
        ChatAISettings(
            provider: selectedProvider,
            ollamaBaseURLString: ollamaBaseURL,
            ollamaModel: ollamaModel,
            unslothBaseURLString: unslothBaseURL,
            unslothModel: unslothModel,
            unslothAPIKey: unslothAPIKey,
            streamResponses: streamResponses,
            deviceSafeMode: deviceSafeMode,
            timeoutSeconds: timeoutSeconds
        )
    }

    private var healthConsentTitle: String {
        let provider = pendingConsentProvider ?? selectedProvider
        return includeClinicalRecords
            ? "Send health and clinical data to \(provider.label)?"
            : "Send health data to \(provider.label)?"
    }

    private var healthSummaryButtonTitle: String {
        includeClinicalRecords ? "Send Health + Clinical Summary" : "Send Health Summary"
    }

    private var healthConsentMessage: String {
        let provider = pendingConsentProvider ?? selectedProvider
        let includedData: String
        if pendingConsentRequest?.isAutomaticOpening == true {
            includedData = includeClinicalRecords
                ? "Your dated HealthScope metric history, bounded workout and clinical-record data, and an automatic opening instruction"
                : "Your dated HealthScope metric history, bounded workout data, and an automatic opening instruction"
        } else {
            includedData = includeClinicalRecords
                ? "Your dated HealthScope metric history, bounded workout and clinical-record data, your question, and eligible recent conversation context"
                : "Your dated HealthScope metric history, bounded workout data, your question, and recent conversation context that does not contain clinical-record-derived responses"
        }
        let endpoint = baseURL(for: provider)
        let transportWarning = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
            ? " This endpoint uses unencrypted HTTP, so the data may be readable on the network."
            : ""
        return "\(includedData) will be sent to \(endpoint).\(transportWarning) Your choice will be saved for \(provider.label) and can be changed in Analysis Settings."
    }

    private func loadAPIKey() {
        guard !credentialLoaded else { return }
        do {
            unslothAPIKey = try credentialStore.loadUnslothAPIKey()
            credentialLoaded = true
        } catch {
            credentialError = error.localizedDescription
            credentialLoaded = true
        }
    }

    private func saveAPIKeyAndClose() {
        do {
            try credentialStore.saveUnslothAPIKey(unslothAPIKey)
            UserDefaults.standard.set(ollamaBaseURL, forKey: "ollama_base_url")
            UserDefaults.standard.set(unslothBaseURL, forKey: "unsloth_base_url")
            credentialError = nil
            if chatViewModel.messages.isEmpty {
                attemptedAutomaticOpeningGeneration = nil
            }
            showSettings = false
        } catch {
            credentialError = error.localizedDescription
        }
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

private enum ChatRequest {
    case user(String)
    case automaticOpening

    var isAutomaticOpening: Bool {
        if case .automaticOpening = self { return true }
        return false
    }
}

private struct ComposerBar: View {
    @Binding var inputText: String
    let isSending: Bool
    let isPreparing: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your trends...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .disabled(isSending || isPreparing)
                .onSubmit {
                    if !isSending && !isPreparing { onSend() }
                }

            if isSending {
                Button("Stop", role: .destructive, action: onStop)
                    .buttonStyle(.borderedProminent)
            } else if isPreparing {
                ProgressView()
                    .frame(minWidth: 52)
            } else {
                Button("Send", action: onSend)
                    .buttonStyle(.borderedProminent)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct PlaintextHTTPWarning: View {
    let endpoint: String

    var body: some View {
        Label {
            Text("Plaintext HTTP is unencrypted. Health data, prompts, responses, and any API key sent to \(endpoint) may be readable on the network.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
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
