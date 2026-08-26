import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func computesKnownSHA256() throws {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "sglang-desktop-sha-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("sglang".utf8).write(to: file)

    #expect(
        try SHA256Checksum.digest(fileAt: file)
            == "6c87e5496f592f3c5af16c684e6edae23fd291553049e83f6f85afb74530495c"
    )
}
