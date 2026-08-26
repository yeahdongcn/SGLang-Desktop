import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func reportsUnsupportedMacAndBusyPort() async throws {
    let host = HostSystemProfile(
        architecture: "unsupported",
        operatingSystemVersion: OperatingSystemVersion(
            majorVersion: 13,
            minorVersion: 0,
            patchVersion: 0
        ),
        physicalMemoryBytes: 4 * 1_073_741_824
    )
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-diagnostics-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let report = await AppleSystemDiagnostics().run(
        host: host,
        installations: [],
        models: [],
        paths: AppPaths(root: root),
        port: 1
    )
    #expect(!report.isReady)
    #expect(report.items.first(where: { $0.id == "platform" })?.status == .failed)
    #expect(
        report.items.first(where: { $0.id == "runtime-sglang" })?.repairAction == .openInstallations
    )
}

@Test func findsAnAvailableLoopbackPort() {
    let port = LocalPort.availablePort()
    #expect(port != nil)
    if let port { #expect(LocalPort.isAvailable(port)) }
}
