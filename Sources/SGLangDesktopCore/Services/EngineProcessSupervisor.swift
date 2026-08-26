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

public actor EngineProcessSupervisor {
    private var process: Process?
    private var attachedSession: EngineSession?
    private var attachmentMonitorTask: Task<Void, Never>?
    private var currentState: EngineProcessState = .stopped
    private var requestedStopProcessIdentifier: Int32?
    private let processInspector: ProcessInspector
    private let logContinuation: AsyncStream<EngineLogEvent>.Continuation
    public nonisolated let logs: AsyncStream<EngineLogEvent>

    public init(processInspector: ProcessInspector = ProcessInspector()) {
        self.processInspector = processInspector
        let pair = AsyncStream<EngineLogEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(2_000)
        )
        self.logs = pair.stream
        self.logContinuation = pair.continuation
    }

    deinit {
        attachmentMonitorTask?.cancel()
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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        let continuation = logContinuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                guard let message = String(data: data, encoding: .utf8) else { continue }
                continuation.yield(EngineLogEvent(stream: .standardOutput, message: message))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                guard let message = String(data: data, encoding: .utf8) else { continue }
                continuation.yield(EngineLogEvent(stream: .standardError, message: message))
            }
        }

        child.terminationHandler = { [weak self] terminated in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task {
                await self?.processDidTerminate(
                    processIdentifier: terminated.processIdentifier,
                    status: terminated.terminationStatus
                )
            }
        }

        do {
            try child.run()
            process = child
            currentState = .running(processIdentifier: child.processIdentifier)
            logContinuation.yield(
                EngineLogEvent(
                    stream: .supervisor,
                    message: "Started engine process \(child.processIdentifier)."
                )
            )
        } catch {
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
    case attachedProcessNotFound(Int32)
    case attachedProcessIdentityMismatch(Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "An engine process is already running."
        case .executableNotFound(let url):
            "The engine executable is missing or not executable: \(url.path)"
        case .attachedProcessNotFound(let identifier):
            "The engine process \(identifier) is no longer running."
        case .attachedProcessIdentityMismatch(let identifier):
            "Process \(identifier) does not match the saved engine session."
        }
    }
}
