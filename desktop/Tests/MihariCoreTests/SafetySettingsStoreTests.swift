import Foundation
import Testing

@testable import MihariCore

/// セーフティー設定の保存・復元・移行・環境変数上書き・gate の追従・daemonPayload を検証する。
@Suite("セーフティー設定ストア")
@MainActor
struct SafetySettingsStoreTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が設定を共有しないようにする。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "mihari.test.safetyStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// 現在時刻。予約の発効時刻の検証で固定しておく。
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("何も保存されていなければ全 OFF のセーフティーモード")
    func startsAsSafetyMode() {
        let store = SafetySettingsStore(defaults: makeDefaults(), environment: [:])
        defer { store.stop() }

        #expect(store.settings == .default)
        #expect(store.mode == .safety)
        #expect(!store.hasCompletedModeSelection)
    }

    @Test("request した変更が保存され、次のストアが復元する")
    func requestIsPersistedAndRestored() {
        let defaults = makeDefaults()
        let store = SafetySettingsStore(defaults: defaults, environment: [:])
        defer { store.stop() }

        let decision = store.request(.enable(.macCamera), isWatching: false)
        #expect(decision == .apply(store.settings, skipped: []))

        let reloaded = SafetySettingsStore(defaults: defaults, environment: [:])
        defer { reloaded.stop() }
        #expect(reloaded.isEnabled(.macCamera))
    }

    @Test("監視中の ON 依頼も即時に効いて保存される")
    func enablingWhileWatchingIsAppliedAndSaved() {
        let defaults = makeDefaults()
        let store = SafetySettingsStore(defaults: defaults, environment: [:])
        defer { store.stop() }

        let decision = store.request(.enable(.macCamera), isWatching: true)

        #expect(decision == .apply(store.settings, skipped: []))
        #expect(store.isEnabled(.macCamera))
        #expect(defaults.data(forKey: SafetySettingsStore.defaultsKey) != nil)
    }

    @Test("旧「スクショに写り込む」キーは値を引き継がず削除する")
    func legacyPhotobombKeyIsRemoved() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: SafetySettingsStore.legacyPhotobombKey)

        let store = SafetySettingsStore(defaults: defaults, environment: [:])
        defer { store.stop() }

        // 全 OFF から始まる(値は引き継がない)。
        #expect(store.settings == .default)
        #expect(store.isEnabled(.photobomb) == false)
        #expect(defaults.object(forKey: SafetySettingsStore.legacyPhotobombKey) == nil)
    }

    @Test("保存値があれば旧キーは触らない")
    func legacyPhotobombKeyDoesNotMatterWhenSavedSettingsExist() {
        let defaults = makeDefaults()
        let store = SafetySettingsStore(defaults: defaults, environment: [:])
        store.request(.enable(.macCamera), isWatching: false)
        store.stop()
        defaults.set(true, forKey: SafetySettingsStore.legacyPhotobombKey)

        let reloaded = SafetySettingsStore(defaults: defaults, environment: [:])
        defer { reloaded.stop() }
        #expect(reloaded.isEnabled(.macCamera))
    }

    @Test("環境変数で enabled を上書きするが、保存しない")
    func environmentOverridesWithoutSaving() {
        let defaults = makeDefaults()
        let env = [SafetySettingsStore.environmentKey: "macCamera,iphonePresence"]

        let store = SafetySettingsStore(defaults: defaults, environment: env, now: { self.now })
        defer { store.stop() }
        #expect(store.isEnabled(.macCamera))
        #expect(store.isEnabled(.iphonePresence))

        // 保存されていないので、環境変数を外すと全 OFF に戻る。
        let reloaded = SafetySettingsStore(defaults: defaults, environment: [:], now: { self.now })
        defer { reloaded.stop() }
        #expect(reloaded.settings == .default)
    }

    @Test("環境変数 all は全 ON を意味する")
    func environmentAllEnablesEverything() {
        let store = SafetySettingsStore(
            defaults: makeDefaults(),
            environment: [SafetySettingsStore.environmentKey: "all"],
            now: { self.now }
        )
        defer { store.stop() }

        #expect(store.settings.enabled == Set(SafetyFeature.allCases))
        #expect(store.mode == .unlimited)
    }

    @Test("環境変数の上書きも normalized を通す")
    func environmentOverrideIsNormalized() {
        // iphoneScreenshot だけ渡しても、前提の iphonePresence が無いので立たない。
        // ここを通さないと、依存の壊れた組み合わせが bridge へ渡ってしまう。
        let store = SafetySettingsStore(
            defaults: makeDefaults(),
            environment: [SafetySettingsStore.environmentKey: "iphoneScreenshot"],
            now: { self.now }
        )
        defer { store.stop() }

        #expect(store.settings.enabled.isEmpty)
        #expect(store.daemonPayload.features.iphoneScreenshot == false)

        // 前提と一緒に渡せば両方立つ。
        let both = SafetySettingsStore(
            defaults: makeDefaults(),
            environment: [SafetySettingsStore.environmentKey: "iphonePresence,iphoneScreenshot"],
            now: { self.now }
        )
        defer { both.stop() }
        #expect(both.settings.enabled == [.iphonePresence, .iphoneScreenshot])
    }

    @Test("環境変数の無効な名前は無視する")
    func environmentIgnoresUnknownNames() {
        let features = SafetySettingsStore.parseEnvironment("macCamera,bogus,iphonePresence")
        #expect(features == [.macCamera, .iphonePresence])

        // 空白と重複も受け流し、空は空になる。
        #expect(SafetySettingsStore.parseEnvironment("") == [])
        #expect(SafetySettingsStore.parseEnvironment(" macCamera , macCamera ") == [.macCamera])
    }

    @Test("gate は settings の変化に追従し、OFF なら check が投げる")
    func gateFollowsSettings() throws {
        let store = SafetySettingsStore(defaults: makeDefaults(), environment: [:])
        defer { store.stop() }

        #expect(store.gate.isEnabled(.macCamera) == false)
        #expect(throws: SafetyGateError.featureDisabled(.macCamera)) {
            try store.gate.check(.macCamera)
        }

        store.request(.enable(.macCamera), isWatching: false)
        #expect(store.gate.isEnabled(.macCamera))
        // 他の機能はまだ OFF のまま。
        #expect(store.gate.isEnabled(.discordExposure) == false)

        store.request(.disable(.macCamera), isWatching: false)
        #expect(store.gate.isEnabled(.macCamera) == false)
    }

    @Test("daemonPayload はデーモンへ渡す 3 本の ON/OFF を映す")
    func daemonPayloadReflectsForwardedFeatures() {
        let defaults = makeDefaults()
        let store = SafetySettingsStore(defaults: defaults, environment: [:])
        defer { store.stop() }

        #expect(store.daemonPayload == SafetyDaemonPayload(settings: .default))
        #expect(
            store.daemonPayload.features
                == SafetyDaemonPayload.Features(
                    iphonePresence: false,
                    iphoneScreenshot: false,
                    discordExposure: false
                )
        )

        // デーモンに渡さない機能(macCamera)は payload に出ない。
        store.request(.enable(.macCamera), isWatching: false)
        store.request(.enable(.iphonePresence), isWatching: false)
        store.request(.enable(.discordExposure), isWatching: false)

        let payload = store.daemonPayload
        #expect(payload.features.iphonePresence)
        #expect(!payload.features.iphoneScreenshot)
        #expect(payload.features.discordExposure)
    }

    @Test("canChangeLater == false の間の ON は予約になり、期限が来たら適用されて保存される")
    func pendingEnableAppliesAndPersistsAfterCoolingOff() {
        let defaults = makeDefaults()
        let store = SafetySettingsStore(
            defaults: defaults,
            environment: [:],
            now: { self.now }
        )
        store.request(.setCanChangeLater(false), isWatching: false)
        // クーリングオフ中の ON は予約になる。
        let decision = store.request(.enable(.macCamera), isWatching: false)

        guard case .schedule = decision else {
            Issue.record("ON が schedule になっていない: \(decision)")
            return
        }
        #expect(store.isEnabled(.macCamera) == false)  // 予約中はまだ OFF
        #expect(store.settings.pendingChange?.effectiveAt == now.addingTimeInterval(SafetyPolicy.coolingOffInterval))

        // 期限が来た状態で新しいストアを作ると、起動時適用で ON になっている。
        let afterDue = now.addingTimeInterval(SafetyPolicy.coolingOffInterval + 1)
        let reloaded = SafetySettingsStore(
            defaults: defaults,
            environment: [:],
            now: { afterDue }
        )
        defer { reloaded.stop() }
        #expect(reloaded.isEnabled(.macCamera))
        #expect(reloaded.settings.pendingChange == nil)
    }

    @Test("canChangeLater == false でも OFF は即時に効いて保存される")
    func disableAppliesImmediatelyDuringCoolingOff() {
        let defaults = makeDefaults()
        let store = SafetySettingsStore(defaults: defaults, environment: [:], now: { self.now })
        defer { store.stop() }

        store.request(.enable(.macCamera), isWatching: false)
        store.request(.setCanChangeLater(false), isWatching: false)
        let decision = store.request(.disable(.macCamera), isWatching: false)

        #expect(decision == .apply(store.settings, skipped: []))
        #expect(store.isEnabled(.macCamera) == false)
        #expect(store.settings.pendingChange == nil)
    }

    /// テストの途中で時刻を進められるようにするための箱。`now` クロージャ(@Sendable)が
    /// 参照するので、ロックは要らないが @unchecked で包む。
    private final class MutableClock: @unchecked Sendable {
        var value: Date
        init(_ value: Date) {
            self.value = value
        }
    }

    @Test("applyDuePendingChangeIfNeeded が期限の来た予約を適用して保存する")
    func applyDuePendingChangeIfNeededAppliesAndSaves() {
        let defaults = makeDefaults()
        let clock = MutableClock(now)
        let store = SafetySettingsStore(defaults: defaults, environment: [:], now: { clock.value })
        store.request(.setCanChangeLater(false), isWatching: false)
        store.request(.enable(.macCamera), isWatching: false)

        // 期限内は何も起きない。
        store.applyDuePendingChangeIfNeeded()
        #expect(store.isEnabled(.macCamera) == false)
        #expect(store.settings.pendingChange != nil)

        // 時刻が進んで期限が来たら、適用して保存する。
        clock.value = now.addingTimeInterval(SafetyPolicy.coolingOffInterval + 1)
        store.applyDuePendingChangeIfNeeded()
        #expect(store.isEnabled(.macCamera))
        #expect(store.settings.pendingChange == nil)

        // 保存されているので、新しいストアでも ON のまま。
        let reloaded = SafetySettingsStore(defaults: defaults, environment: [:], now: { self.now })
        defer { reloaded.stop() }
        #expect(reloaded.isEnabled(.macCamera))
        #expect(reloaded.settings.pendingChange == nil)
    }

    @Test("モード選択の完了フラグを立てて戻せる")
    func modeSelectionCompletionIsRemembered() {
        let defaults = makeDefaults()
        let store = SafetySettingsStore(defaults: defaults, environment: [:])
        defer { store.stop() }

        #expect(!store.hasCompletedModeSelection)
        store.markModeSelectionCompleted()
        #expect(store.hasCompletedModeSelection)
    }

    @Test("markEscapeUsed は前回の脱出時刻を覚えて保存する")
    func markEscapeUsedIsPersisted() {
        let defaults = makeDefaults()
        let escapeAt = Date(timeIntervalSince1970: 3_000_000)
        let store = SafetySettingsStore(defaults: defaults, environment: [:], now: { self.now })
        defer { store.stop() }

        #expect(store.settings.lastEscapeAt == nil)
        store.markEscapeUsed(at: escapeAt)
        #expect(store.settings.lastEscapeAt == escapeAt)

        let reloaded = SafetySettingsStore(defaults: defaults, environment: [:], now: { self.now })
        defer { reloaded.stop() }
        #expect(reloaded.settings.lastEscapeAt == escapeAt)
    }
}
