import CryptoKit
import Foundation

public enum SHA256Checksum {
    public static func digest(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(fileAt url: URL, expected: String) throws -> Bool {
        try digest(fileAt: url).caseInsensitiveCompare(expected) == .orderedSame
    }
}
