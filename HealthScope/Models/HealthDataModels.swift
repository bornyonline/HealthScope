import Foundation

nonisolated enum DateRangeOption: Int, CaseIterable, Identifiable {
    case days7 = 7
    case days30 = 30
    case days90 = 90

    var id: Int { rawValue }

    var title: String {
        "\(rawValue)d"
    }
}

nonisolated enum MetricType: String, CaseIterable, Identifiable, Sendable {
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

nonisolated enum HealthDataSource: String, Codable, Hashable, Sendable {
    case healthKit
    case manual
    case csvImport
    case derived
}

nonisolated struct TimeValuePoint: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let value: Double
    let source: HealthDataSource

    init(
        id: UUID = UUID(),
        date: Date,
        value: Double,
        source: HealthDataSource = .healthKit
    ) {
        self.id = id
        self.date = date
        self.value = value
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, value, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        value = try container.decode(Double.self, forKey: .value)
        source = try container.decodeIfPresent(HealthDataSource.self, forKey: .source) ?? .manual
    }
}

nonisolated struct BloodPressurePoint: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let systolic: Double
    let diastolic: Double
    let source: HealthDataSource

    init(
        id: UUID = UUID(),
        date: Date,
        systolic: Double,
        diastolic: Double,
        source: HealthDataSource = .healthKit
    ) {
        self.id = id
        self.date = date
        self.systolic = systolic
        self.diastolic = diastolic
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, systolic, diastolic, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        systolic = try container.decode(Double.self, forKey: .systolic)
        diastolic = try container.decode(Double.self, forKey: .diastolic)
        source = try container.decodeIfPresent(HealthDataSource.self, forKey: .source) ?? .manual
    }
}

nonisolated struct ActivityPoint: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let minutes: Double

    var id: String { name }
}

nonisolated enum ClinicalRecordCategory: String, CaseIterable, Sendable {
    case allergy
    case condition
    case immunization
    case labResult
    case medication
    case procedure
    case vitalSign

    var title: String {
        switch self {
        case .allergy: return "Allergy"
        case .condition: return "Condition"
        case .immunization: return "Immunization"
        case .labResult: return "Lab Result"
        case .medication: return "Medication"
        case .procedure: return "Procedure"
        case .vitalSign: return "Vital Sign"
        }
    }
}

nonisolated struct ClinicalRecordSummary: Sendable {
    let category: ClinicalRecordCategory
    let displayName: String
    let details: [String]
    let addedToHealthAt: Date
}

nonisolated struct DatedActivityEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let name: String
    let minutes: Double
    let source: HealthDataSource

    init(
        id: UUID = UUID(),
        date: Date,
        name: String,
        minutes: Double,
        source: HealthDataSource = .manual
    ) {
        self.id = id
        self.date = date
        self.name = name
        self.minutes = minutes
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, name, minutes, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        name = try container.decode(String.self, forKey: .name)
        minutes = try container.decode(Double.self, forKey: .minutes)
        source = try container.decodeIfPresent(HealthDataSource.self, forKey: .source) ?? .manual
    }
}

nonisolated struct ManualEntries: Codable, Sendable {
    var bloodPressure: [BloodPressurePoint] = []
    var bloodGlucose: [TimeValuePoint] = []
    var spo2: [TimeValuePoint] = []
    var heartRate: [TimeValuePoint] = []
    var sleep: [TimeValuePoint] = []
    var steps: [TimeValuePoint] = []
    var activities: [DatedActivityEntry] = []

    init(
        bloodPressure: [BloodPressurePoint] = [],
        bloodGlucose: [TimeValuePoint] = [],
        spo2: [TimeValuePoint] = [],
        heartRate: [TimeValuePoint] = [],
        sleep: [TimeValuePoint] = [],
        steps: [TimeValuePoint] = [],
        activities: [DatedActivityEntry] = []
    ) {
        self.bloodPressure = bloodPressure
        self.bloodGlucose = bloodGlucose
        self.spo2 = spo2
        self.heartRate = heartRate
        self.sleep = sleep
        self.steps = steps
        self.activities = activities
    }

    private enum CodingKeys: String, CodingKey {
        case bloodPressure, bloodGlucose, spo2, heartRate, sleep, steps, activities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bloodPressure = try container.decodeIfPresent([BloodPressurePoint].self, forKey: .bloodPressure) ?? []
        bloodGlucose = try container.decodeIfPresent([TimeValuePoint].self, forKey: .bloodGlucose) ?? []
        spo2 = try container.decodeIfPresent([TimeValuePoint].self, forKey: .spo2) ?? []
        heartRate = try container.decodeIfPresent([TimeValuePoint].self, forKey: .heartRate) ?? []
        sleep = try container.decodeIfPresent([TimeValuePoint].self, forKey: .sleep) ?? []
        steps = try container.decodeIfPresent([TimeValuePoint].self, forKey: .steps) ?? []
        activities = try container.decodeIfPresent([DatedActivityEntry].self, forKey: .activities) ?? []
    }
}
