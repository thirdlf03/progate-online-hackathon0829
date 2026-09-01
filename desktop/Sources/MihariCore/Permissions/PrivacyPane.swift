import AppKit
import Foundation

/// システム設定の「プライバシーとセキュリティ」配下の各ペインを開くためのアンカー。
///
/// 一度拒否した TCC はアプリ側から再要求できず、ユーザーにシステム設定を開いてもらうしかない。
/// そのための導線としてオンボーディング画面の各行から使う。
public enum PrivacyPane: String, Sendable, CaseIterable {
    case camera = "Privacy_Camera"
    case screenCapture = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"
    case motion = "Privacy_Motion"

    public var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }

    /// 該当ペインを開く。開けたかどうかを返す。
    @MainActor
    @discardableResult
    public func open() -> Bool {
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }
}
