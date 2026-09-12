import Foundation

final class ManualEntryStore {
    private struct Envelope: Codable {
        let format: String
        let schemaVersion: Int
        let payload: ManualEntries
    }

    private static let format = "healthscope.manualEntries"
    private static let currentVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = baseDirectory.appendingPathComponent("manual_entries.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> ManualEntries {
        guard let data = try VersionedPersistence.dataIfPresent(at: fileURL) else {
            return ManualEntries()
        }

        do {
            switch try decode(data) {
            case .current(let entries):
                return entries
            case .legacy(let entries):
                // Persist generated identities and the envelope during the one-time migration.
                try save(entries)
                return entries
            }
        } catch let error as PersistenceLoadError {
            throw error
        } catch {
            throw PersistenceLoadError.corrupt(
                store: "manual entry",
                backupAvailable: VersionedPersistence.backupExists(for: fileURL),
                underlying: error
            )
        }
    }

    func save(_ entries: ManualEntries) throws {
        if let previous = try VersionedPersistence.dataIfPresent(at: fileURL),
           (try? decode(previous)) == nil {
            throw PersistenceLoadError.corrupt(
                store: "manual entry",
                backupAvailable: VersionedPersistence.backupExists(for: fileURL),
                underlying: CocoaError(.fileReadCorruptFile)
            )
        }
        let envelope = Envelope(
            format: Self.format,
            schemaVersion: Self.currentVersion,
            payload: entries
        )
        let data = try encoder.encode(envelope)
        try VersionedPersistence.saveAtomically(data, to: fileURL) { [self] previous in
            (try? decode(previous)) != nil
        }
    }

    private enum DecodedData {
        case current(ManualEntries)
        case legacy(ManualEntries)
    }

    private func decode(_ data: Data) throws -> DecodedData {
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.format == Self.format else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard envelope.schemaVersion == Self.currentVersion else {
                throw PersistenceLoadError.unsupportedVersion(
                    store: "manual entry",
                    version: envelope.schemaVersion
                )
            }
            return .current(envelope.payload)
        } catch let error as PersistenceLoadError {
            throw error
        } catch {
            if Self.hasEnvelopeMarker(data) {
                throw error
            }
        }

        return .legacy(try decoder.decode(ManualEntries.self, from: data))
    }

    private static func hasEnvelopeMarker(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["schemaVersion"] != nil || object["payload"] != nil || object["format"] != nil
    }
}
