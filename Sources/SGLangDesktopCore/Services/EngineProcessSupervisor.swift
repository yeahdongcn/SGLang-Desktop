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
    private var currentState: EngineProcessState = .stopped
    private var requestedStopProcessIdentifier: Int32?
    private let logContinuation: AsyncStream<EngineLogEvent>.Continuation
    public nonisolated let logs: AsyncStream<EngineLogEvent>

    public init() {
        let pair = AsyncStream<EngineLogEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(2_000)
        )
        self.logs = pair.stream
        self.logContinuation = pair.continuation
    }

    deinit {
        logContinuation.finish()
    }

    public func state() -> EngineProcessState {
        currentState
    }

    public func start(_ configuration: EngineLaunchConfiguration) throws {
        guard process == nil else {
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

    public func stop() {
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

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "An engine process is already running."
        case .executableNotFound(let url):
            "The engine executable is missing or not executable: \(url.path)"
        }
    }
}
