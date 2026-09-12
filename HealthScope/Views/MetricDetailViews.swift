import SwiftUI
import UniformTypeIdentifiers

struct BloodPressureDetailView: View {
    @EnvironmentObject private var viewModel: HealthDashboardViewModel

    @State private var showEntryForm = false
    @State private var showImporter = false
    @State private var selectedDate: Date?

    private var period: String {
        "Last \(viewModel.selectedRange.rawValue) days"
    }

    var body: some View {
        List {
            Section {
                BloodPressureCard(
                    points: viewModel.bloodPressure,
                    period: period,
                    chartHeight: 320,
                    selection: $selectedDate
                )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Manual Entries") {
                if viewModel.manualBloodPressurePoints().isEmpty {
                    Text("No manual entries in this range")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.manualBloodPressurePoints().prefix(30)) { point in
                        HStack {
                            Text(point.date, style: .date)
                            Spacer()
                            Text("\(Int(point.systolic))/\(Int(point.diastolic)) mmHg")
                        }
                    }
                }
            }
        }
        .navigationTitle("Blood Pressure")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Import CSV") {
                    showImporter = true
                }
                Button("Add Entry") {
                    showEntryForm = true
                }
            }
        }
        .sheet(isPresented: $showEntryForm) {
            BloodPressureEntryForm { date, systolic, diastolic in
                viewModel.addManualBloodPressure(date: date, systolic: systolic, diastolic: diastolic)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let imported = try await viewModel.importCSV(for: .bloodPressure, from: url)
                        if imported == 0 {
                            viewModel.errorMessage = "No valid blood pressure rows were imported."
                        }
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

struct TimeMetricDetailView: View {
    let metric: MetricType

    @EnvironmentObject private var viewModel: HealthDashboardViewModel
    @EnvironmentObject private var preferences: AppPreferences

    @State private var showEntryForm = false
    @State private var showImporter = false
    @State private var selectedDate: Date?

    private var points: [TimeValuePoint] {
        viewModel.timeValuePoints(for: metric)
    }

    private var manualPoints: [TimeValuePoint] {
        viewModel.manualTimeValuePoints(for: metric)
    }

    private var period: String {
        "Last \(viewModel.selectedRange.rawValue) days"
    }

    var body: some View {
        List {
            Section {
                TimeMetricCard(
                    metric: metric,
                    points: points,
                    period: period,
                    chartHeight: 320,
                    selection: $selectedDate
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Manual Entries") {
                if manualPoints.isEmpty {
                    Text("No manual entries in this range")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manualPoints.prefix(30)) { point in
                        HStack {
                            Text(point.date, style: .date)
                            Spacer()
                            Text(manualValueText(point.value))
                        }
                    }
                }
            }
        }
        .navigationTitle(metric.title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Import CSV") {
                    showImporter = true
                }
                Button("Add Entry") {
                    showEntryForm = true
                }
            }
        }
        .sheet(isPresented: $showEntryForm) {
            TimeValueEntryForm(
                title: metric.title,
                unitLabel: metric.entryUnit(for: preferences.measurementSystem)
            ) { date, value in
                let canonicalValue = metric == .bloodGlucose
                    ? preferences.measurementSystem.canonicalGlucose(fromDisplayValue: value)
                    : value
                return viewModel.addManualTimeValue(metric: metric, date: date, value: canonicalValue)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let imported = try await viewModel.importCSV(for: metric, from: url)
                        if imported == 0 {
                            viewModel.errorMessage = "No valid rows were imported for \(metric.title)."
                        }
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func manualValueText(_ canonicalValue: Double) -> String {
        if metric == .bloodGlucose {
            return metric.formatted(canonicalValue, measurementSystem: preferences.measurementSystem)
        }
        return "\(canonicalValue.formatted(.number.precision(.fractionLength(1)))) \(metric.entryUnit(for: preferences.measurementSystem))"
    }
}

struct ActivityDetailView: View {
    @EnvironmentObject private var viewModel: HealthDashboardViewModel

    @State private var showEntryForm = false
    @State private var showImporter = false

    private var period: String {
        "Last \(viewModel.selectedRange.rawValue) days"
    }

    var body: some View {
        List {
            Section {
                ActivityCard(points: viewModel.activities, period: period, chartHeight: 320)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Manual Entries") {
                if viewModel.manualActivityEntries().isEmpty {
                    Text("No manual entries in this range")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.manualActivityEntries().prefix(30)) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text(entry.date, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(entry.minutes.formatted(.number.precision(.fractionLength(1)))) min")
                        }
                    }
                }
            }
        }
        .navigationTitle("Activities")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Import CSV") {
                    showImporter = true
                }
                Button("Add Entry") {
                    showEntryForm = true
                }
            }
        }
        .sheet(isPresented: $showEntryForm) {
            ActivityEntryForm { date, name, minutes in
                viewModel.addManualActivity(date: date, name: name, minutes: minutes)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let imported = try await viewModel.importCSV(for: .activities, from: url)
                        if imported == 0 {
                            viewModel.errorMessage = "No valid activity rows were imported."
                        }
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct BloodPressureEntryForm: View {
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var systolic = ""
    @State private var diastolic = ""

    let onSave: (Date, Double, Double) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: [.date])
                TextField("Systolic (mmHg)", text: $systolic)
                    .keyboardType(.decimalPad)
                TextField("Diastolic (mmHg)", text: $diastolic)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Add Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let s = parseLocalizedDecimal(systolic),
                              let d = parseLocalizedDecimal(diastolic) else { return }
                        if onSave(date, s, d) {
                            dismiss()
                        }
                    }
                    .disabled(parseLocalizedDecimal(systolic) == nil || parseLocalizedDecimal(diastolic) == nil)
                }
            }
        }
    }
}

private struct TimeValueEntryForm: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let unitLabel: String
    let onSave: (Date, Double) -> Bool

    @State private var date = Date()
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: [.date])
                TextField("Value (\(unitLabel))", text: $value)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Add \(title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let parsed = parseLocalizedDecimal(value) else { return }
                        if onSave(date, parsed) {
                            dismiss()
                        }
                    }
                    .disabled(parseLocalizedDecimal(value) == nil)
                }
            }
        }
    }
}

private struct ActivityEntryForm: View {
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var name = ""
    @State private var minutes = ""

    let onSave: (Date, String, Double) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: [.date])
                TextField("Activity (Running, Boxing, etc)", text: $name)
                TextField("Minutes", text: $minutes)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Add Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let parsedMinutes = parseLocalizedDecimal(minutes) else { return }
                        if onSave(date, name.trimmingCharacters(in: .whitespacesAndNewlines), parsedMinutes) {
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parseLocalizedDecimal(minutes) == nil)
                }
            }
        }
    }
}
