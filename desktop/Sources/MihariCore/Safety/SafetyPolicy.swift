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
    /// 予約(pendingChange)を積んで 24 時間後に発効させる。`skipped` の意味は
    /// `apply` と同じ(いまは予約になる経路で残すものが無いので常に空)。
    case schedule(SafetySettings, skipped: [SafetyFeature])
    /// 拒否。何も変わらない。
    case reject(SafetyRejection)
}

/// セーフティートグルの変更可否を決める純粋ロジック。副作用なし。
///
/// 合意済みのルール(Epic #58「トグルの変更ルール」):
/// - OFF 方向(安全側)は**常に即時**。例外は `quitLock` を監視中に OFF にできないことだけ
/// - ON 方向(緩める)は**監視していないときだけ**。`requires` が OFF なら reject
/// - `canChangeLater == false` の間は、ON 方向が即時ではなく **24 時間後の予約**になる。
///   「あとで設定を変えられるようにする」を ON に戻す操作も同じく予約になる
public enum SafetyPolicy {

    /// クーリングオフ期間。`canChangeLater == false` の間の ON はここまで発効が延びる。
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
            return decideEnable(feature, current: current, isWatching: isWatching, now: now)
        case .disable(let feature):
            return decideDisable(feature, current: current, isWatching: isWatching)
        case .enableAll:
            return decideEnableAll(current: current, isWatching: isWatching, now: now)
        case .disableAll:
            return decideDisableAll(current: current, isWatching: isWatching)
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
    /// ここでは**監視中かどうかを見ない**。ON 方向を監視中に禁じているのは「その場の
    /// 思いつきで演出が変わる」のを防ぐためで、予約は 24 時間の熟慮を経ている。しかも
    /// 監視は起動と同時に始まってほぼ常時続くので、監視中を理由に見送ると予約が永久に
    /// 発効しなくなる。
    ///
    /// 適用した結果は必ず `normalized()` を通す(予約に従属だけが入っていた等でも
    /// 不整合が残らないように)。
    public static func applyingDuePendingChange(_ settings: SafetySettings, now: Date) -> SafetySettings {
        guard let pending = settings.pendingChange, pending.effectiveAt <= now else {
            return settings
        }
        var result = settings
        result.enabled.formUnion(pending.enabling)
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
        isWatching: Bool,
        now: Date
    ) -> SafetyDecision {
        // 緩める方向は、監視していないときにだけ認める。
        // 監視中に ON を許すと演出が途中で変わって「設定にない機能」が動き出すため。
        if isWatching {
            return .reject(.enablingWhileWatching)
        }
        // 依存は「いま ON」だけでなく「同じ予約で ON になる予定」も満たしたとみなす。
        // 予約中に iphonePresence → iphoneScreenshot の順で頼めるようにするため。
        if let required = feature.requires, !effectiveEnabled(current).contains(required) {
            return .reject(.dependencyMissing(required))
        }
        guard current.canChangeLater else {
            return schedule(enabling: [feature], restoresChangeability: false, over: current, now: now)
        }
        var settings = current
        settings.enabled.insert(feature)
        return .apply(settings, skipped: [])
    }

    private static func decideEnableAll(
        current: SafetySettings,
        isWatching: Bool,
        now: Date
    ) -> SafetyDecision {
        if isWatching {
            return .reject(.enablingWhileWatching)
        }
        guard current.canChangeLater else {
            return schedule(
                enabling: Set(SafetyFeature.allCases),
                restoresChangeability: false,
                over: current,
                now: now
            )
        }
        var settings = current
        settings.enabled = Set(SafetyFeature.allCases)
        return .apply(settings, skipped: [])
    }

    // MARK: - OFF 方向

    /// OFF は `canChangeLater` に関係なく常に即時。予約中の ON があればそれも取り消す。
    private static func decideDisable(
        _ feature: SafetyFeature,
        current: SafetySettings,
        isWatching: Bool
    ) -> SafetyDecision {
        // #5 は監視中に OFF にできない。監視を外せないためのロックを外す抜け道になる。
        if feature == .quitLock, isWatching, current.enabled.contains(.quitLock) {
            return .reject(.quitLockWhileWatching)
        }

        // 従属も同時に OFF にする(iphonePresence を OFF → iphoneScreenshot も OFF)。
        var disabling = Set([feature])
        disabling.formUnion(feature.dependents)

        var settings = current
        settings.enabled.subtract(disabling)
        settings.pendingChange = removing(disabling, from: current.pendingChange)
        return .apply(settings, skipped: [])
    }

    private static func decideDisableAll(
        current: SafetySettings,
        isWatching: Bool
    ) -> SafetyDecision {
        var disabling = Set(SafetyFeature.allCases)
        var skipped: [SafetyFeature] = []
        // 全機能に disable のルールを適用する。quitLock だけは監視中に外せないので、
        // ON のまま残して「残した」ことを skipped で伝える。
        if isWatching, current.enabled.contains(.quitLock) {
            disabling.remove(.quitLock)
            skipped = [.quitLock]
        }

        var settings = current
        settings.enabled.subtract(disabling)
        // 「全部 OFF」なので、予約中の ON は quitLock を残す場合も含めて全部取り消す。
        settings.pendingChange = removing(Set(SafetyFeature.allCases), from: current.pendingChange)
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
        return schedule(enabling: [], restoresChangeability: true, over: current, now: now)
    }

    // MARK: - 予約の組み立て

    /// いま ON の機能に、予約で ON になる予定の機能を足したもの。依存の判定に使う。
    private static func effectiveEnabled(_ settings: SafetySettings) -> Set<SafetyFeature> {
        settings.enabled.union(settings.pendingChange?.enabling ?? [])
    }

    /// 予約から `features` を取り除く。空になり、変更可否も戻さないなら予約ごと消す。
    private static func removing(
        _ features: Set<SafetyFeature>,
        from pending: SafetyPendingChange?
    ) -> SafetyPendingChange? {
        guard var pending else { return nil }
        pending.enabling.subtract(features)
        if pending.enabling.isEmpty, !pending.restoresChangeability {
            return nil
        }
        return pending
    }

    /// pendingChange に予約を積む。
    ///
    /// 既に pending があれば `enabling` は和集合にし、`restoresChangeability` は
    /// どちらかが true なら true にする。`effectiveAt` は今回の `now + coolingOffInterval`
    /// で置き換える(発効は常に「最後に依頼を出して 24 時間後」。先に入れた予約も一緒に
    /// 延びるが、緩める方向を遅らせる側なので安全側として許容する)。
    private static func schedule(
        enabling: Set<SafetyFeature>,
        restoresChangeability: Bool,
        over current: SafetySettings,
        now: Date
    ) -> SafetyDecision {
        var settings = current
        let previous = current.pendingChange
        settings.pendingChange = SafetyPendingChange(
            enabling: (previous?.enabling ?? []).union(enabling),
            restoresChangeability: (previous?.restoresChangeability ?? false) || restoresChangeability,
            effectiveAt: now.addingTimeInterval(coolingOffInterval)
        )
        return .schedule(settings, skipped: [])
    }
}
