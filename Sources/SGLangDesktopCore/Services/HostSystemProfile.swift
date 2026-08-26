import Foundation

public struct HostSystemProfile: Sendable {
    public let architecture: String
    public let operatingSystemVersion: OperatingSystemVersion
    public let physicalMemoryBytes: UInt64

    public init(
        architecture: String,
        operatingSystemVersion: OperatingSystemVersion,
        physicalMemoryBytes: UInt64
    ) {
        self.architecture = architecture
        self.operatingSystemVersion = operatingSystemVersion
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public static var current: HostSystemProfile {
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "unsupported"
        #endif

        return HostSystemProfile(
            architecture: architecture,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    public var isSupported: Bool {
        architecture == "arm64" && operatingSystemVersion.majorVersion >= 14
    }

    public var platformLabel: String {
        let version = operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion) · \(architecture)"
    }
}
