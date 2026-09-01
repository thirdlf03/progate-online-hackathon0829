import Foundation
import Testing

@testable import MihariCore

/// アンインストーラーを検証する。ファイル系は一時ディレクトリ、登録系はスタブを
/// 使い、実際の `launchctl`・管理者パスワードダイアログ・ゴミ箱には触れない。
@Suite("アンインストーラー")
@MainActor
struct UninstallerTests {

    /// watchdog の登録/解除を呼び出し回数だけ記録するスタブ。plist の削除は
    /// Uninstaller 側の検査対象なので、ここでは消さない。
    private final class WatchdogStub: WatchdogRegistering, @unchecked Sendable {
        var unregisteredCount = 0
        func ensureRegistered() {}
        func unregister() { unregisteredCount += 1 }
        func reassertIfMissing() {}
    }

    /// ログイン項目の解除を呼び出し回数だけ記録するスタブ。
    private final class LoginItemStub: LoginItemRegistering, @unchecked Sendable {
        var unregisteredCount = 0
        func ensureRegistered() {}
        func unregister() { unregisteredCount += 1 }
    }

    /// AppleScript の実行結果を固定するスタブ。解除の失敗(キャンセル)を再現する。
    private final class RunnerStub: AppleScriptRunning, @unchecked Sendable {
        var outcome = AppleScriptOutcome(value: "ok")
        func run(_ source: String) -> AppleScriptOutcome { outcome }
    }

    /// tunneld のプローブ(`isReachable`)の結果を順に返す。「登録されている / いない」を再現する。
    private actor ProbeBox {
        private var results: [Bool]
        init(results: [Bool]) { self.results = results }
        func next() -> Bool { results.isEmpty ? false : results.removeFirst() }
    }

    /// テスト用の tunneld モデル。`settleDelay` を 0 にして、解除直後の待ちを挟まない。
    private func makeTunneld(probeResults: [Bool], runner: AppleScriptRunning) -> TunneldModel {
        let probe = ProbeBox(results: probeResults)
        return TunneldModel(
            probe: { await probe.next() },
            runner: runner,
            locator: DaemonLocator(
                environment: ["DEVICE_BRIDGE_DIR": "/repo/bridge"],
                isExecutable: { _ in true },
                directoryExists: { _ in true }
            ),
            settleDelay: .zero
        )
    }

