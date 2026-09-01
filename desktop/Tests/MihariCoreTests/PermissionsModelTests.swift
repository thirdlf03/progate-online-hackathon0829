import Foundation
import Testing

@testable import MihariCore

@Suite("オンボーディングの状態")
@MainActor
struct PermissionsModelTests {

    /// 実際の TCC プロンプトを出さない要求スタブ。呼ばれた権限を記録する。
    private final class RequestSpy: @unchecked Sendable {
        private(set) var requested: [PermissionKind] = []

        func request(_ kind: PermissionKind) async -> String {
            requested.append(kind)
            return "\(kind.title): stub"
        }

        func clear() {
            requested.removeAll()
        }
    }

    private typealias Checker = @Sendable () -> [PermissionKind: PermissionState]

    /// 実機の TCC を見に行かず、指定した権限だけを許可済みとして返す照会スタブ。
    private static func checker(granting granted: Set<PermissionKind>) -> Checker {
        {
            PermissionKind.allCases.reduce(into: [:]) { states, kind in
                states[kind] = PermissionState(
                    grant: granted.contains(kind) ? .granted : .denied,
                    detail: "stub"
                )
            }
        }
    }

    private func makeDefaults() -> UserDefaults {
        // 実行のたびに空の UserDefaults を使い、テスト同士が初回起動フラグを共有しないようにする。
        let suiteName = "mihari.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// macCamera だけ ON にした設定を作る。モデルの初期設定(全 OFF)と区別しやすくする。
    private func macCameraOnlySettings() -> SafetySettings {
        var settings = SafetySettings.default
        settings.enabled = [.macCamera]
        return settings
    }

    @Test("初期状態ではすべて未チェックで、未許可として数えられる")
    func startsUnchecked() {
        let model = PermissionsModel(defaults: makeDefaults())
        #expect(model.lastCheckedAt == nil)
        for kind in PermissionKind.allCases {
            #expect(model.state(for: kind) == .unchecked)
        }
        #expect(model.pending.count == PermissionKind.allCases.count)
    }

    @Test("refresh すると全権限の状態が入り、チェック時刻が記録される")
    func refreshFillsEveryKind() {
        let model = PermissionsModel(defaults: makeDefaults())
        model.refresh()
        #expect(model.lastCheckedAt != nil)
        for kind in PermissionKind.allCases {
            #expect(model.state(for: kind) != .unchecked, "状態が入っていない: \(kind.rawValue)")
        }
    }

    @Test("apply(settings:) で必須権限の判定が変わる")
    func applySettingsChangesRequired() {
        // 全 OFF ならカメラは必須ではないので、権限が無くても始められる。
        let model = PermissionsModel(
            defaults: makeDefaults(),
            checkPermissions: Self.checker(granting: [])
        )
        model.refresh()
        #expect(model.missingRequired.isEmpty)
        #expect(model.isRequiredSatisfied)

        // macCamera を ON に流し込むと、カメラが必須になる。
        model.apply(settings: macCameraOnlySettings())
        #expect(model.missingRequired == [.camera])
        #expect(!model.isRequiredSatisfied)

        // カメラが許可されていれば、同じ設定で満たされる。
        let satisfied = PermissionsModel(
            defaults: makeDefaults(),
            checkPermissions: Self.checker(granting: [.camera])
        )
        satisfied.apply(settings: macCameraOnlySettings())
        satisfied.refresh()
        #expect(satisfied.missingRequired.isEmpty)
        #expect(satisfied.isRequiredSatisfied)
    }

    @Test("全 OFF のときは権限画面に出す行も無い")
    func allOffShowsOnlyNothingRelevant() {
        let model = PermissionsModel(defaults: makeDefaults())
        // 全 OFF なら意味を持つ権限はモーションだけ(オンボーディングには任意の行として出る)。
        #expect(model.relevantKinds == [.motion])
        #expect(model.isRequiredSatisfied)
    }

    @Test("初回起動のまとめ要求は一度きりで、2 回目以降は勝手にプロンプトを出さない")
    func firstLaunchRequestRunsOnce() async {
        let defaults = makeDefaults()
        #expect(defaults.bool(forKey: PermissionsModel.didRequestOnLaunchKey) == false)

        let spy = RequestSpy()
        let model = PermissionsModel(defaults: defaults, requestPermission: spy.request)
        model.apply(settings: macCameraOnlySettings())
        await model.requestOnFirstLaunchIfNeeded()
        #expect(defaults.bool(forKey: PermissionsModel.didRequestOnLaunchKey) == true)
        #expect(spy.requested == [.camera])

        // 同じ defaults を引き継いだ別インスタンスでは、もう要求が走らない。
        let secondSpy = RequestSpy()
        let second = PermissionsModel(defaults: defaults, requestPermission: secondSpy.request)
        await second.requestOnFirstLaunchIfNeeded()
        #expect(secondSpy.requested.isEmpty)
        #expect(second.lastMessage == nil)
    }

    @Test("必須が 1 つでも欠けていれば見張り始めない")
    func requiredSatisfaction() {
        let settings = macCameraOnlySettings()

        let missing = PermissionsModel(
            defaults: makeDefaults(),
            checkPermissions: Self.checker(granting: [])
        )
        missing.apply(settings: settings)
        missing.refresh()
        #expect(missing.missingRequired == [.camera])
        #expect(!missing.isRequiredSatisfied)

        // 任意(画面収録 / オートメーション / モーション)は欠けていても始められる。
        let satisfied = PermissionsModel(
            defaults: makeDefaults(),
            checkPermissions: Self.checker(granting: [.camera, .screenRecording])
        )
        satisfied.apply(settings: settings)
        satisfied.refresh()
        #expect(satisfied.missingRequired.isEmpty)
        #expect(satisfied.isRequiredSatisfied)
        #expect(satisfied.pending == [.automation, .motion])
    }

    @Test("初回起動のまとめ要求を済ませたかを覚えている")
    func firstLaunchCompletion() async {
        let defaults = makeDefaults()
        let spy = RequestSpy()
        let model = PermissionsModel(defaults: defaults, requestPermission: spy.request)
        #expect(!model.hasCompletedFirstLaunch)

        await model.requestOnFirstLaunchIfNeeded()
        #expect(model.hasCompletedFirstLaunch)

        // 同じ defaults を引き継いだ別インスタンスでも、初回ではなくなっている。
        let second = PermissionsModel(defaults: defaults)
        #expect(second.hasCompletedFirstLaunch)
    }

    @Test("まとめ要求は許可済みの権限を飛ばす")
    func requestAllSkipsGranted() async {
        let spy = RequestSpy()
        let model = PermissionsModel(
            defaults: makeDefaults(),
            requestPermission: spy.request,
            checkPermissions: Self.checker(granting: [.camera])
        )
        model.apply(settings: macCameraOnlySettings())
        model.refresh()  // カメラは許可済みになる。

        await model.requestAll()

        #expect(spy.requested.isEmpty)
        #expect(model.lastMessage != nil)
    }

    @Test("request(for:) はそのトグルが必要とする権限だけ要求する")
    func requestForFeatureRequestsMatchingKind() async {
        let spy = RequestSpy()
        let model = PermissionsModel(defaults: makeDefaults(), requestPermission: spy.request)

        await model.request(for: .macCamera)
        #expect(spy.requested == [.camera])

        spy.clear()
        await model.request(for: .sermonTakeover)
        #expect(spy.requested == [.automation])

        // 権限が要らないトグル(Discord など)は何も要求しない。
        spy.clear()
        await model.request(for: .discordExposure)
        #expect(spy.requested.isEmpty)
    }

    @Test("request(for:) はすでに許可済みなら要求しない")
    func requestForFeatureSkipsGranted() async {
        let spy = RequestSpy()
        let model = PermissionsModel(
            defaults: makeDefaults(),
            requestPermission: spy.request,
            checkPermissions: Self.checker(granting: [.camera])
        )
        model.refresh()
        await model.request(for: .macCamera)
        #expect(spy.requested.isEmpty)
    }
}
