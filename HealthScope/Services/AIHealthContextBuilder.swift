import Foundation

nonisolated struct AIHealthContextInput: Sendable {
    let range: DateInterval
    let expectedDays: Int
    let timeZone: TimeZone
    let measurementSystem: MeasurementSystemPreference
    let bloodPressure: [BloodPressurePoint]
    let bloodGlucose: [TimeValuePoint]
    let spo2: [TimeValuePoint]
    let heartRate: [TimeValuePoint]
    let sleep: [TimeValuePoint]
    let steps: [TimeValuePoint]
    let activities: [DatedActivityEntry]
}

nonisolated enum AIHealthContextBuilder {
    static let maximumActivitySessions = 250
    static let maximumActivitySessionBytes = 12_000
    static let maximumActivityTypes = 50

    static func build(_ input: AIHealthContextInput) -> String {
        let dailyDateFormatter = DateFormatter()
        dailyDateFormatter.calendar = Calendar(identifier: .gregorian)
        dailyDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dailyDateFormatter.timeZone = input.timeZone
        dailyDateFormatter.dateFormat = "yyyy-MM-dd"

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.timeZone = input.timeZone
        timestampFormatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        func rounded(_ value: Double) -> Double {
            (value * 100).rounded() / 100
        }

        func datedValues(_ points: [TimeValuePoint], transform: (Double) -> Double = { $0 }) -> [DatedValue] {
            points
                .filter { $0.value.isFinite && $0.date >= input.range.start && $0.date < input.range.end }
                .sorted { $0.date < $1.date }
                .suffix(input.expectedDays)
                .map { DatedValue(date: dailyDateFormatter.string(from: $0.date), value: rounded(transform($0.value))) }
        }

        func metric(
            _ points: [TimeValuePoint],
            unit: String,
            semantics: String,
            transform: (Double) -> Double = { $0 }
        ) -> MetricSeries {
            let values = datedValues(points, transform: transform)
            let average = values.isEmpty
                ? nil
                : rounded(values.map(\.value).reduce(0, +) / Double(values.count))
            return MetricSeries(
                unit: unit,
                dailyValueSemantics: semantics,
                expectedDays: input.expectedDays,
                observedDays: values.count,
                averageAcrossObservedDays: average,
                latest: values.last,
                values: values
            )
        }

        let pressureValues = input.bloodPressure
            .filter {
                $0.systolic.isFinite && $0.diastolic.isFinite
                    && $0.date >= input.range.start && $0.date < input.range.end
            }
            .sorted { $0.date < $1.date }
            .suffix(input.expectedDays)
            .map {
                DatedBloodPressure(
                    date: dailyDateFormatter.string(from: $0.date),
                    systolic: rounded($0.systolic),
                    diastolic: rounded($0.diastolic)
                )
            }

        let validActivities = input.activities
            .filter {
                $0.minutes.isFinite && $0.minutes > 0
                    && $0.date >= input.range.start && $0.date < input.range.end
            }
            .sorted {
                $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
            }
        let allActivitySessions = validActivities.map {
            ActivitySession(
                timestamp: timestampFormatter.string(from: $0.date),
                name: $0.name,
                minutes: rounded($0.minutes),
                source: $0.source.rawValue
            )
        }

        var includedActivitySessions: [ActivitySession] = []
        var activityByteCount = 0
        for session in allActivitySessions.reversed() {
            guard includedActivitySessions.count < maximumActivitySessions else { break }
            guard let encoded = try? encoder.encode(session),
                  activityByteCount + encoded.count <= maximumActivitySessionBytes else {
                continue
            }
            includedActivitySessions.append(session)
            activityByteCount += encoded.count
        }
        includedActivitySessions.reverse()

        var activityMinutesByName: [String: Double] = [:]
        var activityCountByName: [String: Int] = [:]
        for activity in validActivities {
            activityMinutesByName[activity.name, default: 0] += activity.minutes
            activityCountByName[activity.name, default: 0] += 1
        }
        var allActivityTotals: [ActivityTotal] = []
        for (name, minutes) in activityMinutesByName {
            allActivityTotals.append(ActivityTotal(
                name: name,
                sessionCount: activityCountByName[name, default: 0],
                totalMinutes: rounded(minutes)
            ))
        }
        allActivityTotals.sort {
            $0.totalMinutes == $1.totalMinutes ? $0.name < $1.name : $0.totalMinutes > $1.totalMinutes
        }
        let activityTotals = Array(allActivityTotals.prefix(maximumActivityTypes))

        let glucoseTransform: (Double) -> Double = {
            input.measurementSystem.displayGlucose(fromMilligramsPerDeciliter: $0)
        }
        let context = HealthContext(
            schemaVersion: 1,
            range: ContextRange(
                startDate: dailyDateFormatter.string(from: input.range.start),
                endDateExclusive: dailyDateFormatter.string(from: input.range.end),
                expectedDays: input.expectedDays,
                timeZone: input.timeZone.identifier
            ),
            missingDataSemantics: "A missing date means no observation was supplied; it is not a zero value.",
            bloodPressure: BloodPressureSeries(
                unit: "mmHg",
                dailyValueSemantics: "Average of supplied readings for each calendar day.",
                expectedDays: input.expectedDays,
                observedDays: pressureValues.count,
                latest: pressureValues.last,
                values: pressureValues
            ),
            bloodGlucose: metric(
                input.bloodGlucose,
                unit: input.measurementSystem.glucoseUnit,
                semantics: "Average of supplied readings for each calendar day.",
                transform: glucoseTransform
            ),
            spo2: metric(
                input.spo2,
                unit: "%",
                semantics: "Average of supplied readings for each calendar day."
            ),
            heartRate: metric(
                input.heartRate,
                unit: "bpm",
                semantics: "Average of supplied readings for each calendar day."
            ),
            sleep: metric(
                input.sleep,
                unit: "hours",
                semantics: "Asleep duration attributed to the calendar day on which sleep ended."
            ),
            steps: metric(
                input.steps,
                unit: "count",
                semantics: "Total supplied steps for each calendar day."
            ),
            activities: ActivitySeries(
                availableSessionCount: allActivitySessions.count,
                includedSessionCount: includedActivitySessions.count,
                sessionsTruncated: includedActivitySessions.count < allActivitySessions.count,
                availableTypeCount: allActivityTotals.count,
                includedTypeCount: activityTotals.count,
                typesTruncated: activityTotals.count < allActivityTotals.count,
                totalsByType: activityTotals,
                sessions: includedActivitySessions
            )
        )

        guard let data = try? encoder.encode(context),
              let json = String(data: data, encoding: .utf8) else {
            return "<health-context>{\"error\":\"Health context could not be encoded.\"}</health-context>"
        }
        return "<health-context>\n\(json)\n</health-context>"
    }
}

