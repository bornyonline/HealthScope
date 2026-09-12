import Foundation
import HealthKit

protocol HealthDataProviding {
    func isAvailable() -> Bool
    func requestAuthorization() async throws
    func requestProfileAuthorization() async throws
    func fetchProfileSnapshot() async throws -> HealthProfileSnapshot
    func supportsClinicalRecords() -> Bool
    func requestClinicalRecordsAuthorization() async throws
    func fetchClinicalRecordSummaries() async throws -> [ClinicalRecordSummary]
    func fetchBloodPressure(range: DateInterval) async throws -> [BloodPressurePoint]
    func fetchBloodGlucose(range: DateInterval) async throws -> [TimeValuePoint]
    func fetchSpO2(range: DateInterval) async throws -> [TimeValuePoint]
    func fetchHeartRate(range: DateInterval) async throws -> [TimeValuePoint]
    func fetchSleep(range: DateInterval) async throws -> [TimeValuePoint]
    func fetchSteps(range: DateInterval) async throws -> [TimeValuePoint]
    func fetchActivities(range: DateInterval) async throws -> [DatedActivityEntry]
}

final class HealthKitService: HealthDataProviding {
    private let store: HKHealthStore
    private let calendar: Calendar
    private let maximumClinicalRecordsPerType = 40
    private let maximumClinicalRecordsTotal = 100

