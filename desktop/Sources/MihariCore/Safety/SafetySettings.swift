import Foundation

/// 予約(runtime に発効する変更)の 1 本分。
///
/// `canChangeLater == false` のクーリングオフ中に「ON にする」や「設定変更を
/// 許可し直す」を頼まれたとき、24 時間後にこの 1 本にまとめて発効する。
/// OFF 方向(安全側)は予約に入らない——常に即時なので。
public struct SafetyPendingChange: Codable, Equatable, Sendable {
    /// 発効時に ON にする機能。
    public var enabling: Set<SafetyFeature>
    /// 発効時に `canChangeLater` を true に戻すか。
    public var restoresChangeability: Bool
    /// 発効時刻。この時刻以前になったら適用する。
    public var effectiveAt: Date

    public init(
        enabling: Set<SafetyFeature>,
        restoresChangeability: Bool,
        effectiveAt: Date
    ) {
        self.enabling = enabling
        self.restoresChangeability = restoresChangeability
        self.effectiveAt = effectiveAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 旧形式は OFF 方向を積む `disabling` キーだった。OFF は今や常に即時なので、
        // 旧キーは読まずに捨てる。`enabling` が無い保存値は空集合として読む
        // (= 変更可否を戻すだけの予約になる)。
        enabling = try container.decodeIfPresent(Set<SafetyFeature>.self, forKey: .enabling) ?? []
        restoresChangeability = try container.decode(Bool.self, forKey: .restoresChangeability)
        effectiveAt = try container.decode(Date.self, forKey: .effectiveAt)
    }
}

/// セーフティーモードの設定一式。
///
/// 既定は全 OFF(`enabled` が空)で、ユーザーが明示的に ON にした機能だけが動く。
/// `UserDefaults` に JSON(Data)で保存する。Codable の将来のキー追加に耐えるよう、
/// 欠けたキーは `init(from:)` で既定値に埋める。
public struct SafetySettings: Codable, Equatable, Sendable {

    /// いま ON の機能。既定は全 OFF(= セーフティーモード)。
    public var enabled: Set<SafetyFeature> = []
    /// 「あとで設定を変えられるようにする」。false の間は ON 方向が予約(クーリングオフ)になる。
    public var canChangeLater: Bool = true
    /// 発効待ちの予約。無ければ nil。
    public var pendingChange: SafetyPendingChange? = nil
    /// 執行猶予からの脱出を最後に使った時刻。#52(終了ブロック)が使う。
    public var lastEscapeAt: Date? = nil

    public static let `default` = SafetySettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 将来のバージョンが足したキーが無くても、既存の保存値はそのまま読めるようにする。
        // 欠けたキーは既定値で埋める(== SafetySettings() と同じ値)。
        enabled = try container.decodeIfPresent(Set<SafetyFeature>.self, forKey: .enabled) ?? []
        canChangeLater = try container.decodeIfPresent(Bool.self, forKey: .canChangeLater) ?? true
        pendingChange = try container.decodeIfPresent(SafetyPendingChange.self, forKey: .pendingChange)
        lastEscapeAt = try container.decodeIfPresent(Date.self, forKey: .lastEscapeAt)
    }

    /// ON かどうか。
    public func isEnabled(_ feature: SafetyFeature) -> Bool {
        enabled.contains(feature)
    }

    /// この設定のモード(セーフティー / カスタム / 無制限)。
    public var mode: SafetyMode {
        SafetyMode.of(self)
    }

    /// 依存を満たさない ON を落とした設定を返す。
    ///
    /// `iphonePresence` が OFF なのに `iphoneScreenshot` が ON、のような不整合を直す。
    /// 保存値は起動時にこの整形を通すので、通常は起こらない形だが、防御として
    /// 変更のたびにも通せるようにしておく。
    public func normalized() -> SafetySettings {
        var result = self
        for feature in SafetyFeature.allCases {
            if let required = feature.requires, !result.enabled.contains(required) {
                result.enabled.remove(feature)
            }
        }
        return result
    }
}