    /// 実行のたびに独立した一時ディレクトリを作り、テスト同士がファイルを共有しないようにする。
    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihari.test.uninstaller.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 実行のたびに空の UserDefaults を作る。suite 名を bundle id に使い、
    /// 「消える対象」の値も 1 つ仕込んでおく(removePersistentDomain で消えるかを見る)。
    private func makeDefaults(bundleID: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: bundleID)!
        defaults.removePersistentDomain(forName: bundleID)
        defaults.set("value", forKey: "seed")
        return defaults
    }

    /// 存在しない .app のパス。「もう無い」ので appBundle ステップは skip になり、
    /// 実際にゴミ箱へ入らない。
    private func makeMissingAppBundleURL(home: URL) -> URL {
        home.appendingPathComponent("Mihari.app")
    }

    private func makeUninstaller(
        watchdog: WatchdogRegistering,
        loginItem: LoginItemRegistering,
        tunneld: TunneldModel,
        defaults: UserDefaults,
        home: URL,
        bundleID: String,
        environment: [String: String]
    ) -> Uninstaller {
        Uninstaller(
            watchdog: watchdog,
            loginItem: loginItem,
            tunneld: tunneld,
            defaults: defaults,
            homeDirectory: home,
            appBundleURL: makeMissingAppBundleURL(home: home),
            bundleIdentifier: bundleID,
            environment: environment
        )
    }

    @Test("全ステップ成功: succeeded に順番どおり全部、failed は空")
    func allStepsSucceed() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundleID = "com.test.mihari.uninstall.\(UUID().uuidString)"
        let defaults = makeDefaults(bundleID: bundleID)

        // tunneld は未登録(プローブが false)、appBundle は存在しないので、どちらも skip で成功。
        let watchdog = WatchdogStub()
        let loginItem = LoginItemStub()
        let tunneld = makeTunneld(probeResults: [false], runner: RunnerStub())

        let report = await makeUninstaller(
            watchdog: watchdog,
            loginItem: loginItem,
            tunneld: tunneld,
            defaults: defaults,
            home: home,
            bundleID: bundleID,
            environment: [:]
        ).run()

        // 実行順は UninstallStep.allCases の並びどおり。
        #expect(report.succeeded == UninstallStep.allCases)
        #expect(report.failed.isEmpty)
        #expect(watchdog.unregisteredCount == 1)
        #expect(loginItem.unregisteredCount == 1)
        // UserDefaults のドメインが消えている。
        #expect(defaults.object(forKey: "seed") == nil)
    }

    @Test("一部が失敗しても残りまで全部試され、失敗はステップと理由で報告される")
    func continuesAfterFailure() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundleID = "com.test.mihari.uninstall.\(UUID().uuidString)"
        let defaults = makeDefaults(bundleID: bundleID)

        // watchdog: plist が消えないスタブ + 実在する plist → 失敗になる。
        let watchdog = WatchdogStub()
        let plistURL = WatchdogSetup.plistURL(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "dummy".write(to: plistURL, atomically: true, encoding: .utf8)

        // tunneld: 登録されている(プローブ true)が、解除をキャンセルされる → 失敗になる。
        let runner = RunnerStub()
        runner.outcome = AppleScriptOutcome(errorNumber: -128)
        let tunneld = makeTunneld(probeResults: [true], runner: runner)

        // escapeRecord / settingsDir: 消えるはずのファイルを置いておく。
        let escapeURL =
            home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Mihari", isDirectory: true)
            .appendingPathComponent("escape.json")
        try FileManager.default.createDirectory(
            at: escapeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}".write(to: escapeURL, atomically: true, encoding: .utf8)
        let settingsDir = home.appendingPathComponent(".mihari", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)

        let report = await makeUninstaller(
            watchdog: watchdog,
            loginItem: LoginItemStub(),
            tunneld: tunneld,
            defaults: defaults,
            home: home,
            bundleID: bundleID,
            environment: ["MIHARI_SETTINGS_DIR": settingsDir.path]
        ).run()

        // 失敗した 2 本が順番どおり report に入り、理由も空でない。
        #expect(report.failed.map(\.step) == [.watchdog, .tunneld])
        #expect(report.failed.map(\.reason).allSatisfy { !$0.isEmpty })
        #expect(report.failed.first(where: { $0.step == .tunneld })?.reason.contains("キャンセル") == true)
        // 失敗のあとのステップも全部試されて成功している(途中で止まらない)。
        #expect(report.succeeded == [.loginItem, .escapeRecord, .settingsDir, .userDefaults, .appBundle])
        #expect(!FileManager.default.fileExists(atPath: escapeURL.path))
        #expect(!FileManager.default.fileExists(atPath: settingsDir.path))
        #expect(defaults.object(forKey: "seed") == nil)
    }

    @Test("settingsDir は MIHARI_SETTINGS_DIR があればそれを優先する")
    func settingsDirPrefersEnvironmentVariable() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 環境変数の指す先と、home 配下の ~/.mihari の両方にディレクトリを置く。
        let envDir = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: envDir) }
        try FileManager.default.createDirectory(
            at: envDir.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        let defaultDir = home.appendingPathComponent(".mihari", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        let bundleID = "com.test.mihari.uninstall.\(UUID().uuidString)"

        let report = await makeUninstaller(
            watchdog: WatchdogStub(),
            loginItem: LoginItemStub(),
            tunneld: makeTunneld(probeResults: [false], runner: RunnerStub()),
            defaults: makeDefaults(bundleID: bundleID),
            home: home,
            bundleID: bundleID,
            environment: ["MIHARI_SETTINGS_DIR": envDir.path]
        ).run()

        #expect(report.failed.isEmpty)
        #expect(report.succeeded.contains(.settingsDir))
        // 環境変数の指す先だけが消えて、~/.mihari は残る。
        #expect(!FileManager.default.fileExists(atPath: envDir.path))
        #expect(FileManager.default.fileExists(atPath: defaultDir.path))
    }

    @Test("登録が無い tunneld は skip として succeeded に入る")
    func unregisteredTunneldIsSkipped() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 登録されていない(プローブ false)なら、管理者パスワードダイアログも出さない。
        let bundleID = "com.test.mihari.uninstall.\(UUID().uuidString)"
        let report = await makeUninstaller(
            watchdog: WatchdogStub(),
            loginItem: LoginItemStub(),
            tunneld: makeTunneld(probeResults: [false], runner: RunnerStub()),
            defaults: makeDefaults(bundleID: bundleID),
            home: home,
            bundleID: bundleID,
            environment: [:]
        ).run()

        #expect(report.failed.isEmpty)
        #expect(report.succeeded.contains(.tunneld))
        #expect(report.succeeded.contains(.appBundle))
    }

    @Test("手動の手順が report から取れる")
    func manualInstructionsAreAvailable() {
        let report = UninstallReport()
        #expect(report.manualInstructions.contains("launchctl bootout gui/$(id -u)/com.thirdlf03.mihari.watchdog"))
        #expect(report.manualInstructions.contains("sudo launchctl bootout system/com.thirdlf03.mihari.tunneld"))
        #expect(report.manualInstructions.contains("rm -rf ~/.mihari"))
        #expect(report.manualInstructions.contains("defaults delete com.thirdlf03.mihari"))
    }
}

