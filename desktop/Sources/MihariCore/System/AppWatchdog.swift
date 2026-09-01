import AppKit

/// 本体アプリが動いているかを見る。テストでは記録だけするスタブに差し替える。
public protocol RunningApplicationObserving {
    func isRunning(bundleIdentifier: String) -> Bool
}

/// 本体アプリを起こす。テストでは記録だけするスタブに差し替える。
public protocol ApplicationLaunching {
    func launch(appURL: URL)
}

/// `NSRunningApplication` で実際に見る実装。
public struct NSWorkspaceApplicationObserver: RunningApplicationObserving {
    public init() {}

    public func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

/// `NSWorkspace` で実際に起こす実装。
public struct NSWorkspaceApplicationLauncher: ApplicationLaunching {
    public init() {}

    public func launch(appURL: URL) {
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// 「本体が消えていたら起こす」の 1 回分の見回り。
///
/// `MihariWatchdog` 実行可能ターゲットの `main.swift` はこれをループで呼ぶだけの薄い皮に
/// してあり、判定・起動の実処理はここに閉じ込めて単体テストできるようにしている。
public struct AppWatchdog {
    private let bundleIdentifier: String
    private let appURL: URL
    private let observer: RunningApplicationObserving
    private let launcher: ApplicationLaunching
    /// 執行猶予脱出の記録の保存先。記録があり宣言時刻前なら起こさない(#52)。
    private let escapeRecordURL: URL
    /// 現在時刻。テストでは固定値を返すクロージャを渡す。
    private let now: () -> Date

    public init(
        bundleIdentifier: String,
        appURL: URL,
        observer: RunningApplicationObserving = NSWorkspaceApplicationObserver(),
        launcher: ApplicationLaunching = NSWorkspaceApplicationLauncher(),
        escapeRecordURL: URL = EscapeRecordStore.url(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appURL = appURL
        self.observer = observer
        self.launcher = launcher
        self.escapeRecordURL = escapeRecordURL
        self.now = now
    }

    /// 動いていなければ起こす。動いていれば何もしない。
    ///
    /// 執行猶予脱出の記録があり、まだ宣言時刻(`returnAt`)前なら**起こさない**
    /// (脱出は「宣言時刻まで本体を止めてよい」約束なので、途中で起こすと約束を破る)。
    /// 宣言時刻を過ぎていたら記録を削除して通常どおり起こす(宣言時刻に自動復帰させる)。
    public func checkAndReviveIfNeeded() {
        guard !observer.isRunning(bundleIdentifier: bundleIdentifier) else { return }
        guard !isWithinEscapeWindow() else { return }
        launcher.launch(appURL: appURL)
    }

    /// 執行猶予脱出の記録があり、まだ宣言時刻前なら true(= 起こさない)。
    private func isWithinEscapeWindow() -> Bool {
        guard let record = EscapeRecordStore.load(from: escapeRecordURL) else { return false }
        guard now() < record.returnAt else {
            // 宣言時刻を過ぎている。記録は用済みなので消して、通常どおり起こす。
            EscapeRecordStore.remove(at: escapeRecordURL)
            return false
        }
        return true
    }
}
