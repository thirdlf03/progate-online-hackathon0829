import Foundation

/// セーフティーモードの三段階。
///
/// 設定値そのままの表示用。実際の可否判断は `SafetyPolicy` が行い、これは
/// メニューやオンボーディング(#54)に見せるラベルを決めるだけ。
public enum SafetyMode: Equatable, Sendable {
    /// 全 OFF。これが既定。
    case safety
    /// 一部 ON。ON の本数を添える。
    case custom(enabledCount: Int)
    /// 全 ON。
    case unlimited

    /// 一覧に出す日本語名。カスタムは「カスタム(3/7)」のように本数と総数を出す。
    public var label: String {
        switch self {
        case .safety: return "セーフティー"
        case .custom(let enabledCount):
            return "カスタム(\(enabledCount)/\(SafetyFeature.total))"
        case .unlimited: return "無制限"
        }
    }

    /// 設定からモードを決める。
    public static func of(_ settings: SafetySettings) -> SafetyMode {
        switch settings.enabled.count {
        case 0: return .safety
        case SafetyFeature.total: return .unlimited
        case let count: return .custom(enabledCount: count)
        }
    }
}
