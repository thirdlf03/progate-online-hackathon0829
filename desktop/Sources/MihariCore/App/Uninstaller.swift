import AppKit
import Foundation

/// アンインストールで消す対象 1 つぶん。
///
/// `allCases` の並びが実行順でもある。`rawValue` はログやテストでの識別に使う。
public enum UninstallStep: String, CaseIterable, Sendable {
    /// 監視プロセス(MihariWatchdog)の LaunchAgent。bootout + plist 削除。
    case watchdog
    /// iPhone スクショ用トンネル(tunneld)の LaunchDaemon。管理者パスワードが 1 回要る。
    case tunneld
    /// ログイン項目(SMAppService)。
    case loginItem
    /// 執行猶予脱出の記録(`~/Library/Application Support/Mihari/escape.json`)。#52。
    case escapeRecord
    /// bridge 側の設定ディレクトリ(`~/.mihari`)。
    case settingsDir
    /// 本アプリのドメイン(`Bundle.main.bundleIdentifier`)の UserDefaults。
    case userDefaults
    /// アプリ本体(`.app`)。最後にゴミ箱へ移動する。
    case appBundle

    /// ダイアログや一覧に出す日本語の表示名。
    public var title: String {
        switch self {
        case .watchdog: return "監視プロセスの LaunchAgent 登録"
        case .tunneld: return "iPhone トンネル(tunneld)の LaunchDaemon 登録"
        case .loginItem: return "ログイン項目"
        case .escapeRecord: return "執行猶予脱出の記録(escape.json)"
        case .settingsDir: return "設定ディレクトリ(~/.mihari)"
        case .userDefaults: return "アプリの設定(UserDefaults)"
        case .appBundle: return "アプリ本体(Mihari.app)"
        }
    }
}

/// アンインストールの失敗 1 件分。
///
/// `(step:reason:)` のタプルで持つと `UninstallReport` が Equatable にできないので、
/// 名前付きの struct にした。#55。
public struct UninstallFailure: Equatable, Sendable {
    /// 失敗したステップ。
    public let step: UninstallStep
    /// 失敗の理由。そのままダイアログに出す。
    public let reason: String
}

/// アンインストールの結果。成功(または skip)したステップと失敗したステップを全部持つ。
public struct UninstallReport: Equatable, Sendable {
    /// 成功した、または「登録が無く消す必要がなかった」(skip)ステップ。
    public var succeeded: [UninstallStep]
    /// 失敗したステップと理由。空ならすべて成功。
    public var failed: [UninstallFailure]

    public init(succeeded: [UninstallStep] = [], failed: [UninstallFailure] = []) {
        self.succeeded = succeeded
        self.failed = failed
    }

    /// アプリから消し切れなかったときの手動手順。README と同じ 4 コマンド。
    ///
    /// 失敗時のダイアログに出す。tunneld の label は `com.thirdlf03.mihari.tunneld`
    /// (`bridge/scripts/install_tunneld_daemon.sh` の `LABEL` と一致させる)。
    public var manualInstructions: String {
        """
        launchctl bootout gui/$(id -u)/com.thirdlf03.mihari.watchdog
        sudo launchctl bootout system/com.thirdlf03.mihari.tunneld
        rm -rf ~/.mihari
        defaults delete com.thirdlf03.mihari
        """
    }
}

/// ステップの失敗を `UninstallFailure.reason` に載せるためのエラー。
private struct UninstallerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// アプリ自身による完全アンインストール。
///
/// セーフティーモードのトグルで常駐するようになった LaunchAgent(watchdog)・
/// LaunchDaemon(tunneld)・ログイン項目は、`.app` をゴミ箱に入れるだけでは残る。
/// ここが「入れた本人が確実に全部消せる出口」になる。各ステップは独立に試し、
/// 失敗しても次へ進む(途中で止めない)。
///
/// 順番は `UninstallStep.allCases` の並びそのまま。`.app` のゴミ箱行きを最後にする
/// のは、消している最中に本体ごと消えて残りを消せなくならないようにするため。
@MainActor
public final class Uninstaller {

    private let watchdog: WatchdogRegistering
    private let loginItem: LoginItemRegistering
    private let tunneld: TunneldModel
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let homeDirectory: URL
    private let appBundleURL: URL
    /// 本アプリの UserDefaults ドメイン。テストでは一時ドメインを渡す。
    private let bundleIdentifier: String
    /// `MIHARI_SETTINGS_DIR` の解釈に使う。テストでは注入する。
    private let environment: [String: String]

    /// - Parameters:
    ///   - watchdog: 監視プロセスの登録/解除。テストではスタブに差し替える。
    ///   - loginItem: ログイン項目の登録/解除。テストではスタブに差し替える。
    ///   - tunneld: tunneld の LaunchDaemon 登録/解除。テストではスタブの runner /
    ///     probe で作ったモデルを渡す。
    ///   - fileManager: ファイル操作。テストでは一時ディレクトリを渡す(homeDirectory)。
    ///   - defaults: UserDefaults の削除先。テストでは一時ドメインを持つ suite を渡す。
    ///   - homeDirectory: `~/Library` や `~/.mihari` をこの下に解決する。テストでは
    ///     一時ディレクトリを渡す。
    ///   - appBundleURL: ゴミ箱へ入れる `.app`。テストでは存在しないパスを渡すと
    ///     「もう無い」ので skip になり、実際にゴミ箱へ入れない。
    ///   - bundleIdentifier: 消す UserDefaults ドメイン。テストでは一時ドメインを渡す。
    ///   - environment: 環境変数。テストでは `MIHARI_SETTINGS_DIR` を注入する。
    public init(
        watchdog: WatchdogRegistering,
        loginItem: LoginItemRegistering,
        tunneld: TunneldModel,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appBundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.watchdog = watchdog
        self.loginItem = loginItem
        self.tunneld = tunneld
        self.fileManager = fileManager
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.appBundleURL = appBundleURL
        self.bundleIdentifier = bundleIdentifier
        self.environment = environment
    }

