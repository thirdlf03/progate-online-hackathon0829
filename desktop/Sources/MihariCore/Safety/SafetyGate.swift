import Foundation

/// ゲートが OFF の機能を呼び出そうとしたときのエラー。
public enum SafetyGateError: Error, Equatable, Sendable {
    case featureDisabled(SafetyFeature)
}

/// 機能ごとの ON/OFF を、他スレッドから同期に読める判定口。
///
/// 実行部(カメラ・オーバーレイなど)はここに `check` を投げるだけでよく、
/// 設定の保存やロックの存在を知らなくてよい。実体は `SafetySettingsStore` が
/// `OSAllocatedUnfairLock` で守ったスナップショットから作る。
public struct SafetyGate: Sendable {

    private let isEnabled: @Sendable (SafetyFeature) -> Bool

    public init(isEnabled: @escaping @Sendable (SafetyFeature) -> Bool) {
        self.isEnabled = isEnabled
    }

    /// ON かどうか。
    public func isEnabled(_ feature: SafetyFeature) -> Bool {
        isEnabled(feature)
    }

    /// OFF なら `SafetyGateError.featureDisabled` を投げる。実行部は呼び出しの先頭でこれを通す。
    public func check(_ feature: SafetyFeature) throws {
        guard isEnabled(feature) else {
            throw SafetyGateError.featureDisabled(feature)
        }
    }

    /// 全部 ON(= ゲートが無いときと同じ振る舞い)。既定値。
    public static let allowAll = SafetyGate(isEnabled: { _ in true })

    /// 全部 OFF。テストや開発用。
    public static let denyAll = SafetyGate(isEnabled: { _ in false })
}
