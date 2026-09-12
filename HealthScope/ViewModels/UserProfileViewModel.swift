import Foundation
import Combine

@MainActor
final class UserProfileViewModel: ObservableObject {
    @Published private(set) var profile: UserProfile
    @Published var errorMessage: String?
    @Published private(set) var isImportingFromHealth = false

    private let store: UserProfileStore
    private let healthService: any HealthDataProviding

    init(store: UserProfileStore, healthService: any HealthDataProviding) {
        self.store = store
        self.healthService = healthService
        do {
            profile = try store.load()
        } catch {
            profile = UserProfile()
            errorMessage = error.localizedDescription
        }
    }

    convenience init() {
        self.init(store: UserProfileStore(), healthService: HealthKitService())
    }

    func save(_ candidate: UserProfile) -> Bool {
        do {
            try validate(candidate)
            try store.save(candidate)
            profile = candidate
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func importFromHealth(into baseProfile: UserProfile) async -> UserProfile? {
        guard !isImportingFromHealth else { return nil }
        isImportingFromHealth = true
        defer { isImportingFromHealth = false }

        do {
            try validate(baseProfile)
            try await healthService.requestProfileAuthorization()
            let snapshot = try await healthService.fetchProfileSnapshot()
            var candidate = baseProfile
            if let dateOfBirth = snapshot.dateOfBirth {
                candidate.dateOfBirth = dateOfBirth
            }
            if let height = snapshot.heightCentimeters {
                candidate.heightCentimeters = height
            }
            if let weight = snapshot.weightKilograms {
                candidate.weightKilograms = weight
            }
            try validate(candidate)
            errorMessage = nil
            return candidate
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func validate(_ candidate: UserProfile) throws {
        let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 120 else {
            throw UserProfileError.invalidName
        }
        if let dateOfBirth = candidate.dateOfBirth, dateOfBirth > Date() {
            throw UserProfileError.invalidDateOfBirth
        }
        if let height = candidate.heightCentimeters,
           (!height.isFinite || !(30...300).contains(height)) {
            throw UserProfileError.invalidHeight
        }
        if let weight = candidate.weightKilograms,
           (!weight.isFinite || !(1...700).contains(weight)) {
            throw UserProfileError.invalidWeight
        }
        if let photoData = candidate.photoData, photoData.count > 2 * 1_048_576 {
            throw UserProfileError.photoTooLarge
        }
    }
}

nonisolated enum UserProfileError: LocalizedError {
    case invalidName
    case invalidDateOfBirth
    case invalidHeight
    case invalidWeight
    case photoTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Name must be at most 120 characters."
        case .invalidDateOfBirth: return "Date of birth cannot be in the future."
        case .invalidHeight: return "Enter a plausible height."
        case .invalidWeight: return "Enter a plausible weight."
        case .photoTooLarge: return "The selected profile photo is too large."
        }
    }
}
