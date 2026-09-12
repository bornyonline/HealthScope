import Foundation

final class UserProfileStore {
    private struct Envelope: Codable {
        let format: String
        let schemaVersion: Int
        let payload: UserProfile
    }

    private static let format = "healthscope.userProfile"
    private static let currentVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = baseDirectory.appendingPathComponent("user_profile.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> UserProfile {
        guard let data = try VersionedPersistence.dataIfPresent(at: fileURL) else {
            return UserProfile()
        }
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.format == Self.format else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard envelope.schemaVersion == Self.currentVersion else {
                throw PersistenceLoadError.unsupportedVersion(
                    store: "user profile",
                    version: envelope.schemaVersion
                )
            }
            return envelope.payload
        } catch let error as PersistenceLoadError {
            throw error
        } catch {
            throw PersistenceLoadError.corrupt(
                store: "user profile",
                backupAvailable: VersionedPersistence.backupExists(for: fileURL),
                underlying: error
            )
        }
    }

    func save(_ profile: UserProfile) throws {
        if let previous = try VersionedPersistence.dataIfPresent(at: fileURL),
           (try? decoder.decode(Envelope.self, from: previous)) == nil {
            throw PersistenceLoadError.corrupt(
                store: "user profile",
                backupAvailable: VersionedPersistence.backupExists(for: fileURL),
                underlying: CocoaError(.fileReadCorruptFile)
            )
        }
        let data = try encoder.encode(Envelope(
            format: Self.format,
            schemaVersion: Self.currentVersion,
            payload: profile
        ))
        try VersionedPersistence.removeBackup(for: fileURL)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
