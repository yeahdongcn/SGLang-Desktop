import Foundation

#if canImport(Darwin)
    import Darwin
#endif

public struct ProcessSnapshot: Equatable, Sendable {
    public let processIdentifier: Int32
    public let parentProcessIdentifier: Int32
    public let processGroupIdentifier: Int32
    public let command: String

    public init(
        processIdentifier: Int32,
        parentProcessIdentifier: Int32,
        processGroupIdentifier: Int32,
        command: String
    ) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.processGroupIdentifier = processGroupIdentifier
        self.command = command
    }
}

public struct ManagedServerProcessSnapshot: Equatable, Sendable {
    public let process: ProcessSnapshot
    public let engine: EngineKind
    public let port: UInt16
    public let modelPath: String
    public let servedModelName: String?

    public init(
        process: ProcessSnapshot,
        engine: EngineKind,
        port: UInt16,
        modelPath: String,
        servedModelName: String? = nil
    ) {
        self.process = process
        self.engine = engine
        self.port = port
        self.modelPath = modelPath
        self.servedModelName = servedModelName
    }
}

/// Read-only process discovery used to reconnect to a server after the app is
/// relaunched. It never relies on a shell, and attachment matching combines
/// PID/PGID, runtime location, engine marker, model path, port, and `serve`.
public struct ProcessInspector: Sendable {
    public init() {}

    public func snapshots() throws -> [ProcessSnapshot] {
        try runPS(
            arguments: ["-ww", "-axo", "pid=,ppid=,pgid=,command="],
            emptyOnNoMatch: false
        )
    }

    public func snapshot(processIdentifier: Int32) throws -> ProcessSnapshot? {
        guard processIdentifier > 1 else { return nil }
        return try runPS(
            arguments: [
                "-ww", "-p", "\(processIdentifier)", "-o", "pid=,ppid=,pgid=,command=",
            ],
            emptyOnNoMatch: true
        ).first
    }

    private func runPS(
        arguments: [String],
        emptyOnNoMatch: Bool
    ) throws -> [ProcessSnapshot] {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/ps")
        child.arguments = arguments

        let output = Pipe()
        child.standardOutput = output
        // Keep stdout and stderr on one pipe, then drain it before waiting. A
        // large process table can otherwise fill the pipe and deadlock `ps`.
        child.standardError = output
        try child.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()

        if emptyOnNoMatch, child.terminationStatus == 1 {
            return []
        }
        guard child.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessInspectorError.psFailed(
                status: child.terminationStatus,
                message: message ?? "unknown error"
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw ProcessInspectorError.invalidOutput
        }
        return text.split(whereSeparator: \Character.isNewline).compactMap(parseSnapshot)
    }

    public func isAlive(processIdentifier: Int32) -> Bool {
        guard processIdentifier > 1 else { return false }
        #if canImport(Darwin)
            return Darwin.kill(processIdentifier, 0) == 0 || errno == EPERM
        #else
            return false
        #endif
    }

    public func managedServerSnapshots() throws -> [ManagedServerProcessSnapshot] {
        try snapshots().compactMap(managedServerSnapshot)
    }

    public func managedServerSnapshot(
        from process: ProcessSnapshot
    ) -> ManagedServerProcessSnapshot? {
        guard containsWord("serve", in: process.command),
            let engine = engineKind(in: process.command),
            let portText = optionValue("--port", in: process.command),
            let port = UInt16(portText),
            let modelPath = optionValue("--model-path", in: process.command),
            !modelPath.isEmpty
        else {
            return nil
        }

        return ManagedServerProcessSnapshot(
            process: process,
            engine: engine,
            port: port,
            modelPath: modelPath,
            servedModelName: optionValue("--served-model-name", in: process.command)
                ?? optionValue("--model-name", in: process.command)
        )
    }

