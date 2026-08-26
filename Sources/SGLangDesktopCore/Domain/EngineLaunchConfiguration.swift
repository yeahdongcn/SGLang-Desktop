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
}
