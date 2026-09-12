import SwiftUI

struct HealthDashboardView: View {
    @EnvironmentObject private var viewModel: HealthDashboardViewModel

    let onShowProfile: () -> Void
    let onShowConfiguration: () -> Void
    let onExport: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 310, maximum: 520), spacing: 16, alignment: .top)
    ]

    private var period: String {
        "Last \(viewModel.selectedRange.rawValue) days"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                dashboardBackground

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: []) {
                        rangePicker

                        if viewModel.isLoading {
                            loadingBanner
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        dashboardSection(
                            title: "Vitals",
                            subtitle: "Daily cardiovascular and metabolic signals",
                            systemImage: "waveform.path.ecg"
                        ) {
                            NavigationLink {
                                BloodPressureDetailView()
                            } label: {
                                BloodPressureCard(points: viewModel.bloodPressure, period: period)
                            }
                            .buttonStyle(.plain)

                            metricLink(.bloodGlucose, points: viewModel.bloodGlucose)
                            metricLink(.spo2, points: viewModel.spo2)
                            metricLink(.heartRate, points: viewModel.heartRate)
                        }

                        dashboardSection(
                            title: "Recovery",
                            subtitle: "Rest and overnight duration",
                            systemImage: "moon.stars.fill"
                        ) {
                            metricLink(.sleep, points: viewModel.sleep)
                        }

                        dashboardSection(
                            title: "Movement",
                            subtitle: "Daily movement and activity mix",
                            systemImage: "figure.walk.motion"
                        ) {
                            metricLink(.steps, points: viewModel.steps)

                            NavigationLink {
                                ActivityDetailView()
                            } label: {
                                ActivityCard(points: viewModel.activities, period: period)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .refreshable {
                    do {
                        try await viewModel.refreshData()
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isLoading)
            .navigationTitle("HealthScope")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MainMenuButton(
                        exportDisabled: viewModel.csvDocument.content.isEmpty,
                        onShowProfile: onShowProfile,
                        onShowConfiguration: onShowConfiguration,
                        onExport: onExport
                    )
                }
            }
            .alert("HealthScope", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("Retry") {
                    Task { await viewModel.retry() }
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

    private var dashboardBackground: some View {
        LinearGradient(
            colors: [
                Color.blue.opacity(0.08),
                Color.teal.opacity(0.06),
                Color(.systemBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIME PERIOD")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Picker("Date Range", selection: $viewModel.selectedRange) {
                ForEach(DateRangeOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        .accessibilityElement(children: .contain)
    }

    private var loadingBanner: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                loadingTitle
                Spacer()
                loadingDetail
            }

            VStack(alignment: .leading, spacing: 4) {
                loadingTitle
                loadingDetail
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Updating health data. Existing results remain available.")
    }

    private var loadingTitle: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Updating health data...")
                .font(.subheadline.weight(.medium))
        }
    }

    private var loadingDetail: some View {
        Text("Existing results remain available")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func metricLink(_ metric: MetricType, points: [TimeValuePoint]) -> some View {
        NavigationLink {
            TimeMetricDetailView(metric: metric)
        } label: {
            TimeMetricCard(metric: metric, points: points, period: period)
        }
        .buttonStyle(.plain)
    }

    private func dashboardSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                content()
            }
        }
    }
}