    /// Validates all stable launch invariants before the supervisor is allowed
    /// to signal a process it did not create. The configured entrypoint may be
    /// a wrapper which `exec`s a shared Python, so an exact executable match is
    /// accepted but not required when both commands live under the same
    /// app-managed `runtimes` root.
    public func matches(_ process: ProcessSnapshot, session: EngineSession) -> Bool {
        guard process.processIdentifier == session.processIdentifier,
            process.processGroupIdentifier == session.processGroupIdentifier,
            let managed = managedServerSnapshot(from: process),
            managed.engine == session.engine,
            managed.port == session.port,
            standardizedModelPath(managed.modelPath) == standardizedModelPath(session.modelPath),
            hasRuntimeAffinity(process.command, expected: session.runtimeExecutableURL)
        else {
            return false
        }
        return true
    }

    private func parseSnapshot(_ line: Substring) -> ProcessSnapshot? {
        let fields = line.split(
            maxSplits: 3,
            omittingEmptySubsequences: true,
            whereSeparator: \Character.isWhitespace
        )
        guard fields.count == 4,
            let pid = Int32(fields[0]),
            let parentPID = Int32(fields[1]),
            let processGroupID = Int32(fields[2])
        else {
            return nil
        }
        return ProcessSnapshot(
            processIdentifier: pid,
            parentProcessIdentifier: parentPID,
            processGroupIdentifier: processGroupID,
            command: String(fields[3])
        )
    }

    private func engineKind(in command: String) -> EngineKind? {
        if command.contains("-m sglang_omni.cli")
            || command.contains("/sgl-omni ")
        {
            return .sglangOmni
        }
        if command.contains("sglang.cli") || command.contains("sglang.launch_server") {
            return .sglang
        }
        return nil
    }

    private func containsWord(_ word: String, in command: String) -> Bool {
        command.split(whereSeparator: \Character.isWhitespace).contains(Substring(word))
    }

    private func optionValue(_ option: String, in command: String) -> String? {
        var searchStart = command.startIndex
        while searchStart < command.endIndex,
            let range = command.range(of: option, range: searchStart..<command.endIndex)
        {
            let hasLeftBoundary =
                range.lowerBound == command.startIndex
                || command[command.index(before: range.lowerBound)].isWhitespace
            let valueStart = range.upperBound
            guard hasLeftBoundary, valueStart < command.endIndex else {
                searchStart = range.upperBound
                continue
            }

            let separator = command[valueStart]
            guard separator == "=" || separator.isWhitespace else {
                searchStart = range.upperBound
                continue
            }

            var start = separator == "=" ? command.index(after: valueStart) : valueStart
            while start < command.endIndex, command[start].isWhitespace {
                start = command.index(after: start)
            }
            guard start < command.endIndex else { return nil }

            if command[start] == "\"" || command[start] == "'" {
                let quote = command[start]
                let quotedStart = command.index(after: start)
                guard let end = command[quotedStart...].firstIndex(of: quote) else { return nil }
                return String(command[quotedStart..<end])
            }

            let remainder = command[start...]
            let end = remainder.range(of: " --")?.lowerBound ?? command.endIndex
            return String(command[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func standardizedModelPath(_ path: String) -> String {
        NSString(
            string: NSString(string: path).expandingTildeInPath
        ).standardizingPath
    }

    private func hasRuntimeAffinity(_ command: String, expected: URL) -> Bool {
        let expectedPath = expected.standardizedFileURL.path
        if command == expectedPath || command.hasPrefix("\(expectedPath) ") {
            return true
        }

        let binDirectory = expected.deletingLastPathComponent().standardizedFileURL.path
        if command.hasPrefix("\(binDirectory)/") {
            return true
        }

        let components = expected.standardizedFileURL.pathComponents
        guard let runtimesIndex = components.lastIndex(of: "runtimes") else { return false }
        let managedRoot = NSString.path(withComponents: Array(components[...runtimesIndex]))
        return command.hasPrefix("\(managedRoot)/")
    }
}

public enum ProcessInspectorError: LocalizedError, Equatable {
    case psFailed(status: Int32, message: String)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .psFailed(let status, let message):
            "Process inspection failed with status \(status): \(message)"
        case .invalidOutput:
            "Process inspection returned invalid text."
        }
    }
}