private extension AIHealthContextBuilder {
    nonisolated struct HealthContext: Encodable {
        let schemaVersion: Int
        let range: ContextRange
        let missingDataSemantics: String
        let bloodPressure: BloodPressureSeries
        let bloodGlucose: MetricSeries
        let spo2: MetricSeries
        let heartRate: MetricSeries
        let sleep: MetricSeries
        let steps: MetricSeries
        let activities: ActivitySeries
    }

    nonisolated struct ContextRange: Encodable {
        let startDate: String
        let endDateExclusive: String
        let expectedDays: Int
        let timeZone: String
    }

    nonisolated struct DatedValue: Encodable {
        let date: String
        let value: Double
    }

    nonisolated struct MetricSeries: Encodable {
        let unit: String
        let dailyValueSemantics: String
        let expectedDays: Int
        let observedDays: Int
        let averageAcrossObservedDays: Double?
        let latest: DatedValue?
        let values: [DatedValue]
    }

    nonisolated struct DatedBloodPressure: Encodable {
        let date: String
        let systolic: Double
        let diastolic: Double
    }

    nonisolated struct BloodPressureSeries: Encodable {
        let unit: String
        let dailyValueSemantics: String
        let expectedDays: Int
        let observedDays: Int
        let latest: DatedBloodPressure?
        let values: [DatedBloodPressure]
    }

    nonisolated struct ActivitySession: Encodable {
        let timestamp: String
        let name: String
        let minutes: Double
        let source: String
    }

    nonisolated struct ActivityTotal: Encodable {
        let name: String
        let sessionCount: Int
        let totalMinutes: Double
    }

    nonisolated struct ActivitySeries: Encodable {
        let availableSessionCount: Int
        let includedSessionCount: Int
        let sessionsTruncated: Bool
        let availableTypeCount: Int
        let includedTypeCount: Int
        let typesTruncated: Bool
        let totalsByType: [ActivityTotal]
        let sessions: [ActivitySession]
    }
}
