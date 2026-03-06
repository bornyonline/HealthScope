import Foundation
import HealthKit

final class HealthKitService {
    private let store = HKHealthStore()

    func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async throws {
        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            HKObjectType.quantityType(forIdentifier: .bloodGlucose)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.workoutType()
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(domain: "HealthKitService", code: 1, userInfo: [NSLocalizedDescriptionKey: "HealthKit authorization was not granted."]))
                }
            }
        }
    }

    func fetchBloodPressure(range: DateInterval) async throws -> [BloodPressurePoint] {
        async let systolic = fetchDailyQuantityValues(identifier: .bloodPressureSystolic, unit: HKUnit.millimeterOfMercury(), option: .discreteAverage, range: range)
        async let diastolic = fetchDailyQuantityValues(identifier: .bloodPressureDiastolic, unit: HKUnit.millimeterOfMercury(), option: .discreteAverage, range: range)

        let systolicValues = try await systolic
        let diastolicValues = try await diastolic

        let allDates = Set(systolicValues.keys).union(diastolicValues.keys).sorted()
        return allDates.compactMap { date in
            guard let s = systolicValues[date], let d = diastolicValues[date] else {
                return nil
            }
            return BloodPressurePoint(date: date, systolic: s, diastolic: d)
        }
    }

    func fetchBloodGlucose(range: DateInterval) async throws -> [TimeValuePoint] {
        // HealthKit blood glucose samples are commonly stored as substance amount concentration.
        // Read in mmol/L (native compatible unit), then convert for UI display to mg/dL.
        let mmolPerL = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)
            .unitDivided(by: .liter())
        let statsValuesMMol = try await fetchDailyQuantityValues(
            identifier: .bloodGlucose,
            unit: mmolPerL,
            option: .discreteAverage,
            range: range
        )

        let valuesMMol: [Date: Double]
        if statsValuesMMol.isEmpty {
            valuesMMol = try await fetchDailyAverageFromSamples(
                identifier: .bloodGlucose,
                unit: mmolPerL,
                range: range
            )
        } else {
            valuesMMol = statsValuesMMol
        }

        let valuesMgDl = valuesMMol.mapValues { $0 * 18.01559 }
        return valuesMgDl.sortedByDate()
    }

    func fetchSpO2(range: DateInterval) async throws -> [TimeValuePoint] {
        let raw = try await fetchDailyQuantityValues(identifier: .oxygenSaturation, unit: .percent(), option: .discreteAverage, range: range)
        let scaled = raw.mapValues { $0 * 100.0 }
        return scaled.sortedByDate()
    }

    func fetchHeartRate(range: DateInterval) async throws -> [TimeValuePoint] {
        let unit = HKUnit.count().unitDivided(by: .minute())
        let values = try await fetchDailyQuantityValues(identifier: .heartRate, unit: unit, option: .discreteAverage, range: range)
        return values.sortedByDate()
    }

    func fetchSteps(range: DateInterval) async throws -> [TimeValuePoint] {
        let values = try await fetchDailyQuantityValues(identifier: .stepCount, unit: .count(), option: .cumulativeSum, range: range)
        return values.sortedByDate()
    }

    func fetchSleep(range: DateInterval) async throws -> [TimeValuePoint] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return []
        }

        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let categorySamples = (samples as? [HKCategorySample]) ?? []
                var groupedHours: [Date: Double] = [:]

                for sample in categorySamples where Self.isAsleepValue(sample.value) {
                    let day = Calendar.current.startOfDay(for: sample.startDate)
                    let durationHours = sample.endDate.timeIntervalSince(sample.startDate) / 3600.0
                    groupedHours[day, default: 0] += durationHours
                }

                continuation.resume(returning: groupedHours.sortedByDate())
            }

            self.store.execute(query)
        }
    }

    func fetchActivities(range: DateInterval) async throws -> [ActivityPoint] {
        let type = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                var minutesByActivity: [String: Double] = [:]

                for workout in workouts {
                    let name = workout.workoutActivityType.displayName
                    let minutes = workout.duration / 60.0
                    minutesByActivity[name, default: 0] += minutes
                }

                let points = minutesByActivity
                    .map { ActivityPoint(name: $0.key, minutes: $0.value) }
                    .sorted { $0.minutes > $1.minutes }

                continuation.resume(returning: points)
            }

            self.store.execute(query)
        }
    }

    private func fetchDailyQuantityValues(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        option: HKStatisticsOptions,
        range: DateInterval
    ) async throws -> [Date: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return [:]
        }

        let calendar = Calendar.current
        let anchorDate = calendar.startOfDay(for: range.start)
        var interval = DateComponents()
        interval.day = 1

        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: option,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: range.start, to: range.end) { stats, _ in
                    if option == .cumulativeSum, let quantity = stats.sumQuantity() {
                        values[calendar.startOfDay(for: stats.startDate)] = quantity.doubleValue(for: unit)
                    } else if let quantity = stats.averageQuantity() {
                        values[calendar.startOfDay(for: stats.startDate)] = quantity.doubleValue(for: unit)
                    }
                }

                continuation.resume(returning: values)
            }

            self.store.execute(query)
        }
    }

    private func fetchDailyAverageFromSamples(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        range: DateInterval
    ) async throws -> [Date: Double] {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return [:]
        }

        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                let grouped = Dictionary(grouping: quantitySamples) {
                    Calendar.current.startOfDay(for: $0.startDate)
                }

                let averages = grouped.reduce(into: [Date: Double]()) { partialResult, item in
                    let values = item.value.map { $0.quantity.doubleValue(for: unit) }
                    guard !values.isEmpty else { return }
                    partialResult[item.key] = values.reduce(0, +) / Double(values.count)
                }
                continuation.resume(returning: averages)
            }

            self.store.execute(query)
        }
    }

    private static func isAsleepValue(_ value: Int) -> Bool {
        value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
    }
}

private extension Dictionary where Key == Date, Value == Double {
    func sortedByDate() -> [TimeValuePoint] {
        self.keys.sorted().compactMap { date in
            guard let value = self[date] else { return nil }
            return TimeValuePoint(date: date, value: value)
        }
    }
}

private extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running:
            return "Running"
        case .boxing:
            return "Boxing"
        case .hiking:
            return "Rucking / Hiking"
        case .walking:
            return "Walking"
        case .functionalStrengthTraining:
            return "Functional Strength"
        default:
            return String(describing: self).replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        }
    }
}