    /// 全部のステップを順に試す。失敗しても止めずに次へ進む。
    public func run() async -> UninstallReport {
        var report = UninstallReport()
        await perform(.watchdog, into: &report) { try self.removeWatchdog() }
        await perform(.tunneld, into: &report) { try await self.removeTunneld() }
        await perform(.loginItem, into: &report) { self.removeLoginItem() }
        await perform(.escapeRecord, into: &report) { try self.removeEscapeRecord() }
        await perform(.settingsDir, into: &report) { try self.removeSettingsDir() }
        await perform(.userDefaults, into: &report) { self.removeUserDefaults() }
        await perform(.appBundle, into: &report) { try await self.removeAppBundle() }
        return report
    }

    /// 1 ステップを実行し、成功なら succeeded、失敗なら failed に積む。
    private func perform(
        _ step: UninstallStep,
        into report: inout UninstallReport,
        work: () async throws -> Void
    ) async {
        do {
            try await work()
            report.succeeded.append(step)
        } catch {
            report.failed.append(
                UninstallFailure(step: step, reason: error.localizedDescription)
            )
        }
    }

    // MARK: - ステップ本体

    /// watchdog: LaunchAgent の bootout + plist 削除。
    ///
    /// `WatchdogRegistering.unregister()` は失敗をログだけに握りつぶすので、
    /// 後始末が本当に終わったか、plist ファイルが消えたかで確かめる。
    private func removeWatchdog() throws {
        watchdog.unregister()
        let plistURL = WatchdogSetup.plistURL(homeDirectory: homeDirectory)
        guard !fileManager.fileExists(atPath: plistURL.path) else {
            throw UninstallerError(message: "LaunchAgent の plist が残っている: \(plistURL.path)")
        }
    }

    /// tunneld: LaunchDaemon の解除。管理者パスワードダイアログが 1 回出る。
    ///
    /// 登録が無ければ(応答が無ければ)消す必要がないので、skip として成功扱いにする。
    /// 解除のあとまだ応答がある(= 解除できていない)なら失敗にする。
    private func removeTunneld() async throws {
        await tunneld.refresh()
        guard tunneld.status == .running else { return }
        await tunneld.uninstall()
        guard tunneld.status != .running else {
            throw UninstallerError(message: tunneld.message ?? "tunneld がまだ応答している")
        }
    }

    /// loginItem: SMAppService の解除。
    ///
    /// `LoginItemRegistering` は結果を返さない(失敗はログだけ)ので、ここでは
    /// 呼ぶことまでが責務。失敗しても手動の手順で補える。
    private func removeLoginItem() {
        loginItem.unregister()
    }

    /// escapeRecord: 執行猶予脱出の記録の削除。無ければ消す必要がない。#52。
    ///
    /// `EscapeRecordStore.url()` と同じ「Application Support/Mihari/escape.json」を、
    /// テストで差し替え可能な `homeDirectory` から組み立てる。
    private func removeEscapeRecord() throws {
        let url =
            homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Mihari", isDirectory: true)
            .appendingPathComponent("escape.json")
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// settingsDir: bridge 側の設定ディレクトリの削除。
    ///
    /// bridge の `SettingsStore` と同じ決め方で、`MIHARI_SETTINGS_DIR` があれば
    /// それを優先し、無ければ `~/.mihari` を使う。
    private func removeSettingsDir() throws {
        let raw = environment["MIHARI_SETTINGS_DIR"] ?? "~/.mihari"
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// userDefaults: 本アプリのドメインの削除。
    ///
    /// バンドル ID が取れない環境(開発中の素の実行ファイルなど)では消す対象が
    /// 無いので、何もせず成功扱いにする。
    private func removeUserDefaults() {
        guard !bundleIdentifier.isEmpty else { return }
        defaults.removePersistentDomain(forName: bundleIdentifier)
    }

    /// appBundle: アプリ本体をゴミ箱へ移動。最後に実行する。
    ///
    /// 対象が無ければ消す必要がない(skip)。テストでは存在しないパスを注入して、
    /// 実際にゴミ箱へ入れずにこのステップを済ませる。開発中の `.build` 配下など
    /// ゴミ箱へ入らない場所では、理由を報告して手動の手順に委ねる。
    private func removeAppBundle() async throws {
        guard fileManager.fileExists(atPath: appBundleURL.path) else { return }
        let trashed: [URL: URL]
        do {
            trashed = try await moveToTrash(appBundleURL)
        } catch {
            throw UninstallerError(
                message: "ゴミ箱への移動に失敗した: \(error.localizedDescription)"
            )
        }
        guard !trashed.isEmpty else {
            throw UninstallerError(message: "ゴミ箱への移動に失敗した(移動先が返ってこなかった)")
        }
    }

    /// `NSWorkspace.recycle` の completion handler API を await に包む。
    ///
    /// 戻り値は「元の URL → ゴミ箱内の移動先 URL」の辞書。空なら移動されなかった。
    private func moveToTrash(_ url: URL) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { mapping, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: mapping)
                }
            }
        }
    }
}
