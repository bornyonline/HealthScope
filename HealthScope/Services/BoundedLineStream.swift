import Foundation

nonisolated enum BoundedLineStreamError: LocalizedError {
    case lineTooLarge
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .lineTooLarge:
            return "The AI service sent an oversized streaming frame. The response was stopped to protect device memory."
        case .invalidUTF8:
            return "The AI service sent invalid UTF-8 streaming data."
        }
    }
}

nonisolated enum BoundedLineStream {
    static func consume(
        _ bytes: URLSession.AsyncBytes,
        maximumLineBytes: Int,
        body: (String) throws -> Bool
    ) async throws {
        var line = Data()
        line.reserveCapacity(min(maximumLineBytes, 4_096))

        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                if try process(line, body: body) { return }
                line.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                guard line.count < maximumLineBytes else {
                    throw BoundedLineStreamError.lineTooLarge
                }
                line.append(byte)
            }
        }

        if !line.isEmpty {
            _ = try process(line, body: body)
        }
    }

    private static func process(_ data: Data, body: (String) throws -> Bool) throws -> Bool {
        guard let line = String(data: data, encoding: .utf8) else {
            throw BoundedLineStreamError.invalidUTF8
        }
        return try body(line)
    }
}
