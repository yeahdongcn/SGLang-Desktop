import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func engineSessionStoreRoundTripsNonSecretIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sglang-desktop-session-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let paths = AppPaths(root: directory)
    let store = EngineSessionStore(paths: paths)
    let session = EngineSession(
        installationID: UUID(),
        engine: .sglang,
        processIdentifier: 42,
        processGroupIdentifier: 42,
        runtimeExecutableURL: directory.appending(path: "runtimes/core/bin/sglang"),
        modelPath: "/models/qwen",
        servedModelName: "qwen",
        usesMLX: true,
        port: 8000,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    try await store.upsert(session)
    #expect(try await store.sessions() == [session])

    let encoded = try String(contentsOf: paths.sessionsFile, encoding: .utf8)
    #expect(!encoded.contains("arguments"))
    #expect(!encoded.contains("environment"))

    try await store.remove(processIdentifier: 42)
    #expect(try await store.sessions().isEmpty)
}

@Test func processInspectorRecognizesExecedManagedRuntimeWrapper() throws {
    let managedRoot = URL(
        fileURLWithPath: "/Users/test/Library/Application Support/SGLang Desktop/runtimes"
    )
    let modelPath = "/Users/test/.cache/modelscope/Qwen3-0___6B"
    let command = """
        \(managedRoot.path)/trial-shared-apple/python/bin/python3 -s -c from sglang.cli.main import main; main() serve --model-path \(modelPath) --host 127.0.0.1 --port 8000 --model-type llm --served-model-name Qwen/Qwen3-0.6B
        """
    let process = ProcessSnapshot(
        processIdentifier: 6660,
        parentProcessIdentifier: 1,
        processGroupIdentifier: 6660,
        command: command
    )
    let session = EngineSession(
        installationID: UUID(),
        engine: .sglang,
        processIdentifier: 6660,
        processGroupIdentifier: 6660,
        runtimeExecutableURL: managedRoot.appending(path: "sglang-trial-apple/bin/sglang"),
        modelPath: modelPath,
        servedModelName: "Qwen/Qwen3-0.6B",
        port: 8000
    )

    let inspector = ProcessInspector()
    let managed = inspector.managedServerSnapshot(from: process)
    #expect(managed?.engine == .sglang)
    #expect(managed?.port == 8000)
    #expect(managed?.modelPath == modelPath)
    #expect(inspector.matches(process, session: session))

    let wrongPort = EngineSession(
        installationID: session.installationID,
        engine: session.engine,
        processIdentifier: session.processIdentifier,
        processGroupIdentifier: session.processGroupIdentifier,
        runtimeExecutableURL: session.runtimeExecutableURL,
        modelPath: session.modelPath,
        port: 8001
    )
    #expect(!inspector.matches(process, session: wrongPort))
}

@Test func processInspectorCanReadOnePIDWithoutScanningTheProcessTable() throws {
    let identifier = ProcessInfo.processInfo.processIdentifier
    let inspector = ProcessInspector()
    let snapshot = try inspector.snapshot(processIdentifier: identifier)
    #expect(snapshot?.processIdentifier == identifier)
    #expect(snapshot?.processGroupIdentifier != nil)
    #expect(try inspector.snapshot(processIdentifier: Int32.max) == nil)
}
