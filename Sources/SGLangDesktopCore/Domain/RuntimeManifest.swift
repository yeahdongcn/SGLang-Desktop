import Foundation

public enum RuntimeChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case preview
    case nightly
    case local
}

public enum RuntimeDistribution: String, Codable, CaseIterable, Sendable {
    case prebuilt
    case sourceCheckout
    case localVirtualEnvironment
}

public enum RuntimeArtifactKind: String, Codable, CaseIterable, Sendable {
    /// A self-contained runtime used for the first stable implementation.
    case complete
    /// CPython, native libraries, and the dependency lock shared by overlays.
    case base
    /// Engine code tied to one compatible base runtime.
    case engineOverlay
}

public struct RuntimeManifest: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let engine: EngineKind
    public let version: String
    public let platform: String
    public let architecture: String
    public let minimumMacOSVersion: String
    public let channel: RuntimeChannel
    public let distribution: RuntimeDistribution
    public let artifactKind: RuntimeArtifactKind
    public let sourceCommit: String?
    public let baseRuntimeID: String?
    public let compatibilityID: String?
    public let containsNativeCode: Bool
    public let entrypoint: String
    public let defaultArguments: [String]
    public let capabilities: [String]
    public let components: [String: String]
    public let downloadURL: URL?
    public let archiveSizeBytes: Int64?
    public let sha256: String?

    public var generationID: String { "\(id)@\(version)" }

    public init(
        schemaVersion: Int = RuntimeManifest.currentSchemaVersion,
        id: String,
        displayName: String,
        engine: EngineKind,
        version: String,
        platform: String = "macos",
        architecture: String = "arm64",
        minimumMacOSVersion: String = "14.0",
        channel: RuntimeChannel = .stable,
        distribution: RuntimeDistribution = .prebuilt,
        artifactKind: RuntimeArtifactKind = .complete,
        sourceCommit: String? = nil,
        baseRuntimeID: String? = nil,
        compatibilityID: String? = nil,
        containsNativeCode: Bool = true,
        entrypoint: String,
        defaultArguments: [String] = [],
        capabilities: [String] = [],
        components: [String: String] = [:],
        downloadURL: URL? = nil,
        archiveSizeBytes: Int64? = nil,
        sha256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.version = version
        self.platform = platform
        self.architecture = architecture
        self.minimumMacOSVersion = minimumMacOSVersion
        self.channel = channel
        self.distribution = distribution
        self.artifactKind = artifactKind
        self.sourceCommit = sourceCommit
        self.baseRuntimeID = baseRuntimeID
        self.compatibilityID = compatibilityID
        self.containsNativeCode = containsNativeCode
        self.entrypoint = entrypoint
        self.defaultArguments = defaultArguments
        self.capabilities = capabilities
        self.components = components
        self.downloadURL = downloadURL
        self.archiveSizeBytes = archiveSizeBytes
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, displayName, engine, version, platform, architecture
        case minimumMacOSVersion, channel, distribution, artifactKind, sourceCommit, baseRuntimeID
        case compatibilityID, containsNativeCode
        case entrypoint, defaultArguments, capabilities, components, downloadURL
        case archiveSizeBytes, sha256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            id: try values.decode(String.self, forKey: .id),
            displayName: try values.decode(String.self, forKey: .displayName),
            engine: try values.decode(EngineKind.self, forKey: .engine),
            version: try values.decode(String.self, forKey: .version),
            platform: try values.decode(String.self, forKey: .platform),
            architecture: try values.decode(String.self, forKey: .architecture),
            minimumMacOSVersion: try values.decode(String.self, forKey: .minimumMacOSVersion),
            channel: try values.decodeIfPresent(RuntimeChannel.self, forKey: .channel) ?? .stable,
            distribution: try values.decodeIfPresent(
                RuntimeDistribution.self, forKey: .distribution) ?? .prebuilt,
            artifactKind: try values.decodeIfPresent(
                RuntimeArtifactKind.self, forKey: .artifactKind) ?? .complete,
            sourceCommit: try values.decodeIfPresent(String.self, forKey: .sourceCommit),
            baseRuntimeID: try values.decodeIfPresent(String.self, forKey: .baseRuntimeID),
            compatibilityID: try values.decodeIfPresent(String.self, forKey: .compatibilityID),
            containsNativeCode: try values.decodeIfPresent(
                Bool.self, forKey: .containsNativeCode) ?? true,
            entrypoint: try values.decode(String.self, forKey: .entrypoint),
            defaultArguments: try values.decodeIfPresent([String].self, forKey: .defaultArguments)
                ?? [],
            capabilities: try values.decodeIfPresent([String].self, forKey: .capabilities) ?? [],
            components: try values.decodeIfPresent([String: String].self, forKey: .components)
                ?? [:],
            downloadURL: try values.decodeIfPresent(URL.self, forKey: .downloadURL),
            archiveSizeBytes: try values.decodeIfPresent(Int64.self, forKey: .archiveSizeBytes),
            sha256: try values.decodeIfPresent(String.self, forKey: .sha256)
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RuntimeManifestError.unsupportedSchema(schemaVersion)
        }
        guard platform == "macos", architecture == "arm64" else {
            throw RuntimeManifestError.unsupportedPlatform(
                platform: platform,
                architecture: architecture
            )
        }
        guard !id.isEmpty, !version.isEmpty, !entrypoint.isEmpty else {
            throw RuntimeManifestError.missingRequiredField
        }
        guard Self.isSafePathComponent(id) else {
            throw RuntimeManifestError.invalidPathComponent(field: "id", value: id)
        }
        guard Self.isSafePathComponent(version) else {
            throw RuntimeManifestError.invalidPathComponent(field: "version", value: version)
        }
        if artifactKind == .engineOverlay {
            guard let baseRuntimeID, !baseRuntimeID.isEmpty,
                let compatibilityID, !compatibilityID.isEmpty
            else {
                throw RuntimeManifestError.overlayCompatibilityMissing
            }
        }
        guard !entrypoint.hasPrefix("/"), !entrypoint.split(separator: "/").contains("..") else {
            throw RuntimeManifestError.unsafeEntrypoint(entrypoint)
        }
        if let sha256 {
            let isHex = sha256.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
            guard sha256.count == 64, isHex else {
                throw RuntimeManifestError.invalidSHA256
            }
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        guard value.count <= 160, value != ".", value != ".." else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Compares runtime identity while ignoring catalog transport fields.
    /// The archive checksum belongs to the catalog entry; including it inside
    /// `runtime.json` would make the archive hash self-referential.
    public func matchesRuntimeIdentity(_ other: RuntimeManifest) -> Bool {
        schemaVersion == other.schemaVersion
            && id == other.id
            && displayName == other.displayName
            && engine == other.engine
            && version == other.version
            && platform == other.platform
            && architecture == other.architecture
            && minimumMacOSVersion == other.minimumMacOSVersion
            && channel == other.channel
            && distribution == other.distribution
            && artifactKind == other.artifactKind
            && sourceCommit == other.sourceCommit
            && baseRuntimeID == other.baseRuntimeID
            && compatibilityID == other.compatibilityID
            && containsNativeCode == other.containsNativeCode
            && entrypoint == other.entrypoint
            && defaultArguments == other.defaultArguments
            && capabilities == other.capabilities
            && components == other.components
    }
}

public enum RuntimeManifestError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unsupportedPlatform(platform: String, architecture: String)
    case missingRequiredField
    case overlayCompatibilityMissing
    case invalidPathComponent(field: String, value: String)
    case unsafeEntrypoint(String)
    case invalidSHA256

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Unsupported runtime manifest schema: \(version)"
        case .unsupportedPlatform(let platform, let architecture):
            "Unsupported runtime target: \(platform)-\(architecture)"
        case .missingRequiredField:
            "The runtime manifest is missing a required field."
        case .overlayCompatibilityMissing:
            "An engine overlay must name its base runtime and compatibility identity."
        case .invalidPathComponent(let field, let value):
            "Runtime \(field) is not a safe path component: \(value)"
        case .unsafeEntrypoint(let path):
            "The runtime entrypoint must be a safe relative path: \(path)"
        case .invalidSHA256:
            "The runtime SHA-256 value must contain 64 hexadecimal characters."
        }
    }
}