/// `AppCoordinator.canUninstall` の判定。quitLock トグルと終了ロックの組み合わせを見る。
/// ロックの本体(`QuitTimeLock`)は init に注入して、ロック中/解除済みを直接再現する。#55
@Suite("canUninstall の判定")
@MainActor
struct CanUninstallTests {

    private final class SleepPreventerStub: SleepPreventing {
        func start() {}
        func stop() {}
    }

    private final class LifecycleMarkerStub: AppLifecycleMarking {
        func wasPreviousSessionGraceful() -> Bool { true }
        func markSessionStarted() {}
        func markGracefulShutdown() {}
    }

    private final class WatchdogStub: WatchdogRegistering, @unchecked Sendable {
        func ensureRegistered() {}
        func unregister() {}
        func reassertIfMissing() {}
    }

    private final class LoginItemStub: LoginItemRegistering, @unchecked Sendable {
        func ensureRegistered() {}
        func unregister() {}
    }

    /// 実行のたびに空の SafetySettingsStore を作る。quitLockEnabled なら quitLock を ON にする。
    private func makeSafety(quitLockEnabled: Bool) -> SafetySettingsStore {
        let suiteName = "mihari.test.canUninstall.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let safety = SafetySettingsStore(defaults: defaults, environment: [:], now: { Date() })
        if quitLockEnabled {
            _ = safety.request(.enable(.quitLock), isWatching: false)
        }
        return safety
    }

    private func makeCoordinator(
        quitLockEnabled: Bool,
        quitTimeLock: QuitTimeLock = QuitTimeLock()
    ) -> AppCoordinator {
        let safety = makeSafety(quitLockEnabled: quitLockEnabled)
        let suiteName = "mihari.test.canUninstallDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppCoordinator(
            sleepPreventer: SleepPreventerStub(),
            loginItemRegistrar: LoginItemStub(),
            watchdogRegistrar: WatchdogStub(),
            lifecycleMarker: LifecycleMarkerStub(),
            safety: safety,
            defaults: defaults,
            quitTimeLock: quitTimeLock
        )
    }

    @Test("quitLock が OFF ならアンインストールできる")
    func quitLockOffAllowsUninstall() {
        let coordinator = makeCoordinator(quitLockEnabled: false)
        defer { coordinator.safety.stop() }

        #expect(coordinator.canUninstall)
    }

    @Test("quitLock が ON でもロックが解けていればアンインストールできる")
    func unlockedQuitLockAllowsUninstall() {
        // 解除時刻が過去(= もう解けている)のロックを注入する。
        let coordinator = makeCoordinator(
            quitLockEnabled: true,
            quitTimeLock: QuitTimeLock(unlockAt: Date(timeIntervalSince1970: 1_000))
        )
        defer { coordinator.safety.stop() }

        #expect(coordinator.canUninstall)
    }

    @Test("quitLock が ON のロック中はアンインストールできない")
    func lockedQuitLockBlocksUninstall() {
        // 解除時刻が未来(= ロック中)のロックを注入する。
        let coordinator = makeCoordinator(
            quitLockEnabled: true,
            quitTimeLock: QuitTimeLock(unlockAt: Date(timeIntervalSince1970: 4_000_000_000))
        )
        defer { coordinator.safety.stop() }

        #expect(!coordinator.canUninstall)
    }
}
