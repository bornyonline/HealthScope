import Foundation

final class ConversationStore {
    private let fileURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let ioQueue = DispatchQueue(label: "ConversationStore.IO", qos: .utility)

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = baseDirectory.appendingPathComponent("analysis_chat_history.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let messages = try? decoder.decode([ChatMessage].self, from: data) else {
            return []
        }
        return messages
    }

    func save(_ messages: [ChatMessage]) throws {
        let data = try encoder.encode(messages)
        try data.write(to: fileURL, options: .atomic)
    }

    func saveAsync(_ messages: [ChatMessage], completion: @escaping (Error?) -> Void) {
        ioQueue.async { [encoder, fileURL] in
            do {
                let data = try encoder.encode(messages)
                try data.write(to: fileURL, options: .atomic)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}
