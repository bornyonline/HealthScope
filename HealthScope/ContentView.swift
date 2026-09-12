import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var healthViewModel = HealthDashboardViewModel()
    @StateObject private var profileViewModel = UserProfileViewModel()
    @StateObject private var preferences = AppPreferences()

    @State private var selectedTab: AppTab = .health
    @State private var showUserProfile = false
    @State private var showAnalysisSettings = false
    @State private var showExporter = false
    @State private var exportError: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            HealthDashboardView(
                onShowProfile: { showUserProfile = true },
                onShowConfiguration: showConfiguration,
                onExport: { showExporter = true }
            )
                .tabItem {
                    Label("Health", systemImage: "heart.text.square")
                }
                .tag(AppTab.health)

            AnalysisChatView(
                showSettings: $showAnalysisSettings,
                isActive: selectedTab == .analysis,
                onShowProfile: { showUserProfile = true },
                onShowConfiguration: { showAnalysisSettings = true },
                onExport: { showExporter = true }
            )
                .tabItem {
                    Label("Analysis & Advice", systemImage: "message.badge")
                }
                .tag(AppTab.analysis)
        }
        .environmentObject(healthViewModel)
        .environmentObject(profileViewModel)
        .environmentObject(preferences)
        .sheet(isPresented: $showUserProfile) {
            UserProfileView()
                .environmentObject(profileViewModel)
                .environmentObject(preferences)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: healthViewModel.csvDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "healthscope_export"
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("Dismiss", role: .cancel) { }
        } message: {
            Text(exportError ?? "Unexpected export error")
        }
    }

    private func showConfiguration() {
        showAnalysisSettings = true
        selectedTab = .analysis
    }
}

private enum AppTab: Hashable {
    case health
    case analysis
}
