import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func composesMatchingBaseAndOverlay() throws {
    let baseManifest = RuntimeManifest(
        id: "omni-apple-base",
        displayName: "Omni Apple Base",
        engine: .sglangOmni,
        version: "1",
        artifactKind: .base,
        compatibilityID: "py312-torch211-mlx032-ffmpeg71",
        entrypoint: "bin/python3"
    )
    let overlayManifest = RuntimeManifest(
        id: "omni-engine",
        displayName: "Omni Nightly",
        engine: .sglangOmni,
        version: "b83b3b9",
        channel: .nightly,
        artifactKind: .engineOverlay,
        sourceCommit: "b83b3b9",
        baseRuntimeID: baseManifest.generationID,
        compatibilityID: "py312-torch211-mlx032-ffmpeg71",
        containsNativeCode: false,
        entrypoint: "bin/sgl-omni"
    )

    let composition = try RuntimeComposition(
        base: RuntimeInstallation(
            manifest: baseManifest,
            rootDirectory: URL(fileURLWithPath: "/base")
        ),
        overlay: RuntimeInstallation(
            manifest: overlayManifest,
            rootDirectory: URL(fileURLWithPath: "/overlay")
        )
    )

    #expect(composition.overlay.manifest.sourceCommit == "b83b3b9")
}

@Test func rejectsOverlayBuiltForAnotherDependencyLock() throws {
    let baseManifest = RuntimeManifest(
        id: "base",
        displayName: "Base",
        engine: .sglang,
        version: "1",
        artifactKind: .base,
        compatibilityID: "lock-a",
        entrypoint: "bin/python3"
    )
    let overlayManifest = RuntimeManifest(
        id: "overlay",
        displayName: "Overlay",
        engine: .sglang,
        version: "commit",
        artifactKind: .engineOverlay,
        baseRuntimeID: baseManifest.generationID,
        compatibilityID: "lock-b",
        containsNativeCode: false,
        entrypoint: "bin/sglang"
    )

    #expect(throws: RuntimeCompositionError.self) {
        try RuntimeComposition(
            base: RuntimeInstallation(
                manifest: baseManifest,
                rootDirectory: URL(fileURLWithPath: "/base")
            ),
            overlay: RuntimeInstallation(
                manifest: overlayManifest,
                rootDirectory: URL(fileURLWithPath: "/overlay")
            )
        )
    }
}
