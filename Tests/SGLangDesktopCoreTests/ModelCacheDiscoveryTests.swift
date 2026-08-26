import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func discoversHuggingFaceQwenCaches() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-model-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let modelRoot = root.appending(path: "models--mlx-community--Qwen3-ASR-0.6B-4bit")
    let snapshot = modelRoot.appending(path: "snapshots/abc123")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snapshot.appending(path: "config.json"))
    try Data("weights".utf8).write(to: snapshot.appending(path: "model.safetensors"))

    let discovered = ModelCacheDiscovery().discover(
        homeDirectory: root,
        additionalRoots: [root]
    )
    #expect(discovered.contains(where: { $0.repository == "mlx-community/Qwen3-ASR-0.6B-4bit" }))
}

@Test func ignoresIncompleteCacheWithoutWeights() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-incomplete-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = root.appending(path: "models--Qwen--Qwen3-0.6B/snapshots/partial")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snapshot.appending(path: "config.json"))

    let discovered = ModelCacheDiscovery().discover(homeDirectory: root, additionalRoots: [root])
    #expect(discovered.isEmpty)
}

@Test func discoversRuntimeExecutablesInAppleVenvLayout() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-runtime-discovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let omni = root.appending(path: "sglang-omni/.venv-apple/bin/sgl-omni")
    let core = root.appending(path: "sglang-omni/.venv-apple/bin/sglang")
    for executable in [omni, core] {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    let discovered = LocalRuntimeDiscovery().discover(homeDirectory: root, extraRoots: [root])
    #expect(Set(discovered.map { $0.manifest.engine }) == Set(EngineKind.allCases))
}
