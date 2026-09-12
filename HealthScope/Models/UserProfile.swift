import Foundation
import Combine

nonisolated func parseLocalizedDecimal(_ text: String, locale: Locale = .current) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.isLenient = false
    return formatter.number(from: trimmed)?.doubleValue
}

nonisolated enum MeasurementSystemPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case metric
    case imperial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        }
    }

    func displayGlucose(fromMilligramsPerDeciliter value: Double) -> Double {
        self == .metric ? value / 18.01559 : value
    }

    func canonicalGlucose(fromDisplayValue value: Double) -> Double {
        self == .metric ? value * 18.01559 : value
    }

    var glucoseUnit: String {
        self == .metric ? "mmol/L" : "mg/dL"
    }

    func displayWeight(fromKilograms value: Double) -> Double {
        self == .metric ? value : value * 2.2046226218
    }

    func kilograms(fromDisplayWeight value: Double) -> Double {
        self == .metric ? value : value / 2.2046226218
    }
}

nonisolated struct UserProfile: Codable, Sendable {
    var name: String = ""
    var dateOfBirth: Date?
    var heightCentimeters: Double?
    var weightKilograms: Double?
    var photoData: Data?
}

nonisolated struct HealthProfileSnapshot: Sendable {
    let dateOfBirth: Date?
    let heightCentimeters: Double?
    let weightKilograms: Double?
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var measurementSystem: MeasurementSystemPreference {
        didSet {
            userDefaults.set(measurementSystem.rawValue, forKey: Self.measurementSystemKey)
        }
    }

    private static let measurementSystemKey = "measurement_system"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard, locale: Locale = .current) {
        self.userDefaults = userDefaults
        if let rawValue = userDefaults.string(forKey: Self.measurementSystemKey),
           let stored = MeasurementSystemPreference(rawValue: rawValue) {
            measurementSystem = stored
        } else {
            measurementSystem = locale.measurementSystem == .metric ? .metric : .imperial
        }
    }
}
