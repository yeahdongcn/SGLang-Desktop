import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func activatingOverlayAlsoActivatesItsExactBase() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-runtime-library-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(root: root.appending(path: "data"))
    let library = RuntimeLibrary(paths: paths)

    let baseManifest = RuntimeManifest(
        id: "base",
        displayName: "Base",
        engine: .sglangOmni,
        version: "1",
        artifactKind: .base,
        compatibilityID: "lock-a",
        entrypoint: "bin/python3"
    )
    let base = try makeExecutableInstallation(manifest: baseManifest, under: root)
    let overlayManifest = RuntimeManifest(
        id: "overlay",
        displayName: "Overlay",
        engine: .sglangOmni,
        version: "commit",
        artifactKind: .engineOverlay,
        baseRuntimeID: baseManifest.generationID,
        compatibilityID: "lock-a",
        containsNativeCode: false,
        entrypoint: "bin/sgl-omni"
    )
    let overlay = try makeExecutableInstallation(manifest: overlayManifest, under: root)

    try await library.register(base)
    try await library.register(overlay)
    try await library.activate(id: overlay.id)

    let active = try await library.installations().filter(\.isActive)
    #expect(Set(active.map(\.manifest.artifactKind)) == [.base, .engineOverlay])
}

@Test func cannotActivateOverlayWithoutItsBase() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-runtime-library-missing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(root: root.appending(path: "data"))
    let library = RuntimeLibrary(paths: paths)
    let overlayManifest = RuntimeManifest(
        id: "overlay",
        displayName: "Overlay",
        engine: .sglang,
        version: "commit",
        artifactKind: .engineOverlay,
        baseRuntimeID: "missing@1",
        compatibilityID: "lock-a",
        containsNativeCode: false,
        entrypoint: "bin/sglang"
    )
    let overlay = try makeExecutableInstallation(manifest: overlayManifest, under: root)
    try await library.register(overlay)

    await #expect(throws: RuntimeLibraryError.self) {
        try await library.activate(id: overlay.id)
    }
}

private func makeExecutableInstallation(
    manifest: RuntimeManifest,
    under root: URL
) throws -> RuntimeInstallation {
    let installationRoot = root.appending(path: manifest.generationID)
    let executable = installationRoot.appending(path: manifest.entrypoint)
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return RuntimeInstallation(manifest: manifest, rootDirectory: installationRoot)
}