    init(store: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async throws {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
    }

    func requestProfileAuthorization() async throws {
        try Task.checkCancellation()
        guard isAvailable() else {
            throw HealthProfileImportError.healthDataUnavailable
        }
        let readTypes = Set([
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth),
            HKObjectType.quantityType(forIdentifier: .height),
            HKObjectType.quantityType(forIdentifier: .bodyMass)
        ].compactMap { $0 as HKObjectType? })
        guard readTypes.count == 3 else {
            throw HealthProfileImportError.typesUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: HealthProfileImportError.authorizationIncomplete)
                }
            }
        }
        try Task.checkCancellation()
    }

    func fetchProfileSnapshot() async throws -> HealthProfileSnapshot {
        try Task.checkCancellation()
        async let height = fetchLatestQuantity(identifier: .height, unit: .meterUnit(with: .centi))
        async let weight = fetchLatestQuantity(identifier: .bodyMass, unit: .gramUnit(with: .kilo))

        let dateOfBirth: Date? = {
            guard let components = try? store.dateOfBirthComponents() else { return nil }
            return Calendar(identifier: .gregorian).date(from: components)
        }()
        let values = try await (height, weight)
        return HealthProfileSnapshot(
            dateOfBirth: dateOfBirth,
            heightCentimeters: values.0,
            weightKilograms: values.1
        )
    }

    func supportsClinicalRecords() -> Bool {
        isAvailable() && store.supportsHealthRecords()
    }

    func requestClinicalRecordsAuthorization() async throws {
        try Task.checkCancellation()
        guard supportsClinicalRecords() else {
            throw ClinicalRecordsError.unsupported
        }

        let definitions = clinicalTypeDefinitions
        guard definitions.count == ClinicalRecordCategory.allCases.count else {
            throw ClinicalRecordsError.typesUnavailable
        }
        let readTypes = Set(definitions.map { $0.type as HKObjectType })

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ClinicalRecordsError.authorizationIncomplete)
                }
            }
        }
        try Task.checkCancellation()
    }

    func fetchClinicalRecordSummaries() async throws -> [ClinicalRecordSummary] {
        try Task.checkCancellation()
        guard supportsClinicalRecords() else {
            throw ClinicalRecordsError.unsupported
        }

        var summaries: [ClinicalRecordSummary] = []
        for definition in clinicalTypeDefinitions {
            let records = try await fetchClinicalRecords(for: definition.type)
            summaries.append(contentsOf: Self.makeClinicalSummaries(records, category: definition.category))
        }

        return Array(
            summaries
                .sorted { $0.addedToHealthAt > $1.addedToHealthAt }
                .prefix(maximumClinicalRecordsTotal)
        )
    }

    func fetchBloodPressure(range: DateInterval) async throws -> [BloodPressurePoint] {
        guard let correlationType = HKObjectType.correlationType(forIdentifier: .bloodPressure),
              let systolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diastolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) else {
            return []
        }

        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let correlations: [HKCorrelation] = try await executeQuery { completion in
            HKSampleQuery(
                sampleType: correlationType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success((samples as? [HKCorrelation]) ?? []))
                }
            }
        }

        let unit = HKUnit.millimeterOfMercury()
        let pairsByDay = correlations.reduce(into: [Date: [(Double, Double)]]()) { result, correlation in
            guard correlation.startDate >= range.start, correlation.startDate < range.end else { return }
            let systolic = correlation.objects(for: systolicType)
                .compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: unit) }
            let diastolic = correlation.objects(for: diastolicType)
                .compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: unit) }
            guard !systolic.isEmpty, !diastolic.isEmpty else { return }

            let pair = (
                systolic.reduce(0, +) / Double(systolic.count),
                diastolic.reduce(0, +) / Double(diastolic.count)
            )
            result[calendar.startOfDay(for: correlation.startDate), default: []].append(pair)
        }

        return pairsByDay.keys.sorted().compactMap { date in
            guard let pairs = pairsByDay[date], !pairs.isEmpty else { return nil }
            return BloodPressurePoint(
                date: date,
                systolic: pairs.map(\.0).reduce(0, +) / Double(pairs.count),
                diastolic: pairs.map(\.1).reduce(0, +) / Double(pairs.count),
                source: .healthKit
            )
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
        let categorySamples: [HKCategorySample] = try await executeQuery { completion in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            return HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success((samples as? [HKCategorySample]) ?? []))
                }
            }
        }

        let clippedIntervals = categorySamples.compactMap { sample -> DateInterval? in
            guard Self.isAsleepValue(sample.value) else { return nil }
            let start = max(sample.startDate, range.start)
            let end = min(sample.endDate, range.end)
            guard start < end else { return nil }
            return DateInterval(start: start, end: end)
        }.sorted { $0.start < $1.start }

        var mergedIntervals: [DateInterval] = []
        for interval in clippedIntervals {
            if let previous = mergedIntervals.last, interval.start <= previous.end {
                mergedIntervals[mergedIntervals.count - 1] = DateInterval(
                    start: previous.start,
                    end: max(previous.end, interval.end)
                )
            } else {
                mergedIntervals.append(interval)
            }
        }

        let groupedHours = mergedIntervals.reduce(into: [Date: Double]()) { result, interval in
            let wakeDay = calendar.startOfDay(for: interval.end)
            guard wakeDay >= range.start, wakeDay < range.end else { return }
            result[wakeDay, default: 0] += interval.duration / 3600.0
        }

        return groupedHours.sortedByDate()
    }

    func fetchActivities(range: DateInterval) async throws -> [DatedActivityEntry] {
        let type = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)

        let workouts: [HKWorkout] = try await executeQuery { completion in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            return HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success((samples as? [HKWorkout]) ?? []))
                }
            }
        }

        return workouts.compactMap { workout in
            let start = max(workout.startDate, range.start)
            let end = min(workout.endDate, range.end)
            guard start < end else { return nil }
            return DatedActivityEntry(
                id: workout.uuid,
                date: start,
                name: workout.workoutActivityType.displayName,
                minutes: end.timeIntervalSince(start) / 60.0,
                source: .healthKit
            )
        }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
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

        let anchorDate = calendar.startOfDay(for: range.start)
        var interval = DateComponents()
        interval.day = 1

        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)

        return try await executeQuery { completion in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: option,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, collection, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: range.start, to: range.end) { stats, _ in
                    let day = self.calendar.startOfDay(for: stats.startDate)
                    guard day >= range.start, day < range.end else { return }
                    if option == .cumulativeSum, let quantity = stats.sumQuantity() {
                        values[day] = quantity.doubleValue(for: unit)
                    } else if let quantity = stats.averageQuantity() {
                        values[day] = quantity.doubleValue(for: unit)
                    }
                }

                completion(.success(values))
            }
            return query
        }
    }

    private func fetchLatestQuantity(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let samples: [HKQuantitySample] = try await executeQuery { completion in
            HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success((samples as? [HKQuantitySample]) ?? []))
                }
            }
        }
        return samples.first?.quantity.doubleValue(for: unit)
    }

    private struct ClinicalTypeDefinition {
        let category: ClinicalRecordCategory
        let type: HKClinicalType
    }

    private var clinicalTypeDefinitions: [ClinicalTypeDefinition] {
        let identifiers: [(ClinicalRecordCategory, HKClinicalTypeIdentifier)] = [
            (.allergy, .allergyRecord),
            (.condition, .conditionRecord),
            (.immunization, .immunizationRecord),
            (.labResult, .labResultRecord),
            (.medication, .medicationRecord),
            (.procedure, .procedureRecord),
            (.vitalSign, .vitalSignRecord)
        ]
        return identifiers.compactMap { category, identifier in
            guard let type = HKObjectType.clinicalType(forIdentifier: identifier) else { return nil }
            return ClinicalTypeDefinition(category: category, type: type)
        }
    }

    private func fetchClinicalRecords(for type: HKClinicalType) async throws -> [HKClinicalRecord] {
        let limit = maximumClinicalRecordsPerType
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await executeQuery { completion in
            HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success((samples as? [HKClinicalRecord]) ?? []))
                }
            }
        }
    }

    private static func makeClinicalSummaries(
        _ records: [HKClinicalRecord],
        category: ClinicalRecordCategory
    ) -> [ClinicalRecordSummary] {
        var seenResources = Set<String>()
        return records.compactMap { record in
            let resource = record.fhirResource
            if let resource {
                let key = [
                    record.sourceRevision.source.bundleIdentifier,
                    resource.resourceType.rawValue,
                    resource.identifier
                ].joined(separator: "|")
                guard seenResources.insert(key).inserted else { return nil }
            }

            let displayName = cleanClinicalText(record.displayName, maximumCharacters: 200)
            guard !displayName.isEmpty else { return nil }
            let details = resource.map { projectFHIR($0.data, category: category) } ?? []
            return ClinicalRecordSummary(
                category: category,
                displayName: displayName,
                details: Array(details.prefix(8)),
                addedToHealthAt: record.startDate
            )
        }
    }

    private static func projectFHIR(_ data: Data, category: ClinicalRecordCategory) -> [String] {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data),
              let resource = object as? [String: Any] else {
            return []
        }

        var details: [String] = []
        func append(_ label: String, _ value: String?) {
            guard let value else { return }
            let cleaned = cleanClinicalText(value, maximumCharacters: 200)
            guard !cleaned.isEmpty else { return }
            let detail = "\(label): \(cleaned)"
            guard !details.contains(detail) else { return }
            details.append(detail)
        }

        append("Status", scalarText(resource["status"]))

        switch category {
        case .allergy:
            append("Clinical status", codedText(resource["clinicalStatus"]))
            append("Criticality", scalarText(resource["criticality"]))
            append("Recorded", scalarText(resource["recordedDate"]))
            append("Reaction", reactionText(resource["reaction"]))
        case .condition:
            append("Clinical status", codedText(resource["clinicalStatus"]))
            append("Verification", codedText(resource["verificationStatus"]))
            append("Onset", firstScalar(in: resource, keys: ["onsetDateTime", "onsetString"]))
            append("Recorded", firstScalar(in: resource, keys: ["recordedDate", "assertedDate", "dateRecorded"]))
        case .immunization:
            append("Vaccine", codedText(resource["vaccineCode"]))
            append("Date", firstScalar(in: resource, keys: ["occurrenceDateTime", "date"]))
            append("Dose", quantityText(resource["doseQuantity"]))
            append("Route", codedText(resource["route"]))
        case .labResult, .vitalSign:
            append("Test", codedText(resource["code"]))
            append("Value", firstValue(in: resource))
            append("Interpretation", codedText(resource["interpretation"]))
            append("Reference range", referenceRangeText(resource["referenceRange"]))
            append("Effective", firstScalar(in: resource, keys: ["effectiveDateTime", "issued"]))
        case .medication:
            append("Medication", codedText(resource["medicationCodeableConcept"]))
            append("When authored", firstScalar(in: resource, keys: ["authoredOn", "dateAsserted", "whenPrepared", "whenHandedOver"]))
            append("Effective", periodText(resource["effectivePeriod"]))
        case .procedure:
            append("Procedure", codedText(resource["code"]))
            append("Performed", firstScalar(in: resource, keys: ["performedDateTime", "date"]))
            if details.count < 8 {
                append("Performed", periodText(resource["performedPeriod"]))
            }
        }

        return details
    }

    private static func firstValue(in resource: [String: Any]) -> String? {
        if let quantity = quantityText(resource["valueQuantity"]) { return quantity }
        for key in ["valueString", "valueCodeableConcept", "valueInteger", "valueDecimal", "valueBoolean"] {
            if let text = key == "valueCodeableConcept" ? codedText(resource[key]) : scalarText(resource[key]) {
                return text
            }
        }
        return nil
    }

    private static func codedText(_ value: Any?) -> String? {
        if let string = scalarText(value) { return string }
        if let array = value as? [Any] {
            for item in array {
                if let text = codedText(item) { return text }
            }
            return nil
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let text = scalarText(dictionary["text"]) { return text }
        if let display = scalarText(dictionary["display"]) { return display }
        if let coding = dictionary["coding"] as? [Any] {
            for item in coding {
                if let display = codedText(item) { return display }
            }
        }
        return scalarText(dictionary["code"])
    }

    private static func scalarText(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func quantityText(_ value: Any?) -> String? {
        guard let dictionary = value as? [String: Any],
              let amount = scalarText(dictionary["value"]) else { return nil }
        let unit = scalarText(dictionary["unit"]) ?? scalarText(dictionary["code"])
        return [amount, unit].compactMap { $0 }.joined(separator: " ")
    }

    private static func periodText(_ value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let start = scalarText(dictionary["start"])
        let end = scalarText(dictionary["end"])
        if let start, let end { return "\(start) to \(end)" }
        return start ?? end
    }

    private static func referenceRangeText(_ value: Any?) -> String? {
        guard let ranges = value as? [[String: Any]], let range = ranges.first else { return nil }
        let low = quantityText(range["low"])
        let high = quantityText(range["high"])
        if let low, let high { return "\(low) to \(high)" }
        return low ?? high ?? scalarText(range["text"])
    }

    private static func reactionText(_ value: Any?) -> String? {
        guard let reactions = value as? [[String: Any]], let reaction = reactions.first else { return nil }
        let manifestation = codedText(reaction["manifestation"])
        let severity = scalarText(reaction["severity"])
        return [manifestation, severity].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
    }

    private static func firstScalar(in resource: [String: Any], keys: [String]) -> String? {
        keys.compactMap { scalarText(resource[$0]) }.first
    }

    private static func cleanClinicalText(_ value: String, maximumCharacters: Int) -> String {
        let withoutDelimiters = value.replacingOccurrences(of: "<", with: " ")
            .replacingOccurrences(of: ">", with: " ")
        let components = withoutDelimiters.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return String(components.joined(separator: " ").prefix(maximumCharacters))
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

        let quantitySamples: [HKQuantitySample] = try await executeQuery { completion in
            HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success((samples as? [HKQuantitySample]) ?? []))
                }
            }
        }

        let inRangeSamples = quantitySamples.filter {
            $0.startDate >= range.start && $0.startDate < range.end
        }
        let grouped = Dictionary(grouping: inRangeSamples) {
            calendar.startOfDay(for: $0.startDate)
        }

        return grouped.reduce(into: [Date: Double]()) { partialResult, item in
            let values = item.value.map { $0.quantity.doubleValue(for: unit) }
            guard !values.isEmpty else { return }
            partialResult[item.key] = values.reduce(0, +) / Double(values.count)
        }
    }

    private func executeQuery<Value>(
        _ makeQuery: (@escaping (Result<Value, Error>) -> Void) -> HKQuery
    ) async throws -> Value {
        try Task.checkCancellation()
        let state = HealthQueryState<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let query = makeQuery { result in
                    state.finish(with: result)
                }
                guard state.install(query: query, continuation: continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                store.execute(query)
                if state.wasCancelled {
                    store.stop(query)
                }
            }
        } onCancel: {
            state.cancel(using: self.store)
        }
    }

    private static func isAsleepValue(_ value: Int) -> Bool {
        value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
    }
}

