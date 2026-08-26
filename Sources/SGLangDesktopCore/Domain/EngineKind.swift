import Foundation

public enum EngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sglang
    case sglangOmni = "sglang-omni"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sglang:
            "SGLang"
        case .sglangOmni:
            "SGLang-Omni"
        }
    }
}
