import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func layeredLaunchUsesBasePythonAndOverlayFirstOnPythonPath() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-launch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let baseRoot = root.appending(path: "base")
    let overlayRoot = root.appending(path: "overlay")
    let python = baseRoot.appending(path: "python/bin/python3")
    try FileManager.default.createDirectory(
        at: python.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    try FileManager.default.createDirectory(
        at: overlayRoot.appending(path: "packages"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: baseRoot.appending(path: "packages"),
        withIntermediateDirectories: true
    )

    let baseManifest = RuntimeManifest(
        id: "base",
        displayName: "Base",
        engine: .sglangOmni,
        version: "1",
        artifactKind: .base,
        compatibilityID: "lock",
        entrypoint: "python/bin/python3"
    )
    let overlayManifest = RuntimeManifest(
        id: "overlay",
        displayName: "Overlay",
        engine: .sglangOmni,
        version: "commit",
        artifactKind: .engineOverlay,
        baseRuntimeID: baseManifest.generationID,
        compatibilityID: "lock",
        containsNativeCode: false,
        entrypoint: "bin/sgl-omni"
    )
    let composition = try RuntimeComposition(
        base: RuntimeInstallation(manifest: baseManifest, rootDirectory: baseRoot),
        overlay: RuntimeInstallation(manifest: overlayManifest, rootDirectory: overlayRoot)
    )

    let configuration = try EngineLaunchConfiguration.forComposition(
        composition,
        arguments: ["serve", "--port", "30000"]
    )
    #expect(configuration.executableURL == python)
    #expect(configuration.arguments.first == "-s")
    #expect(
        configuration.environment["PYTHONPATH"]?.hasPrefix(
            overlayRoot.appending(path: "packages").path) == true)
}
