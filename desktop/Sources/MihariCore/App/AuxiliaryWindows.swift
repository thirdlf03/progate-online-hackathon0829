import AppKit
import SwiftUI

/// ふだんは出さない補助ウィンドウ(設定 / 権限 / 最初の設定 / デバッグ UI / 脱出)の置き場。
///
/// Mihari の本体はデスクトップのペットで、ウィンドウは必要になったときだけ出す。
/// そのため SwiftUI の `WindowGroup` は使わず、ここで `NSWindow` を直接組み立てて使い回す。
/// `isReleasedWhenClosed = false` にしてあるので、閉じても同じウィンドウを開き直せる。
@MainActor
final class AuxiliaryWindows {

    private var permissions: NSWindow?
    private var onboarding: NSWindow?
    private var settings: NSWindow?
    private var debug: NSWindow?
    private var escape: NSWindow?

    /// 起動時の「始める」フロー用の権限の確認画面を出す(すでに出ていれば中身を差し替えて前面へ)。
    ///
    /// 設定としての権限確認は設定ウィンドウの「権限」タブ側にある。こちらは初回導線専用で、
    /// 出す中身は「始める」ボタン付きの `OnboardingView` の 1 種類だけ。
    func showPermissions<Content: View>(@ViewBuilder content: () -> Content) {
        permissions = present(
            permissions,
            title: "権限の確認",
            size: NSSize(width: 900, height: 640),
            content: content()
        )
    }

    /// 権限の確認画面を閉じる。出していなければ何もしない。
    func closePermissions() {
        permissions?.close()
    }

    /// セーフティーのオンボーディング(モード選択 → 権限)を出す。
    /// 既存の権限画面ウィンドウとは別に、design-54.md の 640×720 を持つ。
    func showOnboarding<Content: View>(@ViewBuilder content: () -> Content) {
        onboarding = present(
            onboarding,
            title: "最初の設定",
            size: NSSize(width: 640, height: 720),
            content: content()
        )
    }

    /// セーフティーのオンボーディングを閉じる。出していなければ何もしない。
    func closeOnboarding() {
        onboarding?.close()
    }

    /// 設定画面(セーフティー / Discord / 権限のタブ)を出す。
    ///
    /// 幅は「権限」タブが一番要る。`PermissionRow` が説明の列に `minWidth: 260` を敷き、
    /// その右に「許可を求める」「システム設定を開く」の 2 ボタンが固定幅で並ぶため、
    /// 640(旧セーフティー設定)ではボタンが押し出される。720 なら 3 タブとも収まる。
    /// 高さは、一番縦に長いセーフティーの旧 720 にタブバーぶんを足して 760 にする。
    func showSettings<Content: View>(@ViewBuilder content: () -> Content) {
        settings = present(
            settings,
            title: "設定",
            size: NSSize(width: 720, height: 760),
            content: content()
        )
    }

    /// 設定画面を閉じる。出していなければ何もしない。
    func closeSettings() {
        settings?.close()
    }

    /// 検証用の 10 タブ画面を出す。`MIHARI_DEBUG_UI=1` のときだけ使う。
    func showDebug<Content: View>(@ViewBuilder content: () -> Content) {
        debug = present(
            debug,
            title: "Mihari (検証用)",
            size: NSSize(width: 940, height: 720),
            content: content()
        )
    }

    /// 執行猶予脱出の宣言ダイアログを出す。
    func showEscape<Content: View>(@ViewBuilder content: () -> Content) {
        // 見出しはこのウィンドウ題 1 つだけにする。中身に同じ見出しをもう 1 行置くと、
        // 同じことを 2 回言うだけになる。
        escape = present(
            escape,
            title: "どうしても終了する",
            // 本文が 4 行あるので、200 では説明とピッカーが見切れる。
            size: NSSize(width: 420, height: 300),
            content: content()
        )
    }

    /// 実行猶予脱出の宣言ダイアログを閉じる。出していなければ何もしない。
    func closeEscape() {
        escape?.close()
    }

    /// 既にあるウィンドウなら中身を差し替えて前面に出し、無ければ作る。
    private func present<Content: View>(
        _ existing: NSWindow?,
        title: String,
        size: NSSize,
        content: Content
    ) -> NSWindow {
        let window = existing ?? makeWindow(title: title)
        window.contentViewController = NSHostingController(rootView: content)
        // 大きさと位置は最初に開いたときだけ決める。次からはユーザーが動かした場所を尊重する。
        if existing == nil {
            window.setContentSize(size)
            window.center()
        }
        // ペットはキーウィンドウにならないため、アプリ自体が前に出ていないことがある。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // 閉じたあとも同じウィンドウを開き直すため、解放させない。
        window.isReleasedWhenClosed = false
        return window
    }
}
