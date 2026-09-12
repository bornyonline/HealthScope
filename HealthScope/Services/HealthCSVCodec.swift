import Foundation

nonisolated enum HealthCSVRecord: Sendable {
    case bloodPressure(BloodPressurePoint)
    case timeValue(MetricType, TimeValuePoint)
    case activity(DatedActivityEntry)
}

nonisolated enum HealthCSVError: LocalizedError {
    case invalidUTF8
    case malformedCSV(String)
    case invalidSchema(metric: MetricType)
    case noValidRows(metric: MetricType, invalidRows: Int)
    case noNewRows(metric: MetricType)
    case invalidValue(metric: MetricType, reason: String)
    case fileTooLarge(maximumBytes: Int)
    case notRegularFile

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The CSV file must use UTF-8 encoding."
        case .malformedCSV(let reason):
            return "The CSV file is malformed: \(reason)"
        case .invalidSchema(let metric):
            return "The CSV schema does not match \(metric.title). Use a HealthScope export or the \(metric.title) sample-file schema."
        case .noValidRows(let metric, let invalidRows):
            let detail = invalidRows == 0 ? "" : " \(invalidRows) row(s) were invalid."
            return "No valid \(metric.title) rows were found.\(detail)"
        case .noNewRows(let metric):
            return "All valid \(metric.title) rows are already imported."
        case .invalidValue(let metric, let reason):
            return "Invalid \(metric.title) entry: \(reason)"
        case .fileTooLarge(let maximumBytes):
            return "The CSV file is too large. The maximum size is \(maximumBytes / 1_048_576) MB."
        case .notRegularFile:
            return "The selected CSV is not a regular file."
        }
    }
}

