import SwiftUI
import UniformTypeIdentifiers

struct HealthDashboardView: View {
    @EnvironmentObject private var viewModel: HealthDashboardViewModel
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.blue.opacity(0.10), Color.green.opacity(0.10), Color(.systemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        Picker("Date Range", selection: $viewModel.selectedRange) {
                            ForEach(DateRangeOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 2)

                        NavigationLink {
                            BloodPressureDetailView()
                        } label: {
                            BloodPressureCard(points: viewModel.bloodPressure)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            TimeMetricDetailView(metric: .bloodGlucose, unitLabel: "mg/dL", color: .pink)
                        } label: {
                            LineMetricCard(
                                title: "Blood Glucose",
                                unitLabel: "mg/dL",
                                points: viewModel.bloodGlucose,
                                color: .pink
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            TimeMetricDetailView(metric: .spo2, unitLabel: "%", color: .cyan)
                        } label: {
                            LineMetricCard(
                                title: "SpO2",
                                unitLabel: "%",
                                points: viewModel.spo2,
                                color: .cyan
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            TimeMetricDetailView(metric: .heartRate, unitLabel: "BPM", color: .red)
                        } label: {
                            LineMetricCard(
                                title: "Heart Rate",
                                unitLabel: "BPM",
                                points: viewModel.heartRate,
                                color: .red
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            TimeMetricDetailView(metric: .sleep, unitLabel: "Hours", color: .indigo)
                        } label: {
                            LineMetricCard(
                                title: "Sleep Pattern",
                                unitLabel: "Hours",
                                points: viewModel.sleep,
                                color: .indigo
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            TimeMetricDetailView(metric: .steps, unitLabel: "Count", color: .green)
                        } label: {
                            LineMetricCard(
                                title: "Steps",
                                unitLabel: "Count",
                                points: viewModel.steps,
                                color: .green
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ActivityDetailView()
                        } label: {
                            ActivityCard(points: viewModel.activities)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                }
                .refreshable {
                    do {
                        try await viewModel.refreshData()
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }

                if viewModel.isLoading {
                    ProgressView("Loading Health Data")
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .navigationTitle("HealthScope")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showExporter = true
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.csvDocument.content.isEmpty)
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: viewModel.csvDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "healthscope_export"
            ) { result in
                if case .failure(let error) = result {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .alert("HealthScope", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("Retry") {
                    Task {
                        await viewModel.retry()
                    }
                }
                Button("Dismiss", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "Unexpected error")
            }
            .task {
                guard !viewModel.hasRequestedAuthorization else { return }
                await viewModel.authorizeAndLoad()
            }
            .task(id: viewModel.selectedRange) {
                guard viewModel.hasRequestedAuthorization else { return }
                await viewModel.refreshForDateRangeChange()
            }
        }
    }
}
