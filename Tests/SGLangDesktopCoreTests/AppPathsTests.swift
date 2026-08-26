import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func appPathsStayUnderConfiguredRoot() throws {
    let root = URL(fileURLWithPath: "/tmp/sglang-desktop-tests")
    let paths = AppPaths(root: root)

    #expect(paths.runtimes.path == "/tmp/sglang-desktop-tests/runtimes")
    #expect(paths.models.path == "/tmp/sglang-desktop-tests/models")
    #expect(paths.logs.path == "/tmp/sglang-desktop-tests/logs")
    #expect(paths.installationsFile.path.hasPrefix(paths.root.path))
}