nonisolated enum HealthCSVCodec {
    static let schemaVersion = "1"

    private static let normalizedHeader = [
        "healthscope_version",
        "metric",
        "record_id",
        "date",
        "source",
        "value",
        "systolic_mmhg",
        "diastolic_mmhg",
        "activity"
    ]

    static func encode(
        bloodPressure: [BloodPressurePoint],
        bloodGlucose: [TimeValuePoint],
        spo2: [TimeValuePoint],
        heartRate: [TimeValuePoint],
        sleep: [TimeValuePoint],
        steps: [TimeValuePoint],
        activities: [DatedActivityEntry]
    ) -> String {
        var rows = [normalizedHeader]

        rows += bloodPressure.sorted(by: recordOrder).map { point in
            normalizedRow(
                metric: .bloodPressure,
                id: point.id,
                date: point.date,
                source: point.source,
                systolic: point.systolic,
                diastolic: point.diastolic
            )
        }
        rows += timeValueRows(.bloodGlucose, bloodGlucose)
        rows += timeValueRows(.spo2, spo2)
        rows += timeValueRows(.heartRate, heartRate)
        rows += timeValueRows(.sleep, sleep)
        rows += timeValueRows(.steps, steps)
        rows += activities.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }.map { entry in
            normalizedRow(
                metric: .activities,
                id: entry.id,
                date: entry.date,
                source: entry.source,
                value: entry.minutes,
                activity: entry.name
            )
        }

        return rows
            .map { $0.map(escape).joined(separator: ",") }
            .joined(separator: "\n")
    }

    static func decode(_ data: Data, selectedMetric: MetricType) throws -> [HealthCSVRecord] {
        let utf8BOM = Data([0xEF, 0xBB, 0xBF])
        let csvData = data.starts(with: utf8BOM) ? Data(data.dropFirst(utf8BOM.count)) : data
        guard var content = String(data: csvData, encoding: .utf8) else {
            throw HealthCSVError.invalidUTF8
        }
        if content.first == "\u{feff}" {
            content.removeFirst()
        }

        let parsedRows = try parse(content)
        let rows = parsedRows.filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard let header = rows.first else {
            throw HealthCSVError.noValidRows(metric: selectedMetric, invalidRows: 0)
        }

        if header == normalizedHeader {
            return try decodeNormalized(Array(rows.dropFirst()), selectedMetric: selectedMetric)
        }

        guard header == legacyHeader(for: selectedMetric) else {
            throw HealthCSVError.invalidSchema(metric: selectedMetric)
        }
        return try decodeLegacy(Array(rows.dropFirst()), selectedMetric: selectedMetric)
    }

    static func validateBloodPressure(systolic: Double, diastolic: Double) throws {
        guard systolic.isFinite, diastolic.isFinite,
              systolic > 0, diastolic > 0 else {
            throw HealthCSVError.invalidValue(metric: .bloodPressure, reason: "values must be finite and positive.")
        }
        guard (50...300).contains(systolic), (30...200).contains(diastolic), systolic > diastolic else {
            throw HealthCSVError.invalidValue(
                metric: .bloodPressure,
                reason: "use plausible pressure values (systolic 50-300, diastolic 30-200, systolic above diastolic)."
            )
        }
    }

    static func validateTimeValue(_ value: Double, metric: MetricType) throws {
        guard value.isFinite, value > 0 else {
            throw HealthCSVError.invalidValue(metric: metric, reason: "the value must be finite and positive.")
        }

        let range: ClosedRange<Double>
        switch metric {
        case .bloodGlucose: range = 20...1_000
        case .spo2: range = 1...100
        case .heartRate: range = 20...300
        case .sleep: range = 0.1...24
        case .steps: range = 1...200_000
        default:
            throw HealthCSVError.invalidValue(metric: metric, reason: "this metric does not accept a single numeric value.")
        }
        guard range.contains(value) else {
            throw HealthCSVError.invalidValue(metric: metric, reason: "the value is outside the plausible range \(range.lowerBound)-\(range.upperBound).")
        }
    }

    static func validateActivity(name: String, minutes: Double) throws -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 200 else {
            throw HealthCSVError.invalidValue(metric: .activities, reason: "the activity name must contain 1-200 characters.")
        }
        guard minutes.isFinite, minutes > 0, minutes <= 1_440 else {
            throw HealthCSVError.invalidValue(metric: .activities, reason: "minutes must be finite and between 0 and 1,440.")
        }
        return normalizedName
    }

    private static func decodeNormalized(
        _ rows: [[String]],
        selectedMetric: MetricType
    ) throws -> [HealthCSVRecord] {
        var records: [HealthCSVRecord] = []
        var invalidRows = 0

        for columns in rows {
            guard columns.count == normalizedHeader.count,
                  columns[0] == schemaVersion,
                  let rowMetric = MetricType(rawValue: columns[1]) else {
                invalidRows += 1
                continue
            }
            guard rowMetric == selectedMetric else { continue }

            do {
                guard let id = UUID(uuidString: columns[2]),
                      HealthDataSource(rawValue: columns[4]) != nil,
                      let date = parseNormalizedDate(columns[3]) else {
                    throw HealthCSVError.malformedCSV("invalid identity, source, or date")
                }
                records.append(try makeRecord(
                    metric: rowMetric,
                    id: id,
                    date: date,
                    value: columns[5],
                    systolic: columns[6],
                    diastolic: columns[7],
                    activity: columns[8]
                ))
            } catch {
                invalidRows += 1
            }
        }

        guard !records.isEmpty else {
            throw HealthCSVError.noValidRows(metric: selectedMetric, invalidRows: invalidRows)
        }
        return records
    }

    private static func decodeLegacy(
        _ rows: [[String]],
        selectedMetric: MetricType
    ) throws -> [HealthCSVRecord] {
        var records: [HealthCSVRecord] = []
        var invalidRows = 0

        for columns in rows {
            do {
                guard columns.count == legacyHeader(for: selectedMetric).count else {
                    throw HealthCSVError.malformedCSV("wrong column count")
                }
                guard let date = parseLegacyDate(columns[0]) else {
                    throw HealthCSVError.malformedCSV("date must use yyyy-MM-dd")
                }

                switch selectedMetric {
                case .bloodPressure:
                    records.append(try makeRecord(
                        metric: selectedMetric,
                        id: UUID(),
                        date: date,
                        value: "",
                        systolic: columns[1],
                        diastolic: columns[2],
                        activity: ""
                    ))
                case .activities:
                    records.append(try makeRecord(
                        metric: selectedMetric,
                        id: UUID(),
                        date: date,
                        value: columns[2],
                        systolic: "",
                        diastolic: "",
                        activity: columns[1]
                    ))
                default:
                    records.append(try makeRecord(
                        metric: selectedMetric,
                        id: UUID(),
                        date: date,
                        value: columns[1],
                        systolic: "",
                        diastolic: "",
                        activity: ""
                    ))
                }
            } catch {
                invalidRows += 1
            }
        }

        guard !records.isEmpty else {
            throw HealthCSVError.noValidRows(metric: selectedMetric, invalidRows: invalidRows)
        }
        return records
    }

    private static func makeRecord(
        metric: MetricType,
        id: UUID,
        date: Date,
        value: String,
        systolic: String,
        diastolic: String,
        activity: String
    ) throws -> HealthCSVRecord {
        switch metric {
        case .bloodPressure:
            guard value.isEmpty, activity.isEmpty,
                  let systolicValue = strictDouble(systolic),
                  let diastolicValue = strictDouble(diastolic) else {
                throw HealthCSVError.invalidValue(metric: metric, reason: "invalid pressure columns.")
            }
            try validateBloodPressure(systolic: systolicValue, diastolic: diastolicValue)
            return .bloodPressure(BloodPressurePoint(
                id: id,
                date: date,
                systolic: systolicValue,
                diastolic: diastolicValue,
                source: .csvImport
            ))

        case .activities:
            guard systolic.isEmpty, diastolic.isEmpty,
                  let minutes = strictDouble(value) else {
                throw HealthCSVError.invalidValue(metric: metric, reason: "invalid activity columns.")
            }
            let name = try validateActivity(name: activity, minutes: minutes)
            return .activity(DatedActivityEntry(
                id: id,
                date: date,
                name: name,
                minutes: minutes,
                source: .csvImport
            ))

        default:
            guard systolic.isEmpty, diastolic.isEmpty, activity.isEmpty,
                  let numericValue = strictDouble(value) else {
                throw HealthCSVError.invalidValue(metric: metric, reason: "invalid value columns.")
            }
            try validateTimeValue(numericValue, metric: metric)
            return .timeValue(metric, TimeValuePoint(
                id: id,
                date: date,
                value: numericValue,
                source: .csvImport
            ))
        }
    }

    private static func timeValueRows(_ metric: MetricType, _ points: [TimeValuePoint]) -> [[String]] {
        points.sorted(by: recordOrder).map { point in
            normalizedRow(
                metric: metric,
                id: point.id,
                date: point.date,
                source: point.source,
                value: point.value
            )
        }
    }

    private static func normalizedRow(
        metric: MetricType,
        id: UUID,
        date: Date,
        source: HealthDataSource,
        value: Double? = nil,
        systolic: Double? = nil,
        diastolic: Double? = nil,
        activity: String = ""
    ) -> [String] {
        [
            schemaVersion,
            metric.rawValue,
            id.uuidString.lowercased(),
            normalizedDateFormatter().string(from: date),
            source.rawValue,
            value.map(number) ?? "",
            systolic.map(number) ?? "",
            diastolic.map(number) ?? "",
            activity
        ]
    }

    private static func legacyHeader(for metric: MetricType) -> [String] {
        switch metric {
        case .bloodPressure: return ["date", "systolic_mmhg", "diastolic_mmhg"]
        case .bloodGlucose: return ["date", "glucose_mg_dL"]
        case .spo2: return ["date", "spo2_percent"]
        case .heartRate: return ["date", "bpm"]
        case .sleep: return ["date", "sleep_hours"]
        case .steps: return ["date", "step_count"]
        case .activities: return ["date", "activity", "total_minutes"]
        }
    }

    private static func strictDouble(_ text: String) -> Double? {
        guard !text.isEmpty,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text), value.isFinite else {
            return nil
        }
        return value
    }

    private static func parseNormalizedDate(_ text: String) -> Date? {
        let formatter = normalizedDateFormatter()
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            return nil
        }
        return date
    }

    private static func parseLegacyDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            return nil
        }
        return date
    }

    private static func normalizedDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        formatter.isLenient = false
        return formatter
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func recordOrder(_ lhs: TimeValuePoint, _ rhs: TimeValuePoint) -> Bool {
        lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date < rhs.date
    }

    private static func recordOrder(_ lhs: BloodPressurePoint, _ rhs: BloodPressurePoint) -> Bool {
        lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date < rhs.date
    }

    private static func parse(_ content: String) throws -> [[String]] {
        let characters = Array(content)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var index = 0

        func completedField() -> String {
            fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespaces)
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    guard field.isEmpty, !fieldWasQuoted else {
                        throw HealthCSVError.malformedCSV("unexpected quote")
                    }
                    inQuotes = true
                    fieldWasQuoted = true
                case ",":
                    row.append(completedField())
                    field = ""
                    fieldWasQuoted = false
                case "\n", "\r", "\r\n":
                    row.append(completedField())
                    rows.append(row)
                    row = []
                    field = ""
                    fieldWasQuoted = false
                    if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                default:
                    guard !fieldWasQuoted else {
                        throw HealthCSVError.malformedCSV("characters after a closing quote")
                    }
                    field.append(character)
                }
            }
            index += 1
        }

        guard !inQuotes else {
            throw HealthCSVError.malformedCSV("unterminated quoted field")
        }
        if !field.isEmpty || fieldWasQuoted || !row.isEmpty {
            row.append(completedField())
            rows.append(row)
        }
        return rows
    }
}
