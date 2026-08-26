import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func adoptsArbitraryLocalOmniVirtualEnvironment() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-local-runtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "bin/sgl-omni")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let installation = try LocalRuntimeAdopter().makeInstallation(executableURL: executable)

    #expect(installation.manifest.engine == .sglangOmni)
    #expect(installation.manifest.channel == .local)
    #expect(installation.manifest.distribution == .localVirtualEnvironment)
    #expect(installation.manifest.entrypoint == "bin/sgl-omni")
    #expect(installation.executableURL == executable)
}