nonisolated enum ClinicalRecordsError: LocalizedError {
    case unsupported
    case typesUnavailable
    case authorizationIncomplete

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Clinical Health Records are not available on this device or in this region."
        case .typesUnavailable:
            return "The required Clinical Health Records types are unavailable."
        case .authorizationIncomplete:
            return "Clinical Health Records authorization did not complete."
        }
    }
}

nonisolated enum HealthProfileImportError: LocalizedError {
    case healthDataUnavailable
    case typesUnavailable
    case authorizationIncomplete

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Apple Health data is unavailable on this device."
        case .typesUnavailable:
            return "Apple Health profile types are unavailable."
        case .authorizationIncomplete:
            return "Apple Health profile authorization did not complete."
        }
    }
}

private nonisolated final class HealthQueryState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var query: HKQuery?
    private var isFinished = false
    private var isCancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func install(query: HKQuery, continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        self.query = query
        self.continuation = continuation
        return true
    }

    func finish(with result: Result<Value, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        query = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    func cancel(using store: HKHealthStore) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        isCancelled = true
        let continuation = continuation
        let query = query
        self.continuation = nil
        self.query = nil
        lock.unlock()

        if let query {
            store.stop(query)
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private extension Dictionary where Key == Date, Value == Double {
    func sortedByDate() -> [TimeValuePoint] {
        self.keys.sorted().compactMap { date in
            guard let value = self[date] else { return nil }
            return TimeValuePoint(date: date, value: value, source: .healthKit)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
