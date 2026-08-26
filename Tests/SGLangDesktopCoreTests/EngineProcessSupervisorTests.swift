import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func durableEngineLogsArePrivatePersistedAndStreamed() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-supervisor-logs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appending(path: "logs")
    let executable = try makeEngineScript(
        under: root,
        body: """
            printf 'durable-stdout\n'
            printf 'durable-stderr\n' >&2
            sleep 0.2
            """
    )
    let supervisor = EngineProcessSupervisor(logDirectory: logs)
    let eventStream = supervisor.logs

    try await supervisor.start(configuration(for: executable, root: root))
    let urls = try #require(await supervisor.currentLogURLs())
    let standardOutput = try #require(urls.standardOutput)
    let standardError = try #require(urls.standardError)

    #expect(await waitForText("durable-stdout", in: standardOutput))
    #expect(await waitForText("durable-stderr", in: standardError))
    #expect(try permissions(of: logs) == 0o700)
    #expect(try permissions(of: standardOutput) == 0o600)
    #expect(try permissions(of: standardError) == 0o600)

    let streamed = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in eventStream {
                if event.stream == .standardOutput,
                    event.message.contains("durable-stdout")
                {
                    return true
                }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
    #expect(streamed)
}

@Test func childCanWriteLateOutputAfterSupervisorIsReleased() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-supervisor-release-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appending(path: "logs")
    let executable = try makeEngineScript(
        under: root,
        body: """
            printf 'before-release\n'
            sleep 0.5
            printf 'after-release-stdout\n'
            printf 'after-release-stderr\n' >&2
            """
    )

    // Returning from this scope releases the only supervisor reference. This
    // models quitting the app while leaving the engine process alive.
    let urls = try await launchThenRelease(
        executable: executable,
        root: root,
        logs: logs
    )
    let standardOutput = try #require(urls.standardOutput)
    let standardError = try #require(urls.standardError)

    #expect(await waitForText("after-release-stdout", in: standardOutput))
    #expect(await waitForText("after-release-stderr", in: standardError))
}

private func launchThenRelease(
    executable: URL,
    root: URL,
    logs: URL
) async throws -> EngineProcessLogURLs {
    let supervisor = EngineProcessSupervisor(logDirectory: logs)
    try await supervisor.start(configuration(for: executable, root: root))
    return try #require(await supervisor.currentLogURLs())
}

private func configuration(for executable: URL, root: URL) -> EngineLaunchConfiguration {
    EngineLaunchConfiguration(
        installationID: UUID(),
        executableURL: executable,
        workingDirectory: root,
        arguments: [],
        port: 30_000
    )
}

private func makeEngineScript(under root: URL, body: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appending(path: "engine-\(UUID().uuidString).sh")
    try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
    )
    return executable
}

private func waitForText(
    _ expected: String,
    in file: URL,
    timeout: Duration = .seconds(3)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let contents = try? String(contentsOf: file, encoding: .utf8),
            contents.contains(expected)
        {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
}
