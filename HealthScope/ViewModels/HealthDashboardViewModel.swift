import Foundation
import Combine

@MainActor
final class HealthDashboardViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var hasRequestedAuthorization = false
    @Published var errorMessage: String?
    @Published var selectedRange: DateRangeOption = .days30

    @Published var bloodPressure: [BloodPressurePoint] = []
    @Published var bloodGlucose: [TimeValuePoint] = []
    @Published var spo2: [TimeValuePoint] = []
    @Published var heartRate: [TimeValuePoint] = []
    @Published var sleep: [TimeValuePoint] = []
    @Published var steps: [TimeValuePoint] = []
    @Published var activities: [ActivityPoint] = []

    @Published var csvDocument = CSVExportDocument(content: "")

    private var healthBloodPressure: [BloodPressurePoint] = []
    private var healthBloodGlucose: [TimeValuePoint] = []
    private var healthSpO2: [TimeValuePoint] = []
    private var healthHeartRate: [TimeValuePoint] = []
    private var healthSleep: [TimeValuePoint] = []
    private var healthSteps: [TimeValuePoint] = []
    private var healthActivities: [ActivityPoint] = []

    private var manualEntries: ManualEntries

    private let service: HealthKitService
    private let manualEntryStore: ManualEntryStore

    init(service: HealthKitService, manualEntryStore: ManualEntryStore) {
        self.service = service
        self.manualEntryStore = manualEntryStore
        self.manualEntries = manualEntryStore.load()
    }

    convenience init() {
        self.init(service: HealthKitService(), manualEntryStore: ManualEntryStore())
    }

    func authorizeAndLoad() async {
        errorMessage = nil

        guard service.isAvailable() else {
            hasRequestedAuthorization = true
            refreshFromManualOnly()
            return
        }

        do {
            isLoading = true
            try await service.requestAuthorization()
            hasRequestedAuthorization = true
            try await refreshData()
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func refreshData() async throws {
        let range = dateRange

        async let bp = service.fetchBloodPressure(range: range)
        async let glucose = service.fetchBloodGlucose(range: range)
        async let oxygen = service.fetchSpO2(range: range)
        async let hr = service.fetchHeartRate(range: range)
        async let sleepData = service.fetchSleep(range: range)
        async let stepData = service.fetchSteps(range: range)
        async let workoutData = service.fetchActivities(range: range)

        healthBloodPressure = try await bp
        healthBloodGlucose = try await glucose
        healthSpO2 = try await oxygen
        healthHeartRate = try await hr
        healthSleep = try await sleepData
        healthSteps = try await stepData
        healthActivities = try await workoutData

        rebuildDisplayedData()
    }

    func refreshForDateRangeChange() async {
        do {
            if hasRequestedAuthorization {
                try await refreshData()
            } else {
                refreshFromManualOnly()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry() async {
        await authorizeAndLoad()
    }

    func addManualBloodPressure(date: Date, systolic: Double, diastolic: Double) {
        manualEntries.bloodPressure.append(BloodPressurePoint(date: date, systolic: systolic, diastolic: diastolic))
        persistAndRebuild()
    }

    func addManualTimeValue(metric: MetricType, date: Date, value: Double) {
        let point = TimeValuePoint(date: date, value: value)

        switch metric {
        case .bloodGlucose:
            manualEntries.bloodGlucose.append(point)
        case .spo2:
            manualEntries.spo2.append(point)
        case .heartRate:
            manualEntries.heartRate.append(point)
        case .sleep:
            manualEntries.sleep.append(point)
        case .steps:
            manualEntries.steps.append(point)
        default:
            return
        }

        persistAndRebuild()
    }

    func addManualActivity(date: Date, name: String, minutes: Double) {
        manualEntries.activities.append(DatedActivityEntry(date: date, name: name, minutes: minutes))
        persistAndRebuild()
    }

    func importCSV(for metric: MetricType, from url: URL) throws -> Int {
        let fileData = try Data(contentsOf: url)
        guard let content = String(data: fileData, encoding: .utf8) else {
            throw NSError(domain: "CSVImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to read UTF-8 CSV file."])
        }

        let rows = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var imported = 0
        for row in rows {
            if row.lowercased().contains("date") || row.lowercased().hasPrefix("blood ") || row.lowercased() == "activities" {
                continue
            }

            let columns = CSVParser.splitCSVRow(row)

            switch metric {
            case .bloodPressure:
                guard columns.count >= 3,
                      let date = Self.parseDate(columns[0]),
                      let systolic = Double(columns[1]),
                      let diastolic = Double(columns[2]) else { continue }
                manualEntries.bloodPressure.append(BloodPressurePoint(date: date, systolic: systolic, diastolic: diastolic))
                imported += 1

            case .bloodGlucose, .spo2, .heartRate, .sleep, .steps:
                guard columns.count >= 2,
                      let date = Self.parseDate(columns[0]),
                      let value = Double(columns[1]) else { continue }
                addImportedTimeValue(metric: metric, date: date, value: value)
                imported += 1

            case .activities:
                if columns.count >= 3,
                   let date = Self.parseDate(columns[0]),
                   let minutes = Double(columns[2]) {
                    manualEntries.activities.append(DatedActivityEntry(date: date, name: columns[1], minutes: minutes))
                    imported += 1
                } else if columns.count >= 2,
                          let minutes = Double(columns[1]) {
                    manualEntries.activities.append(DatedActivityEntry(date: Date(), name: columns[0], minutes: minutes))
                    imported += 1
                }
            }
        }

        persistAndRebuild()
        return imported
    }

    func timeValuePoints(for metric: MetricType) -> [TimeValuePoint] {
        switch metric {
        case .bloodGlucose: return bloodGlucose
        case .spo2: return spo2
        case .heartRate: return heartRate
        case .sleep: return sleep
        case .steps: return steps
        default: return []
        }
    }

    func manualTimeValuePoints(for metric: MetricType) -> [TimeValuePoint] {
        let range = dateRange
        switch metric {
        case .bloodGlucose:
            return manualEntries.bloodGlucose.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
        case .spo2:
            return manualEntries.spo2.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
        case .heartRate:
            return manualEntries.heartRate.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
        case .sleep:
            return manualEntries.sleep.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
        case .steps:
            return manualEntries.steps.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
        default:
            return []
        }
    }

    func manualBloodPressurePoints() -> [BloodPressurePoint] {
        manualEntries.bloodPressure
            .filter { dateRange.contains($0.date) }
            .sorted { $0.date > $1.date }
    }

    func manualActivityEntries() -> [DatedActivityEntry] {
        manualEntries.activities
            .filter { dateRange.contains($0.date) }
            .sorted { $0.date > $1.date }
    }

    func aiSummaryContext() -> String {
        func avg(_ points: [TimeValuePoint]) -> String {
            guard !points.isEmpty else { return "n/a" }
            let value = points.map(\.value).reduce(0, +) / Double(points.count)
            return String(format: "%.1f", value)
        }

        func latest(_ points: [TimeValuePoint]) -> String {
            guard let value = points.last?.value else { return "n/a" }
            return String(format: "%.1f", value)
        }

        let bpText: String = {
            guard let latestBP = bloodPressure.last else { return "n/a" }
            return String(format: "%.0f/%.0f mmHg", latestBP.systolic, latestBP.diastolic)
        }()

        let topActivities = activities
            .prefix(3)
            .map { "\($0.name) (\(Int($0.minutes)) min)" }
            .joined(separator: ", ")
        let activityText = topActivities.isEmpty ? "n/a" : topActivities

        return """
        Date range: last \(selectedRange.rawValue) days.
        Blood pressure latest: \(bpText)
        Blood glucose latest: \(latest(bloodGlucose)) mg/dL (avg \(avg(bloodGlucose)))
        SpO2 latest: \(latest(spo2))% (avg \(avg(spo2)))
        Heart rate latest: \(latest(heartRate)) bpm (avg \(avg(heartRate)))
        Sleep avg: \(avg(sleep)) hours
        Steps avg/day: \(avg(steps))
        Top activities: \(activityText)
        """
    }

    private func refreshFromManualOnly() {
        healthBloodPressure = []
        healthBloodGlucose = []
        healthSpO2 = []
        healthHeartRate = []
        healthSleep = []
        healthSteps = []
        healthActivities = []
        rebuildDisplayedData()
    }

    private var dateRange: DateInterval {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -selectedRange.rawValue, to: end) ?? end
        return DateInterval(start: start, end: end)
    }

    private func addImportedTimeValue(metric: MetricType, date: Date, value: Double) {
        let point = TimeValuePoint(date: date, value: value)
        switch metric {
        case .bloodGlucose:
            manualEntries.bloodGlucose.append(point)
        case .spo2:
            manualEntries.spo2.append(point)
        case .heartRate:
            manualEntries.heartRate.append(point)
        case .sleep:
            manualEntries.sleep.append(point)
        case .steps:
            manualEntries.steps.append(point)
        default:
            break
        }
    }

    private func persistAndRebuild() {
        do {
            try manualEntryStore.save(manualEntries)
            rebuildDisplayedData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildDisplayedData() {
        let range = dateRange

        bloodPressure = Self.aggregateBloodPressure(
            healthBloodPressure + manualEntries.bloodPressure.filter { range.contains($0.date) }
        )

        bloodGlucose = Self.aggregateTimeValues(
            healthBloodGlucose + manualEntries.bloodGlucose.filter { range.contains($0.date) },
            aggregation: .average
        )

        spo2 = Self.aggregateTimeValues(
            healthSpO2 + manualEntries.spo2.filter { range.contains($0.date) },
            aggregation: .average
        )

        heartRate = Self.aggregateTimeValues(
            healthHeartRate + manualEntries.heartRate.filter { range.contains($0.date) },
            aggregation: .average
        )

        sleep = Self.aggregateTimeValues(
            healthSleep + manualEntries.sleep.filter { range.contains($0.date) },
            aggregation: .average
        )

        steps = Self.aggregateTimeValues(
            healthSteps + manualEntries.steps.filter { range.contains($0.date) },
            aggregation: .sum
        )

        let manualActivityTotals = manualEntries.activities
            .filter { range.contains($0.date) }
            .reduce(into: [String: Double]()) { partialResult, entry in
                partialResult[entry.name, default: 0] += entry.minutes
            }

        var mergedActivities = Dictionary(uniqueKeysWithValues: healthActivities.map { ($0.name, $0.minutes) })
        for (name, minutes) in manualActivityTotals {
            mergedActivities[name, default: 0] += minutes
        }
        activities = mergedActivities
            .map { ActivityPoint(name: $0.key, minutes: $0.value) }
            .sorted { $0.minutes > $1.minutes }

        csvDocument = CSVExportDocument(content: buildCSV())
    }

    private func buildCSV() -> String {
        var lines: [String] = []

        lines.append("Blood Pressure")
        lines.append("date,systolic_mmhg,diastolic_mmhg")
        for row in bloodPressure {
            lines.append("\(row.date.csvDate),\(row.systolic.csvRounded),\(row.diastolic.csvRounded)")
        }

        lines.append("")
        lines.append("Blood Glucose")
        lines.append("date,glucose_mg_dL")
        for row in bloodGlucose {
            lines.append("\(row.date.csvDate),\(row.value.csvRounded)")
        }

        lines.append("")
        lines.append("SpO2")
        lines.append("date,spo2_percent")
        for row in spo2 {
            lines.append("\(row.date.csvDate),\(row.value.csvRounded)")
        }

        lines.append("")
        lines.append("Heart Rate")
        lines.append("date,bpm")
        for row in heartRate {
            lines.append("\(row.date.csvDate),\(row.value.csvRounded)")
        }

        lines.append("")
        lines.append("Sleep")
        lines.append("date,sleep_hours")
        for row in sleep {
            lines.append("\(row.date.csvDate),\(row.value.csvRounded)")
        }

        lines.append("")
        lines.append("Steps")
        lines.append("date,step_count")
        for row in steps {
            lines.append("\(row.date.csvDate),\(row.value.csvRounded)")
        }

        lines.append("")
        lines.append("Activities")
        lines.append("activity,total_minutes")
        for row in activities {
            lines.append("\(row.name.csvEscaped),\(row.minutes.csvRounded)")
        }

        return lines.joined(separator: "\n")
    }

    private static func parseDate(_ text: String) -> Date? {
        if let d = DateFormatter.csv.date(from: text) {
            return d
        }
        if let d = ISO8601DateFormatter().date(from: text) {
            return d
        }
        return nil
    }

    private static func aggregateBloodPressure(_ points: [BloodPressurePoint]) -> [BloodPressurePoint] {
        let grouped = Dictionary(grouping: points) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted().compactMap { date in
            guard let dayPoints = grouped[date], !dayPoints.isEmpty else { return nil }
            let systolic = dayPoints.map(\.systolic).reduce(0, +) / Double(dayPoints.count)
            let diastolic = dayPoints.map(\.diastolic).reduce(0, +) / Double(dayPoints.count)
            return BloodPressurePoint(date: date, systolic: systolic, diastolic: diastolic)
        }
    }

    private enum AggregateType {
        case average
        case sum
    }

    private static func aggregateTimeValues(_ points: [TimeValuePoint], aggregation: AggregateType) -> [TimeValuePoint] {
        let grouped = Dictionary(grouping: points) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted().compactMap { date in
            guard let dayPoints = grouped[date], !dayPoints.isEmpty else { return nil }
            let value: Double
            switch aggregation {
            case .average:
                value = dayPoints.map(\.value).reduce(0, +) / Double(dayPoints.count)
            case .sum:
                value = dayPoints.map(\.value).reduce(0, +)
            }
            return TimeValuePoint(date: date, value: value)
        }
    }
}

private enum CSVParser {
    static func splitCSVRow(_ row: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inQuotes = false

        for character in row {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }

        values.append(current.trimmingCharacters(in: .whitespaces))
        return values
    }
}

private extension Date {
    var csvDate: String {
        DateFormatter.csv.string(from: self)
    }
}

private extension Double {
    var csvRounded: String {
        String(format: "%.2f", self)
    }
}

private extension String {
    var csvEscaped: String {
        if contains(",") || contains("\"") {
            let escaped = replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return self
    }
}

private extension DateFormatter {
    static let csv: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
