import Foundation

enum PersistenceLoadError: LocalizedError {
    case corrupt(store: String, backupAvailable: Bool, underlying: Error)
    case unsupportedVersion(store: String, version: Int)

    var errorDescription: String? {
        switch self {
        case .corrupt(let store, let backupAvailable, _):
            let backup = backupAvailable ? " A previous-good backup is available." : ""
            return "The saved \(store) data is corrupt and was not discarded.\(backup)"
        case .unsupportedVersion(let store, let version):
            return "The saved \(store) data uses unsupported version \(version)."
        }
    }
}

enum VersionedPersistence {
    static func dataIfPresent(at url: URL, fileManager: FileManager = .default) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func saveAtomically(
        _ data: Data,
        to url: URL,
        previousDataIsValid: (Data) -> Bool,
        fileManager: FileManager = .default
    ) throws {
        if let previous = try dataIfPresent(at: url, fileManager: fileManager),
           previousDataIsValid(previous) {
            try previous.write(to: backupURL(for: url), options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func backupExists(for url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: backupURL(for: url).path)
    }

    static func removeBackup(for url: URL, fileManager: FileManager = .default) throws {
        let backupURL = backupURL(for: url)
        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        try fileManager.removeItem(at: backupURL)
    }

    private static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }
}
