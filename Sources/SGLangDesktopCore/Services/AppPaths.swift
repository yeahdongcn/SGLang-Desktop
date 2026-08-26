import Foundation

public struct AppPaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func userDefault(fileManager: FileManager = .default) throws -> AppPaths {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return AppPaths(root: applicationSupport.appending(path: "SGLang Desktop"))
    }

    public var runtimes: URL { root.appending(path: "runtimes", directoryHint: .isDirectory) }
    public var runtimeStaging: URL { root.appending(path: "staging", directoryHint: .isDirectory) }
    public var models: URL { root.appending(path: "models", directoryHint: .isDirectory) }
    public var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    public var state: URL { root.appending(path: "state", directoryHint: .isDirectory) }
    public var installationsFile: URL { state.appending(path: "installations.json") }
    public var modelsFile: URL { state.appending(path: "models.json") }
    public var sessionsFile: URL { state.appending(path: "sessions.json") }

    public func createRequiredDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, runtimes, runtimeStaging, models, logs, state] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
