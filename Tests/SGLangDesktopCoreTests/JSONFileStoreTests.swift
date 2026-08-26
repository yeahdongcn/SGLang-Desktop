import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func jsonStoreRoundTripsAtomically() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sglang-desktop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = JSONFileStore<[String]>(fileURL: directory.appending(path: "state.json")) { [] }
    #expect(try await store.load().isEmpty)

    try await store.save(["one", "two"])
    #expect(try await store.load() == ["one", "two"])
}
