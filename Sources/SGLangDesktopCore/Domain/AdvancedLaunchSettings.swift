import Foundation

public struct AdvancedLaunchSettings: Codable, Equatable, Sendable {
    public var servedModelName: String
    public var contextLength: String
    public var maxRunningRequests: String
    public var maxTotalTokens: String
    public var memoryFractionStatic: String
    public var logLevel: String
    public var trustRemoteCode: Bool
    public var disableRadixCache: Bool
    public var disableOverlapSchedule: Bool
    public var extraArguments: String
    public var extraEnvironment: String

    public init(
        servedModelName: String = "",
        contextLength: String = "",
        maxRunningRequests: String = "",
        maxTotalTokens: String = "",
        memoryFractionStatic: String = "",
        logLevel: String = "info",
        trustRemoteCode: Bool = false,
        disableRadixCache: Bool = false,
        disableOverlapSchedule: Bool = false,
        extraArguments: String = "",
        extraEnvironment: String = ""
    ) {
        self.servedModelName = servedModelName
        self.contextLength = contextLength
        self.maxRunningRequests = maxRunningRequests
        self.maxTotalTokens = maxTotalTokens
        self.memoryFractionStatic = memoryFractionStatic
        self.logLevel = logLevel
        self.trustRemoteCode = trustRemoteCode
        self.disableRadixCache = disableRadixCache
        self.disableOverlapSchedule = disableOverlapSchedule
        self.extraArguments = extraArguments
        self.extraEnvironment = extraEnvironment
    }
}
