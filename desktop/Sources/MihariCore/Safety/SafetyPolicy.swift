import Foundation

/// セーフティートグルへの操作。`SafetySettingsStore.request` やテストから投げる。
public enum SafetyChange: Equatable, Sendable {
    /// 1 本 ON にする。
    case enable(SafetyFeature)
    /// 1 本(とその従属)OFF にする。
    case disable(SafetyFeature)
    /// 全部 ON にする。
    case enableAll
    /// 全部 OFF にする。
    case disableAll
    /// 「あとで設定を変えられるようにする」を入れる / 切る。
    case setCanChangeLater(Bool)
    /// 発効待ちの予約を取り消す。
    case cancelPendingChange
}

/// 変更を拒否した理由。
public enum SafetyRejection: Equatable, Sendable {
    /// 緩める方向(ON)は監視していないときだけ。
    case enablingWhileWatching
    /// #5(終了ブロック)は監視中に OFF にできない。
    case quitLockWhileWatching
    /// 前提(requires)のトグルが OFF。
    case dependencyMissing(SafetyFeature)
}

/// 変更を受け付けた結果。
public enum SafetyDecision: Equatable, Sendable {
    /// 即時に効く。`skipped` は disableAll で quitLock を残した等、依頼どおり
    /// できなかったものを積む。
    case apply(SafetySettings, skipped: [SafetyFeature])
    /// 予約(pendingChange)を積んで 24 時間後に発効させる。
    case schedule(SafetySettings)
    /// 拒否。何も変わらない。
    case reject(SafetyRejection)
}

/// セーフティートグルの変更可否を決める純粋ロジック。副作用なし。
///
/// 合意済みのルール:
/// - OFF 方向(安全側)は常に即時。ただし例外 2 つ:
///   (a) `quitLock` は監視中に OFF にできない
///   (b) `canChangeLater == false` の間は OFF も 24 時間後の予約になる
/// - ON 方向は監視していないときだけ。`requires` が OFF なら reject
public enum SafetyPolicy {

    /// クーリングオフ期間。`canChangeLater == false` の間の変更はここまで発効が延びる。
    public static let coolingOffInterval: TimeInterval = 24 * 60 * 60

    /// 変更を受け付けるか決める。
    public static func decide(
        _ change: SafetyChange,
        current: SafetySettings,
        isWatching: Bool,
        now: Date
    ) -> SafetyDecision {
        switch change {
        case .enable(let feature):
            return decideEnable(feature, current: current, isWatching: isWatching)
        case .disable(let feature):
            return decideDisable(feature, current: current, isWatching: isWatching, now: now)
        case .enableAll:
            if isWatching {
                return .reject(.enablingWhileWatching)
            }
            var settings = current
            settings.enabled = Set(SafetyFeature.allCases)
            return .apply(settings, skipped: [])
        case .disableAll:
            return decideDisableAll(current: current, isWatching: isWatching, now: now)
        case .setCanChangeLater(let enabled):
            if enabled {
                return decideRestoreChangeability(current: current, now: now)
            }
            var settings = current
            settings.canChangeLater = false
            return .apply(settings, skipped: [])
        case .cancelPendingChange:
            var settings = current
            settings.pendingChange = nil
            return .apply(settings, skipped: [])
        }
    }

    /// 発効時刻が来た予約を適用する。来ていなければそのまま返す。
    ///
    /// 適用した結果は必ず `normalized()` を通す(予約に従属だけが入っていた等でも
    /// 不整合が残らないように)。
    public static func applyingDuePendingChange(_ settings: SafetySettings, now: Date) -> SafetySettings {
        guard let pending = settings.pendingChange, pending.effectiveAt <= now else {
            return settings
        }
        var result = settings
        // 予約された機能と、その従属(iphonePresence を OFF → iphoneScreenshot も OFF)を落とす。
        var disabling = pending.disabling
        for feature in pending.disabling {
            disabling.formUnion(feature.dependents)
        }
        result.enabled.subtract(disabling)
        if pending.restoresChangeability {
            result.canChangeLater = true
        }
        result.pendingChange = nil
        return result.normalized()
    }

