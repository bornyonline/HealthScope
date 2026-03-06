import SwiftUI

struct ContentView: View {
    @StateObject private var healthViewModel = HealthDashboardViewModel()

    var body: some View {
        TabView {
            HealthDashboardView()
                .tabItem {
                    Label("Health", systemImage: "heart.text.square")
                }

            AnalysisChatView()
                .tabItem {
                    Label("Analysis & Advice", systemImage: "message.badge")
                }
        }
        .environmentObject(healthViewModel)
    }
}
