import Foundation

public struct EngineLaunchConfiguration: Equatable, Sendable {
    public let installationID: UUID
    public let executableURL: URL
    public let workingDirectory: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let port: UInt16
    public let healthPath: String

    public init(
        installationID: UUID,
        executableURL: URL,
        workingDirectory: URL,
        arguments: [String],
        environment: [String: String] = [:],
        port: UInt16 = 30000,
        healthPath: String = "/health"
    ) {
        self.installationID = installationID
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.environment = environment
        self.port = port
        self.healthPath = healthPath
    }

    public var healthURL: URL {
        URL(string: "http://127.0.0.1:\(port)\(healthPath)")!
    }

    /// Builds the launch contract for a layered Python runtime. The base owns
    /// the interpreter and native libraries; the overlay contributes engine
    /// Python code ahead of the base package directory.
    public static func forComposition(
        _ composition: RuntimeComposition,
        arguments: [String],
        port: UInt16 = 30000,
        healthPath: String = "/health"
    ) throws -> EngineLaunchConfiguration {
        let baseRoot = composition.base.rootDirectory
        let overlayRoot = composition.overlay.rootDirectory
        let python = baseRoot.appending(path: "python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineLaunchConfigurationError.basePythonMissing(python)
        }

        let overlayPackages = overlayRoot.appending(path: "packages")
        let basePackages = baseRoot.appending(path: "packages")
        let pythonPath = [overlayPackages.path, basePackages.path]
            .filter { FileManager.default.fileExists(atPath: $0) }
            .joined(separator: ":")
        guard !pythonPath.isEmpty else {
            throw EngineLaunchConfigurationError.runtimePackagesMissing
        }

        let ffmpeg = baseRoot.appending(path: "ffmpeg/lib")
        var environment = [
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": pythonPath,
            "PATH": "\(baseRoot.path)/ffmpeg/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if FileManager.default.fileExists(atPath: ffmpeg.path) {
            environment["DYLD_LIBRARY_PATH"] = ffmpeg.path
        }

        return EngineLaunchConfiguration(
            installationID: composition.overlay.id,
            executableURL: python,
            workingDirectory: baseRoot,
            arguments: ["-s", "-m", "sglang_omni.cli"] + arguments,
            environment: environment,
            port: port,
            healthPath: healthPath
        )
    }
}

public enum EngineLaunchConfigurationError: LocalizedError, Equatable {
    case basePythonMissing(URL)
    case runtimePackagesMissing

    public var errorDescription: String? {
        switch self {
        case .basePythonMissing(let url):
            "The layered runtime base Python is missing: \(url.path)"
        case .runtimePackagesMissing:
            "The layered runtime has no materialized Python packages."
        }
    }
}
