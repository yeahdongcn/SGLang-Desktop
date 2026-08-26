import Foundation

#if canImport(Darwin)
    import Darwin
#endif

public enum EngineProcessState: Equatable, Sendable {
    case stopped
    case starting
    case running(processIdentifier: Int32)
    case stopping
    case failed(message: String)
}

public struct EngineLogEvent: Equatable, Sendable {
    public enum Stream: String, Sendable {
        case standardOutput
        case standardError
        case supervisor
    }

    public let timestamp: Date
    public let stream: Stream
    public let message: String

    public init(timestamp: Date = Date(), stream: Stream, message: String) {
        self.timestamp = timestamp
        self.stream = stream
        self.message = message
    }
}

/// Files backing a launched engine's standard streams. The child owns its
/// inherited descriptors, so it can continue writing after the desktop app
/// exits and closes its own copies.
public struct EngineProcessLogURLs: Equatable, Sendable {
    public let standardOutput: URL?
    public let standardError: URL?

    public init(standardOutput: URL? = nil, standardError: URL? = nil) {
        self.standardOutput = standardOutput?.standardizedFileURL
        self.standardError = standardError?.standardizedFileURL
    }

    public var isEmpty: Bool {
        standardOutput == nil && standardError == nil
    }
}

public actor EngineProcessSupervisor {
    private var process: Process?
    private var attachedSession: EngineSession?
    private var attachmentMonitorTask: Task<Void, Never>?
    private var currentState: EngineProcessState = .stopped
    private var requestedStopProcessIdentifier: Int32?
    private let processInspector: ProcessInspector
    private let logDirectory: URL?
    private var activeLogURLs: EngineProcessLogURLs?
    private var logTailTasks: [Task<Void, Never>] = []
    private var logTailShutdownTask: Task<Void, Never>?
    private let logContinuation: AsyncStream<EngineLogEvent>.Continuation
    public nonisolated let logs: AsyncStream<EngineLogEvent>

    public init(
        processInspector: ProcessInspector = ProcessInspector(),
        logDirectory: URL? = nil
    ) {
        self.processInspector = processInspector
        self.logDirectory = logDirectory?.standardizedFileURL
        let pair = AsyncStream<EngineLogEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(2_000)
        )
        self.logs = pair.stream
        self.logContinuation = pair.continuation
    }

    deinit {
        attachmentMonitorTask?.cancel()
        logTailShutdownTask?.cancel()
        for task in logTailTasks { task.cancel() }
        logContinuation.finish()
    }

    public func state() -> EngineProcessState {
        currentState
    }

    public func processIdentifier() -> Int32? {
        process?.processIdentifier ?? attachedSession?.processIdentifier
    }

    public func processGroupIdentifier() -> Int32? {
        if let attachedSession {
            return attachedSession.processGroupIdentifier
        }
        guard let process else { return nil }
        #if canImport(Darwin)
            let identifier = Darwin.getpgid(process.processIdentifier)
            return identifier > 0 ? identifier : nil
        #else
            return process.processIdentifier
        #endif
    }

    public func currentLogURLs() -> EngineProcessLogURLs? {
        activeLogURLs
    }

    public func start(_ configuration: EngineLaunchConfiguration) throws {
        guard process == nil, attachedSession == nil else {
            throw EngineProcessError.alreadyRunning
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw EngineProcessError.executableNotFound(configuration.executableURL)
        }

        currentState = .starting
        let child = Process()
        child.executableURL = configuration.executableURL
        child.currentDirectoryURL = configuration.workingDirectory
        child.arguments = configuration.arguments
        child.environment = sanitizedEnvironment(configuration.environment)

        cancelLogTails()
        activeLogURLs = nil

        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?
        var parentWriteHandles: [FileHandle] = []
        if let logDirectory {
            let capture: DurableLogCapture
            do {
                capture = try makeDurableLogCapture(in: logDirectory)
            } catch {
                currentState = .failed(message: error.localizedDescription)
                throw error
            }
            activeLogURLs = capture.urls
            parentWriteHandles = [capture.standardOutput, capture.standardError]
            child.standardOutput = capture.standardOutput
            child.standardError = capture.standardError
        } else {
            let standardOutput = Pipe()
            let standardError = Pipe()
            stdoutPipe = standardOutput
            stderrPipe = standardError
            child.standardOutput = standardOutput
            child.standardError = standardError

            let continuation = logContinuation
            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                while true {
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    guard let message = String(data: data, encoding: .utf8) else { continue }
                    continuation.yield(
                        EngineLogEvent(stream: .standardOutput, message: message)
                    )
                }
            }
            standardError.fileHandleForReading.readabilityHandler = { handle in
                while true {
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    guard let message = String(data: data, encoding: .utf8) else { continue }
                    continuation.yield(
                        EngineLogEvent(stream: .standardError, message: message)
                    )
                }
            }
        }

        let terminationStandardOutputPipe = stdoutPipe
        let terminationStandardErrorPipe = stderrPipe
        child.terminationHandler = { [weak self] terminated in
            terminationStandardOutputPipe?.fileHandleForReading.readabilityHandler = nil
            terminationStandardErrorPipe?.fileHandleForReading.readabilityHandler = nil
            Task {
                await self?.processDidTerminate(
                    processIdentifier: terminated.processIdentifier,
                    status: terminated.terminationStatus
                )
            }
        }

        do {
            try child.run()
            // The child inherited independent descriptors during `run()`. The
            // parent copies must not remain open for the lifetime of the UI.
            for handle in parentWriteHandles { try? handle.close() }
            process = child
            currentState = .running(processIdentifier: child.processIdentifier)
            if let activeLogURLs {
                beginLogTails(urls: activeLogURLs, replayExisting: false)
            }
            logContinuation.yield(
                EngineLogEvent(
                    stream: .supervisor,
                    message: "Started engine process \(child.processIdentifier)."
                )
            )
        } catch {
            for handle in parentWriteHandles { try? handle.close() }
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            activeLogURLs = nil
            currentState = .failed(message: error.localizedDescription)
            throw error
        }
    }

    /// Reconnects supervision to a process which outlived an earlier app
    /// process. Identity is re-read and validated here so callers cannot attach
    /// an arbitrary PID and later signal it through `stop()`.
    public func attach(to session: EngineSession) throws {
        guard process == nil, attachedSession == nil else {
            throw EngineProcessError.alreadyRunning
        }
        guard session.processIdentifier > 1, session.processGroupIdentifier > 1,
            session.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let snapshot = try processInspector.snapshot(
                processIdentifier: session.processIdentifier
            )
        else {
            throw EngineProcessError.attachedProcessNotFound(session.processIdentifier)
        }
        guard processInspector.matches(snapshot, session: session) else {
            throw EngineProcessError.attachedProcessIdentityMismatch(session.processIdentifier)
        }

        attachedSession = session
        requestedStopProcessIdentifier = nil
        currentState = .running(processIdentifier: session.processIdentifier)
        let restoredLogURLs = EngineProcessLogURLs(
            standardOutput: validatedAttachedLogURL(session.standardOutputLogURL),
            standardError: validatedAttachedLogURL(session.standardErrorLogURL)
        )
        activeLogURLs = restoredLogURLs.isEmpty ? nil : restoredLogURLs
        if let activeLogURLs {
            beginLogTails(urls: activeLogURLs, replayExisting: true)
        }
        logContinuation.yield(
            EngineLogEvent(
                stream: .supervisor,
                message: "Reattached to engine process \(session.processIdentifier)."
            )
        )
        beginAttachmentMonitor(sessionID: session.id)
    }

    /// Forgets an attached process without sending it a signal. Processes
    /// launched by this supervisor cannot be detached through this API.
    public func detach() {
        guard attachedSession != nil else { return }
        attachmentMonitorTask?.cancel()
        attachmentMonitorTask = nil
        logTailShutdownTask?.cancel()
        logTailShutdownTask = nil
        cancelLogTails()
        activeLogURLs = nil
        attachedSession = nil
        requestedStopProcessIdentifier = nil
        currentState = .stopped
    }

    public func stop() {
        if let attachedSession {
            stopAttached(session: attachedSession)
            return
        }

        guard let process else {
            currentState = .stopped
            return
        }
        guard process.isRunning else {
            self.process = nil
            currentState = .stopped
            return
        }

        currentState = .stopping
        requestedStopProcessIdentifier = process.processIdentifier
        logContinuation.yield(
            EngineLogEvent(stream: .supervisor, message: "Stopping engine process.")
        )
        process.terminate()
        let identifier = process.processIdentifier
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            await self?.escalateIfStillRunning(identifier: identifier)
        }
    }

    private func stopAttached(session: EngineSession) {
        do {
            guard
                let snapshot = try processInspector.snapshot(
                    processIdentifier: session.processIdentifier
                ), processInspector.matches(snapshot, session: session)
            else {
                finishAttachment(
                    session: session,
                    failure: "The attached engine process identity changed; no signal was sent."
                )
                return
            }
        } catch {
            guard processInspector.isAlive(processIdentifier: session.processIdentifier) else {
                finishAttachment(session: session, failure: nil)
                return
            }
            currentState = .failed(
                message:
                    "Could not verify the attached engine before stopping: \(error.localizedDescription)"
            )
            return
        }

        currentState = .stopping
        requestedStopProcessIdentifier = session.processIdentifier
        logContinuation.yield(
            EngineLogEvent(
                stream: .supervisor,
                message: "Stopping attached engine process \(session.processIdentifier)."
            )
        )
        signalAttachedProcess(session, signal: SIGTERM)
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            await self?.escalateAttachedIfStillRunning(sessionID: session.id)
        }
    }

    private struct DurableLogCapture {
        let urls: EngineProcessLogURLs
        let standardOutput: FileHandle
        let standardError: FileHandle
    }

    private func makeDurableLogCapture(in directory: URL) throws -> DurableLogCapture {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
            var directoryInfo = stat()
            guard
                Darwin.lstat(directory.path, &directoryInfo) == 0,
                directoryInfo.st_mode & S_IFMT == S_IFDIR
            else {
                throw EngineProcessError.insecureLogLocation(directory)
            }
        #endif
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        let identifier = "engine-\(UUID().uuidString.lowercased())"
        let standardOutputURL = directory.appending(path: "\(identifier).stdout.log")
        let standardErrorURL = directory.appending(path: "\(identifier).stderr.log")
        let standardOutput = try Self.openAppendOnlyFile(at: standardOutputURL)
        do {
            let standardError = try Self.openAppendOnlyFile(at: standardErrorURL)
            return DurableLogCapture(
                urls: EngineProcessLogURLs(
                    standardOutput: standardOutputURL,
                    standardError: standardErrorURL
                ),
                standardOutput: standardOutput,
                standardError: standardError
            )
        } catch {
            try? standardOutput.close()
            throw error
        }
    }

    /// Session JSON is user-writable state. Never let a saved URL turn the log
    /// tailer into an arbitrary-file reader: only regular, non-symlink direct
    /// children of this supervisor's configured log directory are accepted.
    private func validatedAttachedLogURL(_ candidate: URL?) -> URL? {
        guard let logDirectory, let candidate, candidate.isFileURL else { return nil }
        let directory = logDirectory.standardizedFileURL
        let file = candidate.standardizedFileURL
        guard file.deletingLastPathComponent() == directory else { return nil }
        guard
            file.deletingLastPathComponent().resolvingSymlinksInPath()
                == directory.resolvingSymlinksInPath()
        else {
            return nil
        }
        #if canImport(Darwin)
            var directoryInfo = stat()
            var fileInfo = stat()
            guard
                Darwin.lstat(directory.path, &directoryInfo) == 0,
                directoryInfo.st_mode & S_IFMT == S_IFDIR,
                Darwin.lstat(file.path, &fileInfo) == 0,
                fileInfo.st_mode & S_IFMT == S_IFREG
            else {
                return nil
            }
        #else
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: file.path,
                    isDirectory: &isDirectory
                ), !isDirectory.boolValue
            else {
                return nil
            }
        #endif
        return file
    }

    private nonisolated static func openAppendOnlyFile(at url: URL) throws -> FileHandle {
        #if canImport(Darwin)
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_APPEND,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                _ = Darwin.close(descriptor)
                throw error
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
            if !FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        #endif
    }

    private func beginLogTails(urls: EngineProcessLogURLs, replayExisting: Bool) {
        logTailShutdownTask?.cancel()
        logTailShutdownTask = nil
        cancelLogTails()
        if let url = urls.standardOutput {
            logTailTasks.append(
                Self.makeLogTailTask(
                    url: url,
                    stream: .standardOutput,
                    replayExisting: replayExisting,
                    continuation: logContinuation
                )
            )
        }
        if let url = urls.standardError {
            logTailTasks.append(
                Self.makeLogTailTask(
                    url: url,
                    stream: .standardError,
                    replayExisting: replayExisting,
                    continuation: logContinuation
                )
            )
        }
    }

    private func cancelLogTails() {
        for task in logTailTasks { task.cancel() }
        logTailTasks.removeAll()
    }

    private func scheduleLogTailShutdown() {
        logTailShutdownTask?.cancel()
        let expectedURLs = activeLogURLs
        logTailShutdownTask = Task.detached { [weak self] in
            // Let tailers drain data the child wrote immediately before exit.
            try? await Task.sleep(for: .milliseconds(300))
            await self?.finishLogTailShutdown(expectedURLs: expectedURLs)
        }
    }

    private func finishLogTailShutdown(expectedURLs: EngineProcessLogURLs?) {
        guard process == nil, attachedSession == nil, activeLogURLs == expectedURLs else {
            return
        }
        cancelLogTails()
        logTailShutdownTask = nil
    }

    private nonisolated static func makeLogTailTask(
        url: URL,
        stream: EngineLogEvent.Stream,
        replayExisting: Bool,
        continuation: AsyncStream<EngineLogEvent>.Continuation
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await tailLogFile(
                at: url,
                stream: stream,
                replayExisting: replayExisting,
                continuation: continuation
            )
        }
    }

    private nonisolated static func tailLogFile(
        at url: URL,
        stream: EngineLogEvent.Stream,
        replayExisting: Bool,
        continuation: AsyncStream<EngineLogEvent>.Continuation
    ) async {
        var handle: FileHandle?
        while !Task.isCancelled, handle == nil {
            handle = openReadOnlyRegularFile(at: url)
            if handle == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let handle else { return }
        defer { try? handle.close() }

        if replayExisting,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        {
            // Replaying a bounded suffix makes restored UI logs useful without
            // reading an unbounded long-running server log into memory.
            let replayLimit: UInt64 = 256 * 1_024
            try? handle.seek(toOffset: size > replayLimit ? size - replayLimit : 0)
        }

        var undecodedBytes = Data()
        while !Task.isCancelled {
            do {
                if let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
                    undecodedBytes.append(data)
                    let decoded = decodeCompleteUTF8Prefix(from: undecodedBytes)
                    undecodedBytes = decoded.remainder
                    if !decoded.message.isEmpty {
                        continuation.yield(
                            EngineLogEvent(stream: stream, message: decoded.message)
                        )
                    }
                    continue
                }
            } catch {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !undecodedBytes.isEmpty {
            continuation.yield(
                EngineLogEvent(
                    stream: stream,
                    message: String(decoding: undecodedBytes, as: UTF8.self)
                )
            )
        }
    }

    private nonisolated static func openReadOnlyRegularFile(at url: URL) -> FileHandle? {
        #if canImport(Darwin)
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                _ = Darwin.close(descriptor)
                return nil
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
            return try? FileHandle(forReadingFrom: url)
        #endif
    }

    private nonisolated static func decodeCompleteUTF8Prefix(
        from data: Data
    ) -> (message: String, remainder: Data) {
        let maximumIncompleteSuffix = min(3, data.count)
        for suffixCount in 0...maximumIncompleteSuffix {
            let prefixCount = data.count - suffixCount
            let prefix = data.prefix(prefixCount)
            if let message = String(data: prefix, encoding: .utf8) {
                return (
                    message,
                    suffixCount == 0 ? Data() : Data(data.suffix(suffixCount))
                )
            }
        }
        // Preserve progress even if a subprocess emitted invalid UTF-8.
        return (String(decoding: data, as: UTF8.self), Data())
    }

    private func sanitizedEnvironment(_ configured: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "TMPDIR", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME"]
        var result = inherited.filter { allowed.contains($0.key) }
        for forbidden in [
            "PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV",
            "UV_PROJECT", "UV_CONFIG_FILE", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH",
        ] {
            result.removeValue(forKey: forbidden)
        }
        result["PYTHONNOUSERSITE"] = "1"
        result["PYTHONDONTWRITEBYTECODE"] = "1"
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result.merge(configured, uniquingKeysWith: { _, value in value })
        return result
    }

    private func escalateIfStillRunning(identifier: Int32) {
        guard process?.processIdentifier == identifier, process?.isRunning == true else { return }
        logContinuation.yield(
            EngineLogEvent(stream: .supervisor, message: "Engine did not stop; sending SIGKILL.")
        )
        #if canImport(Darwin)
            _ = Darwin.kill(identifier, SIGKILL)
        #else
            process?.terminate()
        #endif
    }

    private func beginAttachmentMonitor(sessionID: UUID) {
        attachmentMonitorTask?.cancel()
        attachmentMonitorTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard await self.refreshAttachment(sessionID: sessionID) else { return }
            }
        }
    }

    private func refreshAttachment(sessionID: UUID) -> Bool {
        guard let session = attachedSession, session.id == sessionID else { return false }
        do {
            guard
                let snapshot = try processInspector.snapshot(
                    processIdentifier: session.processIdentifier
                )
            else {
                finishAttachment(session: session, failure: nil)
                return false
            }
            guard processInspector.matches(snapshot, session: session) else {
                finishAttachment(
                    session: session,
                    failure: "Attached engine process identity changed."
                )
                return false
            }
            return true
        } catch {
            // A transient `ps` failure is not proof that the process exited.
            guard !processInspector.isAlive(processIdentifier: session.processIdentifier) else {
                return true
            }
            finishAttachment(session: session, failure: nil)
            return false
        }
    }

    private func escalateAttachedIfStillRunning(sessionID: UUID) {
        guard let session = attachedSession, session.id == sessionID else { return }
        guard
            let snapshot = try? processInspector.snapshot(
                processIdentifier: session.processIdentifier
            ), processInspector.matches(snapshot, session: session)
        else {
            return
        }
        logContinuation.yield(
            EngineLogEvent(
                stream: .supervisor,
                message: "Attached engine did not stop; sending SIGKILL."
            )
        )
        signalAttachedProcess(session, signal: SIGKILL)
    }

    private func signalAttachedProcess(_ session: EngineSession, signal: Int32) {
        #if canImport(Darwin)
            let processGroupIsDedicated =
                session.processGroupIdentifier == session.processIdentifier
                && session.processGroupIdentifier != Darwin.getpgrp()
            let target =
                processGroupIsDedicated
                ? -session.processGroupIdentifier
                : session.processIdentifier
            _ = Darwin.kill(target, signal)
        #endif
    }

    private func finishAttachment(session: EngineSession, failure: String?) {
        guard attachedSession?.id == session.id else { return }
        attachmentMonitorTask?.cancel()
        attachmentMonitorTask = nil
        attachedSession = nil
        scheduleLogTailShutdown()
        let wasRequested = requestedStopProcessIdentifier == session.processIdentifier
        requestedStopProcessIdentifier = nil
        if let failure {
            currentState = .failed(message: failure)
            logContinuation.yield(EngineLogEvent(stream: .supervisor, message: failure))
        } else if wasRequested {
            currentState = .stopped
            logContinuation.yield(
                EngineLogEvent(
                    stream: .supervisor,
                    message: "Attached engine process \(session.processIdentifier) stopped."
                )
            )
        } else {
            let message =
                "Attached engine process \(session.processIdentifier) is no longer running."
            currentState = .failed(message: message)
            logContinuation.yield(EngineLogEvent(stream: .supervisor, message: message))
        }
    }

    private func processDidTerminate(processIdentifier: Int32, status: Int32) {
        guard process?.processIdentifier == processIdentifier else { return }
        process = nil
        scheduleLogTailShutdown()
        let requestedStop = requestedStopProcessIdentifier == processIdentifier
        requestedStopProcessIdentifier = nil
        currentState =
            requestedStop || status == 0
            ? .stopped
            : .failed(message: "Engine exited with status \(status).")
        logContinuation.yield(
            EngineLogEvent(
                stream: .supervisor,
                message: "Engine process \(processIdentifier) exited with status \(status)."
            )
        )
    }
}

public enum EngineProcessError: LocalizedError {
    case alreadyRunning
    case executableNotFound(URL)
    case insecureLogLocation(URL)
    case attachedProcessNotFound(Int32)
    case attachedProcessIdentityMismatch(Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "An engine process is already running."
        case .executableNotFound(let url):
            "The engine executable is missing or not executable: \(url.path)"
        case .insecureLogLocation(let url):
            "The engine log directory is not a regular directory: \(url.path)"
        case .attachedProcessNotFound(let identifier):
            "The engine process \(identifier) is no longer running."
        case .attachedProcessIdentityMismatch(let identifier):
            "Process \(identifier) does not match the saved engine session."
        }
    }
}
