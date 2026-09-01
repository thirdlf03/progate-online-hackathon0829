import Foundation
import Testing

@testable import MihariCore

/// セーフティートグルの変更可否ルール(合意済みの仕様)を検証する。
///
/// - OFF 方向(安全側)は常に即時。ただし quitLock の監視中 OFF と、canChangeLater == false
///   の間の予約(クーリングオフ)は例外。
/// - ON 方向は監視していないときだけ。requires が OFF なら拒否。
@Suite("セーフティーポリシー")
struct SafetyPolicyTests {

    /// 現在時刻。テストごとに固定して、発効時刻の計算を検証できるようにする。
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// 24 時間後の時刻。`now` と組で使う。
    private var due: Date {
        now.addingTimeInterval(SafetyPolicy.coolingOffInterval)
    }

    private func makeSettings(
        enabled: Set<SafetyFeature> = [],
        canChangeLater: Bool = true,
        pending: SafetyPendingChange? = nil
    ) -> SafetySettings {
        var settings = SafetySettings()
        settings.enabled = enabled
        settings.canChangeLater = canChangeLater
        settings.pendingChange = pending
        return settings
    }

    // MARK: - OFF 方向は即時

    @Test("OFF は即時に効く")
    func disablingAppliesImmediately() {
        let current = makeSettings(enabled: [.macCamera, .iphonePresence])

        let decision = SafetyPolicy.decide(
            .disable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.iphonePresence])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("OFF にすると従属(requires で繋がった先)も落ちる")
    func disablingPullsDependents() {
        // iphoneScreenshot は iphonePresence を requires に持つ。
        let current = makeSettings(enabled: [.iphonePresence, .iphoneScreenshot])

        let decision = SafetyPolicy.decide(
            .disable(.iphonePresence),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("quitLock は監視中に OFF にできない")
    func quitLockCannotBeDisabledWhileWatching() {
        let current = makeSettings(enabled: [.quitLock, .macCamera])

        let decision = SafetyPolicy.decide(
            .disable(.quitLock),
            current: current,
            isWatching: true,
            now: now
        )

        #expect(decision == .reject(.quitLockWhileWatching))
    }

    @Test("quitLock は監視していなければ OFF にできる")
    func quitLockCanBeDisabledWhenNotWatching() {
        let current = makeSettings(enabled: [.quitLock])

        let decision = SafetyPolicy.decide(
            .disable(.quitLock),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("canChangeLater == false の間は OFF も 24 時間後の予約になる")
    func disablingSchedulesDuringCoolingOff() {
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .disable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(enabled: [.macCamera], canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            disabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        // 予約は積むが、まだ OFF にしない。
        #expect(decision == .schedule(expected))
    }

    @Test("予約が既にあれば disabling は和集合になり、発効は今回の 24 時間後に置き換わる")
    func schedulingMergesDisablingAndResetsEffectiveAt() {
        let previous = SafetyPendingChange(
            disabling: [.quitLock],
            restoresChangeability: false,
            effectiveAt: now.addingTimeInterval(60 * 60)  // 1 時間前に入れた予約
        )
        let current = makeSettings(
            enabled: [.macCamera, .quitLock],
            canChangeLater: false,
            pending: previous
        )

        let decision = SafetyPolicy.decide(
            .disable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(
            enabled: [.macCamera, .quitLock],
            canChangeLater: false
        )
        expected.pendingChange = SafetyPendingChange(
            disabling: [.quitLock, .macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        #expect(decision == .schedule(expected))
    }

    @Test("監視中は予約された OFF でも quitLock だけは残して予約する")
    func disablingDuringCoolingOffStillRespectsQuitLock() {
        // canChangeLater == false かつ監視中は、quitLock は OFF 予約にすら入れない。
        let current = makeSettings(enabled: [.macCamera, .quitLock], canChangeLater: false)
        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: true,
            now: now
        )
        // schedule の disabling に quitLock が入っていないことを直接検証する。
        guard case .schedule(let scheduled) = decision else {
            Issue.record("disableAll が schedule になっていない")
            return
        }
        #expect(scheduled.pendingChange?.disabling == Set(SafetyFeature.allCases).subtracting([.quitLock]))
        #expect(scheduled.pendingChange?.effectiveAt == due)
    }

    // MARK: - ON 方向

    @Test("ON は監視中は拒否される")
    func enablingWhileWatchingIsRejected() {
        let current = makeSettings()

        let decision = SafetyPolicy.decide(
            .enable(.macCamera),
            current: current,
            isWatching: true,
            now: now
        )

        #expect(decision == .reject(.enablingWhileWatching))
    }

    @Test("ON は監視していなければ即時に効く")
    func enablingAppliesWhenNotWatching() {
        let current = makeSettings(enabled: [.macCamera])

        let decision = SafetyPolicy.decide(
            .enable(.discordExposure),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.macCamera, .discordExposure])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("requires が OFF なら ON を拒否する")
    func enablingWithoutDependencyIsRejected() {
        let current = makeSettings()

        let decision = SafetyPolicy.decide(
            .enable(.iphoneScreenshot),
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .reject(.dependencyMissing(.iphonePresence)))
    }

    @Test("requires が ON なら iPhone の画面撮りも ON にできる")
    func enablingWithDependencyApplies() {
        let current = makeSettings(enabled: [.iphonePresence])

        let decision = SafetyPolicy.decide(
            .enable(.iphoneScreenshot),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.iphonePresence, .iphoneScreenshot])
        #expect(decision == .apply(expected, skipped: []))
    }

    // MARK: - 全部切り替え

    @Test("enableAll は監視中でなければ全 ON、監視中は拒否")
    func enableAll() {
        let current = makeSettings(enabled: [.macCamera])

        let whileWatching = SafetyPolicy.decide(
            .enableAll,
            current: current,
            isWatching: true,
            now: now
        )
        #expect(whileWatching == .reject(.enablingWhileWatching))

        let notWatching = SafetyPolicy.decide(
            .enableAll,
            current: current,
            isWatching: false,
            now: now
        )
        let expected = makeSettings(enabled: Set(SafetyFeature.allCases))
        #expect(notWatching == .apply(expected, skipped: []))
    }

    @Test("disableAll は監視中なら quitLock だけ残して残りを落とす")
    func disableAllSkipsQuitLockWhileWatching() {
        let current = makeSettings(enabled: Set(SafetyFeature.allCases))

        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: true,
            now: now
        )

        let expected = makeSettings(enabled: [.quitLock])
        #expect(decision == .apply(expected, skipped: [.quitLock]))
    }

    @Test("disableAll は監視していなければ全部落とす")
    func disableAllTurnsEverythingOffWhenNotWatching() {
        let current = makeSettings(enabled: Set(SafetyFeature.allCases))

        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .apply(.default, skipped: []))
    }

    @Test("disableAll は canChangeLater == false なら全体を予約にする")
    func disableAllSchedulesDuringCoolingOff() {
        let current = makeSettings(enabled: [.macCamera, .discordExposure], canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(
            enabled: [.macCamera, .discordExposure],
            canChangeLater: false
        )
        // OFF 方向の予約は「全部を切る」意図のまま、全機能が対象になる。
        expected.pendingChange = SafetyPendingChange(
            disabling: Set(SafetyFeature.allCases),
            restoresChangeability: false,
            effectiveAt: due
        )
        #expect(decision == .schedule(expected))
    }

    // MARK: - 変更可能性の切り替え

    @Test("setCanChangeLater(false) は即時に効く")
    func disablingChangeabilityAppliesImmediately() {
        let current = makeSettings(enabled: [.macCamera])

        let decision = SafetyPolicy.decide(
            .setCanChangeLater(false),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.macCamera], canChangeLater: false)
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("setCanChangeLater(true) はすでに true なら何もしない")
    func restoringChangeabilityWhenAlreadyEnabledDoesNothing() {
        let current = makeSettings(enabled: [.macCamera])

        let decision = SafetyPolicy.decide(
            .setCanChangeLater(true),
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .apply(current, skipped: []))
    }

    @Test("setCanChangeLater(true) は false からなら 24 時間後の予約になる")
    func restoringChangeabilityFromFalseSchedules() {
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .setCanChangeLater(true),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(enabled: [.macCamera], canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            disabling: [],
            restoresChangeability: true,
            effectiveAt: due
        )
        #expect(decision == .schedule(expected))
    }

    @Test("cancelPendingChange は即時に予約を消す")
    func cancelPendingChangeClearsReservation() {
        let pending = SafetyPendingChange(
            disabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false, pending: pending)

        let decision = SafetyPolicy.decide(
            .cancelPendingChange,
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.macCamera], canChangeLater: false)
        #expect(decision == .apply(expected, skipped: []))
    }

    // MARK: - 予約の発効

    @Test("発効時刻前なら予約は適用されない")
    func pendingChangeDoesNotApplyBeforeEffectiveAt() {
        let pending = SafetyPendingChange(
            disabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: now)

        #expect(applied == current)
    }

    @Test("発効時刻が来たら予約どおり OFF にして pendingChange を消す")
    func pendingChangeAppliesAtEffectiveAt() {
        let pending = SafetyPendingChange(
            disabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied == makeSettings(enabled: [], canChangeLater: false))
    }

    @Test("適用時に従属も巻き込んで OFF にする")
    func pendingChangePullsDependents() {
        let pending = SafetyPendingChange(
            disabling: [.iphonePresence],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(
            enabled: [.iphonePresence, .iphoneScreenshot],
            canChangeLater: false,
            pending: pending
        )

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied.enabled.isEmpty)
        #expect(applied.pendingChange == nil)
    }

    @Test("restoresChangeability が true なら発効時に変更可能性も戻す")
    func pendingChangeRestoresChangeability() {
        let pending = SafetyPendingChange(
            disabling: [],
            restoresChangeability: true,
            effectiveAt: due
        )
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied.canChangeLater)
        #expect(applied.pendingChange == nil)
        // 戻しただけでは ON の機能は変わらない。
        #expect(applied.enabled == [.macCamera])
    }

    @Test("発効後も依存を満たさない ON は normalized が落とす")
    func pendingChangeResultIsNormalized() {
        // 予約が「iphonePresence」だけを落とし、iphoneScreenshot は予約漏れしていた状況。
        let pending = SafetyPendingChange(
            disabling: [.iphonePresence],
            restoresChangeability: false,
            effectiveAt: due
        )
        // 依存を満たさない iphoneScreenshot が ON のまま残ることはない。
        let current = makeSettings(enabled: [.iphoneScreenshot], canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied.enabled.isEmpty)
    }
}
