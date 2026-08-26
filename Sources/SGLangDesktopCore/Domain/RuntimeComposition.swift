import Foundation

/// A large immutable dependency base combined with a small engine code layer.
public struct RuntimeComposition: Equatable, Sendable {
    public let base: RuntimeInstallation
    public let overlay: RuntimeInstallation

    public init(base: RuntimeInstallation, overlay: RuntimeInstallation) throws {
        guard base.manifest.artifactKind == .base else {
            throw RuntimeCompositionError.expectedBase(base.manifest.artifactKind)
        }
        guard overlay.manifest.artifactKind == .engineOverlay else {
            throw RuntimeCompositionError.expectedOverlay(overlay.manifest.artifactKind)
        }
        guard overlay.manifest.baseRuntimeID == base.manifest.generationID else {
            throw RuntimeCompositionError.baseGenerationMismatch(
                expected: base.manifest.generationID,
                actual: overlay.manifest.baseRuntimeID
            )
        }
        guard overlay.manifest.compatibilityID == base.manifest.compatibilityID else {
            throw RuntimeCompositionError.compatibilityMismatch(
                base: base.manifest.compatibilityID,
                overlay: overlay.manifest.compatibilityID
            )
        }
        guard base.manifest.engine == overlay.manifest.engine else {
            throw RuntimeCompositionError.engineMismatch
        }

        self.base = base
        self.overlay = overlay
    }
}

public enum RuntimeCompositionError: LocalizedError, Equatable {
    case expectedBase(RuntimeArtifactKind)
    case expectedOverlay(RuntimeArtifactKind)
    case baseGenerationMismatch(expected: String, actual: String?)
    case compatibilityMismatch(base: String?, overlay: String?)
    case engineMismatch

    public var errorDescription: String? {
        switch self {
        case .expectedBase(let kind):
            "Expected a base runtime, got \(kind.rawValue)."
        case .expectedOverlay(let kind):
            "Expected an engine overlay, got \(kind.rawValue)."
        case .baseGenerationMismatch(let expected, let actual):
            "Engine overlay expects base \(actual ?? "none"), but \(expected) was selected."
        case .compatibilityMismatch(let base, let overlay):
            "Runtime compatibility mismatch: base=\(base ?? "none"), overlay=\(overlay ?? "none")."
        case .engineMismatch:
            "The base runtime and engine overlay belong to different engine families."
        }
    }
}
