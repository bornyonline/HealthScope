import Foundation

final class ConversationStore {
    private struct Envelope: Codable {
        let format: String
        let schemaVersion: Int
        let payload: [ChatMessage]
    }

    private static let format = "healthscope.conversation"
    private static let currentVersion = 2

    private let fileURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let ioQueue = DispatchQueue(label: "ConversationStore.IO", qos: .utility)

    private(set) var loadError: Error?

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = baseDirectory.appendingPathComponent("analysis_chat_history.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    // Kept for AnalysisChatViewModel compatibility. Callers that can present load
    // failures immediately should use loadThrowing().
    func load() -> [ChatMessage] {
        do {
            let messages = try loadThrowing()
            loadError = nil
            return messages
        } catch {
            loadError = error
            return []
        }
    }

    func loadThrowing() throws -> [ChatMessage] {
        guard let data = try VersionedPersistence.dataIfPresent(at: fileURL) else {
            return []
        }

        do {
            switch try decode(data) {
            case .current(let messages):
                return messages
            case .legacy(let messages):
                try save(messages)
                return messages
            }
        } catch let error as PersistenceLoadError {
            throw error
        } catch {
            throw PersistenceLoadError.corrupt(
                store: "conversation history",
                backupAvailable: VersionedPersistence.backupExists(for: fileURL),
                underlying: error
            )
        }
    }

    func save(_ messages: [ChatMessage]) throws {
        try ioQueue.sync {
            try saveNow(messages)
        }
    }

    func saveAsync(_ messages: [ChatMessage], completion: @escaping (Error?) -> Void) {
        // The serial queue preserves submission order so an older snapshot cannot
        // overwrite a newer conversation.
        ioQueue.async { [self] in
            do {
                try saveNow(messages)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private enum DecodedData {
        case current([ChatMessage])
        case legacy([ChatMessage])
    }

    private func saveNow(_ messages: [ChatMessage]) throws {
        if let previous = try VersionedPersistence.dataIfPresent(at: fileURL),
           (try? decode(previous)) == nil {
            throw PersistenceLoadError.corrupt(
                store: "conversation history",
                backupAvailable: VersionedPersistence.backupExists(for: fileURL),
                underlying: CocoaError(.fileReadCorruptFile)
            )
        }
        let envelope = Envelope(
            format: Self.format,
            schemaVersion: Self.currentVersion,
            payload: messages
        )
        let data = try encoder.encode(envelope)
        try VersionedPersistence.saveAtomically(data, to: fileURL) { [self] previous in
            (try? decode(previous)) != nil
        }
    }

    private func decode(_ data: Data) throws -> DecodedData {
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.format == Self.format else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if envelope.schemaVersion == Self.currentVersion {
                return .current(envelope.payload)
            }
            if envelope.schemaVersion == 1 {
                return .legacy(envelope.payload)
            } else {
                throw PersistenceLoadError.unsupportedVersion(
                    store: "conversation history",
                    version: envelope.schemaVersion
                )
            }
        } catch let error as PersistenceLoadError {
            throw error
        } catch {
            if Self.hasEnvelopeMarker(data) {
                throw error
            }
        }

        return .legacy(try decoder.decode([ChatMessage].self, from: data))
    }

    private static func hasEnvelopeMarker(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["schemaVersion"] != nil || object["payload"] != nil || object["format"] != nil
    }
}
