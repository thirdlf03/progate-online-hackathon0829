import Foundation
import Testing

@testable import MihariCore

@Suite("本体の生死を見る 1 回分の見回り")
struct AppWatchdogTests {

    private final class StubObserver: RunningApplicationObserving, @unchecked Sendable {
        var isRunningResult: Bool
        init(isRunningResult: Bool) { self.isRunningResult = isRunningResult }
        func isRunning(bundleIdentifier: String) -> Bool { isRunningResult }
    }

    private final class SpyLauncher: ApplicationLaunching, @unchecked Sendable {
        private(set) var launchedURLs: [URL] = []
        func launch(appURL: URL) { launchedURLs.append(appURL) }
    }

    @Test("本体が動いていれば何もしない")
    func doesNothingWhenRunning() {
        let observer = StubObserver(isRunningResult: true)
        let launcher = SpyLauncher()
        let watchdog = AppWatchdog(
            bundleIdentifier: "com.thirdlf03.mihari",
            appURL: URL(fileURLWithPath: "/Applications/Mihari.app"),
            observer: observer,
            launcher: launcher
        )

        watchdog.checkAndReviveIfNeeded()

        #expect(launcher.launchedURLs.isEmpty)
    }

    @Test("本体が消えていれば起こす")
    func revivesWhenNotRunning() {
        let observer = StubObserver(isRunningResult: false)
        let launcher = SpyLauncher()
        let appURL = URL(fileURLWithPath: "/Applications/Mihari.app")
        let watchdog = AppWatchdog(
            bundleIdentifier: "com.thirdlf03.mihari",
            appURL: appURL,
            observer: observer,
            launcher: launcher
        )

        watchdog.checkAndReviveIfNeeded()

        #expect(launcher.launchedURLs == [appURL])
    }

    /// 実行のたびに一時ディレクトリに記録を置き、テスト同士がファイルを共有しないようにする。
    private func makeEscapeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mihari.test.watchdog.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("escape.json")
    }

    @Test("脱出の記録があり宣言時刻前は起こさない")
    func doesNotReviveBeforeEscapeReturn() throws {
        let observer = StubObserver(isRunningResult: false)
        let launcher = SpyLauncher()
        let escapeURL = makeEscapeURL()
        try EscapeRecordStore.save(
            EscapeRecord(
                escapedAt: Date(timeIntervalSince1970: 900),
                returnAt: Date(timeIntervalSince1970: 2000)
            ),
            to: escapeURL
        )
        let watchdog = AppWatchdog(
            bundleIdentifier: "com.thirdlf03.mihari",
            appURL: URL(fileURLWithPath: "/Applications/Mihari.app"),
            observer: observer,
            launcher: launcher,
            escapeRecordURL: escapeURL,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        watchdog.checkAndReviveIfNeeded()

        #expect(launcher.launchedURLs.isEmpty)
        // 記録は宣言時刻まで残る。
        #expect(EscapeRecordStore.load(from: escapeURL) != nil)
    }

    @Test("脱出の記録は宣言時刻を過ぎたら消して起こす")
    func revivesAndRemovesRecordAfterEscapeReturn() throws {
        let observer = StubObserver(isRunningResult: false)
        let launcher = SpyLauncher()
        let appURL = URL(fileURLWithPath: "/Applications/Mihari.app")
        let escapeURL = makeEscapeURL()
        try EscapeRecordStore.save(
            EscapeRecord(
                escapedAt: Date(timeIntervalSince1970: 900),
                returnAt: Date(timeIntervalSince1970: 2000)
            ),
            to: escapeURL
        )
        let watchdog = AppWatchdog(
            bundleIdentifier: "com.thirdlf03.mihari",
            appURL: appURL,
            observer: observer,
            launcher: launcher,
            escapeRecordURL: escapeURL,
            now: { Date(timeIntervalSince1970: 2000) }
        )

        watchdog.checkAndReviveIfNeeded()

        #expect(launcher.launchedURLs == [appURL])
        #expect(EscapeRecordStore.load(from: escapeURL) == nil)
    }
}
