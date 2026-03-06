import Foundation

enum DateRangeOption: Int, CaseIterable, Identifiable {
    case days7 = 7
    case days30 = 30
    case days90 = 90

    var id: Int { rawValue }

    var title: String {
        "\(rawValue)d"
    }
}

enum MetricType: String, CaseIterable, Identifiable {
    case bloodPressure
    case bloodGlucose
    case spo2
    case heartRate
    case sleep
    case steps
    case activities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bloodPressure: return "Blood Pressure"
        case .bloodGlucose: return "Blood Glucose"
        case .spo2: return "SpO2"
        case .heartRate: return "Heart Rate"
        case .sleep: return "Sleep Pattern"
        case .steps: return "Steps"
        case .activities: return "Activities"
        }
    }
}

struct TimeValuePoint: Identifiable, Codable, Hashable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct BloodPressurePoint: Identifiable, Codable, Hashable {
    let date: Date
    let systolic: Double
    let diastolic: Double

    var id: Date { date }
}

struct ActivityPoint: Identifiable, Codable, Hashable {
    let name: String
    let minutes: Double

    var id: String { name }
}

struct DatedActivityEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let name: String
    let minutes: Double

    init(id: UUID = UUID(), date: Date, name: String, minutes: Double) {
        self.id = id
        self.date = date
        self.name = name
        self.minutes = minutes
    }
}

struct ManualEntries: Codable {
    var bloodPressure: [BloodPressurePoint] = []
    var bloodGlucose: [TimeValuePoint] = []
    var spo2: [TimeValuePoint] = []
    var heartRate: [TimeValuePoint] = []
    var sleep: [TimeValuePoint] = []
    var steps: [TimeValuePoint] = []
    var activities: [DatedActivityEntry] = []
}
