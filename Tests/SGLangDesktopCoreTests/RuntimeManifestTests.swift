import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func acceptsAppleSiliconManifest() throws {
    let manifest = RuntimeManifest(
        id: "sglang-omni-apple",
        displayName: "SGLang-Omni Apple Runtime",
        engine: .sglangOmni,
        version: "0.1.0",
        entrypoint: "bin/sgl-omni",
        capabilities: ["qwen3-asr", "mlx"]
    )

    try manifest.validate()
}

@Test func rejectsNonAppleTarget() {
    let manifest = RuntimeManifest(
        id: "linux-runtime",
        displayName: "Linux Runtime",
        engine: .sglang,
        version: "0.1.0",
        platform: "linux",
        architecture: "x86_64",
        entrypoint: "bin/sglang"
    )

    #expect(throws: RuntimeManifestError.self) {
        try manifest.validate()
    }
}

@Test func rejectsUnsafeEntrypoint() {
    let manifest = RuntimeManifest(
        id: "unsafe",
        displayName: "Unsafe Runtime",
        engine: .sglang,
        version: "0.1.0",
        entrypoint: "../outside"
    )

    #expect(throws: RuntimeManifestError.self) {
        try manifest.validate()
    }
}

@Test func rejectsPathTraversalInCatalogIdentity() {
    let manifest = RuntimeManifest(
        id: "../../escape",
        displayName: "Unsafe Runtime",
        engine: .sglang,
        version: "1",
        entrypoint: "bin/sglang"
    )

    #expect(throws: RuntimeManifestError.self) {
        try manifest.validate()
    }
}
