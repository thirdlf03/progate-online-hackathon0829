import Foundation

/// tunneld(iOS 17+ の iPhone スクショに必要な RemoteXPC トンネルの常駐)の
/// 登録スクリプトを組み立てる純粋なロジック。
///
/// tunneld は root でしか動かせないため、アプリからは直接起動できない。
/// 代わりに `install_tunneld_daemon.sh` を macOS の
/// 管理者パスワードダイアログ(`do shell script … with administrator privileges`)
/// 経由で 1 回実行し、launchd(LaunchDaemon)に常駐を任せる。
///
/// スクリプトの置き場は `DaemonLocator.tunneldScripts()` が決める。配布した `.app` なら
/// 同梱物の `Contents/Resources/device-bridge/scripts/`、リポジトリなら `bridge/scripts/`。
public enum TunneldSetup {

    /// tunneld の HTTP API。ここが応答すれば常駐している。
    public static let apiURL = URL(string: "http://127.0.0.1:49151/")!

    /// 登録スクリプトを管理者権限で実行する AppleScript を組み立てる。
    ///
    /// `pymobiledevice3Path` を渡すと、スクリプトはそのバイナリを直接 launchd に登録する。
    /// `.app` に同梱した `pymobiledevice3` を使わせるための入口。渡さなければ、
    /// スクリプトは従来どおり自分で `uv` を探して `bridge/` 越しに起動する。
    public static func installScript(scriptsDirectory: String, pymobiledevice3Path: String? = nil) -> String {
        let path = scriptsDirectory + "/install_tunneld_daemon.sh"
        guard let pymobiledevice3Path else {
            return "do shell script \(appleScriptLiteral(path)) with administrator privileges"
        }
        let command = "PYMOBILEDEVICE3_PATH=\(shellLiteral(pymobiledevice3Path)) \(shellLiteral(path))"
        return "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    }

    /// 解除スクリプトを管理者権限で実行する AppleScript を組み立てる。
    ///
    /// `install()` と同じく LaunchDaemon は root しか触れないため、
    /// 管理者パスワードダイアログ経由で `uninstall_tunneld_daemon.sh` を 1 回実行する。
    /// 解除は `launchctl bootout` と plist の削除だけなので、`pymobiledevice3` は要らない。
    public static func uninstallScript(scriptsDirectory: String) -> String {
        let path = scriptsDirectory + "/uninstall_tunneld_daemon.sh"
        return "do shell script \(appleScriptLiteral(path)) with administrator privileges"
    }

    /// `do shell script` に渡すコマンド行の中で、1 語として扱わせるためのシェルリテラル。
    /// シングルクォートで囲めば中身は素通りするので、閉じる引用符だけ処理すればよい。
    static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// AppleScript の文字列リテラルにする。引用符とバックスラッシュだけ気をつければよい。
    static func appleScriptLiteral(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// tunneld の API に到達できるか。起動直後は数秒かかるので短いタイムアウトで見る。
    public static func isReachable() async -> Bool {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// オンボーディング画面に出す tunneld の状態と、アプリからの登録操作。
@MainActor
public final class TunneldModel: ObservableObject {

    public enum Status: Equatable {
        /// まだ確かめていない。
        case unknown
        /// 確認中。
        case checking
        /// 常駐していて API が応答する。
        case running
        /// 応答がない(未登録か、起動直後)。
        case notRunning
        /// 管理者パスワードダイアログを出して登録している最中。
        case installing
    }

    @Published public private(set) var status: Status = .unknown
    @Published public private(set) var message: String?

    private let probe: @Sendable () async -> Bool
    private let runner: AppleScriptRunning
    private let locator: DaemonLocator
    /// 登録直後、tunneld が API を開くまでの待ち。テストでは 0 にする。
    private let settleDelay: Duration

    public init(
        probe: @escaping @Sendable () async -> Bool = { await TunneldSetup.isReachable() },
        runner: AppleScriptRunning = SystemAppleScriptRunner(),
        locator: DaemonLocator = DaemonLocator(),
        settleDelay: Duration = .seconds(3)
    ) {
        self.probe = probe
        self.runner = runner
        self.locator = locator
        self.settleDelay = settleDelay
    }

    /// いまの状態を確かめる。
    public func refresh() async {
        guard status != .installing else { return }
        status = .checking
        status = await probe() ? .running : .notRunning
    }

    /// 管理者パスワードダイアログを出して LaunchDaemon を登録する。
    public func install() async {
        guard status != .installing else { return }
        status = .installing
        message = nil

        // 配布した .app なら同梱物、リポジトリなら bridge/scripts/。
        // 同梱スクリプトには同梱の pymobiledevice3 を渡すので uv が要らない。
        let scripts: TunneldScriptLocation
        do {
            scripts = try locator.tunneldScripts()
        } catch {
            status = .notRunning
            message = "tunneld のスクリプトが見つかりません。DEVICE_BRIDGE_DIR を設定してください"
            return
        }

        let source = TunneldSetup.installScript(
            scriptsDirectory: scripts.scriptsDirectory,
            pymobiledevice3Path: scripts.pymobiledevice3Path
        )
        let runner = self.runner
        // パスワードダイアログが閉じるまで返ってこない同期呼び出しなので、メインを塞がない。
        let outcome = await Task.detached { runner.run(source) }.value

        if outcome.succeeded {
            // 登録直後は tunneld の起動に数秒かかる。
            try? await Task.sleep(for: settleDelay)
            status = .unknown
            await refresh()
            message =
                status == .running
                ? "登録しました。以後は再起動しても自動で立ち上がります"
                : "登録は完了しましたが、まだ応答がありません。数秒待って再確認してください"
        } else if outcome.errorNumber == -128 {
            status = .notRunning
            message = "キャンセルされました"
        } else {
            status = .notRunning
            message = "登録に失敗しました(エラー \(outcome.errorNumber.map(String.init) ?? "不明"))"
        }
    }

    /// 管理者パスワードダイアログを出して LaunchDaemon を解除する。
    ///
    /// セーフティートグル `iphoneScreenshot` を OFF にしたときに `AppCoordinator` が呼ぶ。
    /// 解除に失敗しても壊れた状態にしないため、キャンセルや失敗では開始前の状態に戻す。
    public func uninstall() async {
        guard status != .installing else { return }
        let previous = status
        status = .installing
        message = nil

        let scripts: TunneldScriptLocation
        do {
            scripts = try locator.tunneldScripts()
        } catch {
            status = previous
            message = "tunneld のスクリプトが見つかりません。DEVICE_BRIDGE_DIR を設定してください"
            return
        }

        let source = TunneldSetup.uninstallScript(scriptsDirectory: scripts.scriptsDirectory)
        let runner = self.runner
        // パスワードダイアログが閉じるまで返ってこない同期呼び出しなので、メインを塞がない。
        let outcome = await Task.detached { runner.run(source) }.value

        if outcome.succeeded {
            // 解除直後は tunneld の停止に少し時間がかかる。
            try? await Task.sleep(for: settleDelay)
            status = .unknown
            await refresh()
            message =
                status == .running
                ? "解除しましたが、まだ応答があります。数秒待って再確認してください"
                : "解除しました。以後は再起動しても自動で立ち上がりません"
        } else if outcome.errorNumber == -128 {
            status = previous
            message = "キャンセルされました"
        } else {
            status = previous
            message = "解除に失敗しました(エラー \(outcome.errorNumber.map(String.init) ?? "不明"))"
        }
    }
}
