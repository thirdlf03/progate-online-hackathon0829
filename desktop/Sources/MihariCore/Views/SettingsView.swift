import SwiftUI

/// 設定ウィンドウのタブ。
///
/// 「すぐ触りたい操作」(監視の停止 / 再開・在席スタンプ・休憩・サイズ・声・写り込み)は
/// 右クリックメニューに残し、「じっくり決める設定」だけをこの 3 タブに寄せる。
public enum SettingsTab: String, CaseIterable, Identifiable {
    case safety
    case discord
    case permissions

    public var id: String { rawValue }

    /// タブに出す名前。
    public var label: String {
        switch self {
        case .safety: return "セーフティー"
        case .discord: return "Discord"
        case .permissions: return "権限"
        }
    }

    /// タブに出す SF Symbol。
    public var systemImage: String {
        switch self {
        case .safety: return "shield"
        case .discord: return "paperplane"
        case .permissions: return "lock.shield"
        }
    }
}

/// 設定ウィンドウで選ばれているタブ。
///
/// ウィンドウの中身は開くたびに組み立て直すので、選択はウィンドウの外(`AppCoordinator`)で
/// 持ち続ける。メニュー最上段のセーフティー状態行から `.safety` を指して開けるよう、
/// 外から差し替えられる `ObservableObject` にしてある。
@MainActor
public final class SettingsTabSelection: ObservableObject {
    /// いま選ばれているタブ。初回は `.safety`。
    @Published public var tab: SettingsTab

    public init(tab: SettingsTab = .safety) {
        self.tab = tab
    }
}

/// 設定ウィンドウのルート View。
///
/// この View が持つのは「タブバーと選択状態」だけで、各タブの中身は呼び側から受け取る。
/// 中身の 3 つ(`SafetyModeView` / `DiscordView` / `OnboardingView`)はどれも自前で
/// `ScrollView` を持っているので、ここでは包まない(二重スクロールにしない)。
public struct SettingsView<Safety: View, Discord: View, Permissions: View>: View {
    @ObservedObject private var selection: SettingsTabSelection
    private let safety: Safety
    private let discord: Discord
    private let permissions: Permissions

    /// - Parameters:
    ///   - selection: 選ばれているタブ。呼び側が持ち、開くタブを指定するのにも使う。
    ///   - safety: 「セーフティー」タブの中身。
    ///   - discord: 「Discord」タブの中身。
    ///   - permissions: 「権限」タブの中身。
    public init(
        selection: SettingsTabSelection,
        @ViewBuilder safety: () -> Safety,
        @ViewBuilder discord: () -> Discord,
        @ViewBuilder permissions: () -> Permissions
    ) {
        self.selection = selection
        self.safety = safety()
        self.discord = discord()
        self.permissions = permissions()
    }

    public var body: some View {
        TabView(selection: $selection.tab) {
            safety
                .tabItem { Label(SettingsTab.safety.label, systemImage: SettingsTab.safety.systemImage) }
                .tag(SettingsTab.safety)
            discord
                .tabItem { Label(SettingsTab.discord.label, systemImage: SettingsTab.discord.systemImage) }
                .tag(SettingsTab.discord)
            permissions
                .tabItem {
                    Label(SettingsTab.permissions.label, systemImage: SettingsTab.permissions.systemImage)
                }
                .tag(SettingsTab.permissions)
        }
    }
}