    // MARK: - ON 方向

    private static func decideEnable(
        _ feature: SafetyFeature,
        current: SafetySettings,
        isWatching: Bool
    ) -> SafetyDecision {
        // 緩める方向は、監視していないときにだけ認める。
        // 監視中に ON を許すと演出が途中で変わって「設定にない機能」が動き出すため。
        if isWatching {
            return .reject(.enablingWhileWatching)
        }
        if let required = feature.requires, !current.enabled.contains(required) {
            return .reject(.dependencyMissing(required))
        }
        var settings = current
        settings.enabled.insert(feature)
        return .apply(settings, skipped: [])
    }

    // MARK: - OFF 方向

    private static func decideDisable(
        _ feature: SafetyFeature,
        current: SafetySettings,
        isWatching: Bool,
        now: Date
    ) -> SafetyDecision {
        // (a) #5 は監視中に OFF にできない。監視を外せないためのロックを外す抜け道になる。
        if feature == .quitLock, isWatching, current.enabled.contains(.quitLock) {
            return .reject(.quitLockWhileWatching)
        }

        // 従属も同時に OFF にする(iphonePresence を OFF → iphoneScreenshot も OFF)。
        var disabling = Set([feature])
        disabling.formUnion(feature.dependents)

        // (b) クーリングオフ中は OFF も即時ではなく 24 時間後の予約になる。
        guard current.canChangeLater else {
            return schedule(
                pendingDisabling: disabling,
                restoresChangeability: false,
                over: current,
                now: now
            )
        }
        var settings = current
        settings.enabled.subtract(disabling)
        return .apply(settings, skipped: [])
    }

    private static func decideDisableAll(
        current: SafetySettings,
        isWatching: Bool,
        now: Date
    ) -> SafetyDecision {
        var disabling = Set(SafetyFeature.allCases)
        var skipped: [SafetyFeature] = []
        // 全機能に disable のルールを適用する。quitLock だけは監視中に外せないので、
        // ON のまま残して「残した」ことを skipped で伝える。
        if isWatching, current.enabled.contains(.quitLock) {
            disabling.remove(.quitLock)
            skipped = [.quitLock]
        }

        guard current.canChangeLater else {
            return schedule(
                pendingDisabling: disabling,
                restoresChangeability: false,
                over: current,
                now: now
            )
        }
        var settings = current
        settings.enabled.subtract(disabling)
        return .apply(settings, skipped: skipped)
    }

    /// 「あとで設定を変えられるようにする」を戻す。
    ///
    /// すでに true なら何もしない。false から true へは「無効化の強度を下げる」方向なので、
    /// これもクーリングオフの予約になる。
    private static func decideRestoreChangeability(
        current: SafetySettings,
        now: Date
    ) -> SafetyDecision {
        if current.canChangeLater {
            return .apply(current, skipped: [])
        }
        return schedule(
            pendingDisabling: current.pendingChange?.disabling ?? [],
            restoresChangeability: true,
            over: current,
            now: now
        )
    }

    /// pendingChange に予約を積む。
    ///
    /// 既に pending があれば `disabling` は和集合にし、`restoresChangeability` は
    /// どちらかが true なら true にする。`effectiveAt` は今回の `now + coolingOffInterval`
    /// で置き換える(発効は常に「依頼を出して 24 時間後」)。
    private static func schedule(
        pendingDisabling: Set<SafetyFeature>,
        restoresChangeability: Bool,
        over current: SafetySettings,
        now: Date
    ) -> SafetyDecision {
        var settings = current
        let previous = current.pendingChange
        let pending = SafetyPendingChange(
            disabling: (previous?.disabling ?? []).union(pendingDisabling),
            restoresChangeability: (previous?.restoresChangeability ?? false) || restoresChangeability,
            effectiveAt: now.addingTimeInterval(coolingOffInterval)
        )
        settings.pendingChange = pending
        return .schedule(settings)
    }
}
