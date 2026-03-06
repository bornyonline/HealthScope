import Foundation

final class ManualEntryStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = baseDirectory.appendingPathComponent("manual_entries.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> ManualEntries {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(ManualEntries.self, from: data) else {
            return ManualEntries()
        }
        return decoded
    }

    func save(_ entries: ManualEntries) throws {
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
