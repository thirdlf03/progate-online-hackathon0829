import Combine
import SwiftUI

/// 初回起動のオンボーディング。2 ステップ。
///
/// 1. `SafetyModeView`(セーフティーの「モードを選ぶ画面」)
/// 2. 既存の `OnboardingView`(権限画面・tunneld 登録)
///
/// ステップ 2 は、要求すべき権限が 1 つも無く、かつ tunneld も不要
/// (iphoneScreenshot が OFF)なら飛ばして直ちに `onStart` する。
@MainActor
public struct OnboardingFlowView: View {

    private enum Step {
        case mode
        case permissions
    }

    @ObservedObject private var safety: SafetySettingsStore
    @ObservedObject private var permissions: PermissionsModel
    /// iPhone スクショが ON になったときに tunneld を登録するためのモデル。
    /// 画面表示は既存 `OnboardingView` が自分で持つモデルで行う。
    @ObservedObject private var tunneld: TunneldModel
    /// オンボーディングを終えて見張り始める処理。`AppCoordinator` 側が
    /// モード選択完了の記録 → ウィンドウを閉じる → `begin()` を行う。
    private let onStart: () -> Void

    @State private var step: Step = .mode

    /// - Parameters:
    ///   - safety: セーフティートグル。モード選択とステップ 2 を飛ばす判定に使う。
    ///   - permissions: ステップ 2 の権限モデル。
    ///   - tunneld: ステップ 1 で iphoneScreenshot を ON にしたときの登録に使う。
    ///   - onStart: オンボーディングを終えてアプリ本体へ進む処理。
    public init(
        safety: SafetySettingsStore,
        permissions: PermissionsModel,
        tunneld: TunneldModel,
        onStart: @escaping () -> Void
    ) {
        self.safety = safety
        self.permissions = permissions
        self.tunneld = tunneld
        self.onStart = onStart
    }

    public var body: some View {
        ZStack {
            switch step {
            case .mode:
                SafetyModeView(
                    safety: safety,
                    permissions: permissions,
                    tunneld: tunneld,
                    isWatching: false,
                    // オンボーディングの時点ではまだ見張り始めていないので、ロックも無い。
                    lockedUntil: nil,
                    context: .onboarding(
                        caption: footerCaption,
                        nextTitle: nextTitle,
                        onNext: goToPermissionsStep
                    ),
                    onFeatureEnabled: { feature in
                        Task { await enableFeature(feature) }
                    },
                    // オンボーディングにはアンインストールの入り口を置かない。#55
                    onUninstall: nil,
                    canUninstall: false
                )
                .transition(.move(edge: .leading))
            case .permissions:
                permissionsStep
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        // 必須権限はトグルから導出するので、ステップ 1 でトグルを動かすたびに
        // 権限モデルへ流し込む。`AppCoordinator.observeSafety()` は `begin()` 後にしか
        // 配線されず、オンボーディング中の変更を拾えない(#51)。
        .onReceive(safety.$settings) { settings in
            permissions.apply(settings: settings)
        }
    }

    /// ステップ 1 のフッターのキャプション。
    ///
    /// 権限ステップを飛ばせるなら「押したらもう始まる」こと、飛ばせないなら
    /// 「次に何を確認されるのか」を書く。ボタンの文言と食い違わせない。
    private var footerCaption: String {
        shouldSkipPermissionsStep
            ? "全部 OFF なら権限は不要です。「この設定で始める」で今すぐ見張り始めます。"
            : "ON にした機能に必要な権限を次の画面で確認します。"
    }

    /// ステップ 1 のボタンの文言。
    ///
    /// 権限ステップを飛ばせるなら、押した瞬間に監視が始まる。「次へ」だと次の画面が
    /// 出ると思わせてしまうので、そこで終わることが分かる文言にする。
    private var nextTitle: String {
        shouldSkipPermissionsStep ? "この設定で始める" : "次へ(権限の確認)"
    }

    /// ステップ 2(権限画面)に見せるものが無いか。
    ///
    /// `permissions` は `onReceive` でトグルの変化を受け取っているので、body の再構成の
    /// たびに最新の設定で判定できる。
    private var shouldSkipPermissionsStep: Bool {
        SafetyModeViewModel.shouldSkipPermissionsStep(
            relevantKinds: permissions.relevantKinds,
            isIPhoneScreenshotEnabled: safety.isEnabled(.iphoneScreenshot)
        )
    }

    /// ステップ 2(権限画面)。見せるものが無ければステップ 1 のボタンで
    /// そのままオンボーディングを終える。
    private func goToPermissionsStep() {
        // 「次へ」を押した時点のトグルで判断する。`onReceive` が届く前でも、
        // 古い設定のまま権限画面を飛ばさないよう、ここでも必ず反映させる。
        permissions.apply(settings: safety.settings)
        if shouldSkipPermissionsStep {
            onStart()
        } else {
            step = .permissions
        }
    }

    @ViewBuilder
    private var permissionsStep: some View {
        VStack(spacing: 0) {
            // 「戻る」でステップ 1 のモード選択へ戻れる。OnboardingView 自体には
            // 手を加えず(権限画面の流れは #51 の範囲)、このフロー側で出す。
            HStack(spacing: 8) {
                Button("戻る", systemImage: "chevron.left") {
                    step = .mode
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // ステップ 1 と同じ tunneld インスタンスを渡す。ステップ 1 で ON にした
            // tunneld が別インスタンスだと、「登録する…」が二重の管理者パスワード
            // ダイアログを呼んでしまうため。
            OnboardingView(model: permissions, tunneld: tunneld, onStart: onStart)
        }
    }

    /// ステップ 1 で ON になった機能の事後処理。`AppCoordinator` 側の
    /// `onFeatureEnabled` と同じ意味の動きを、このフロー専用に持つ。
    private func enableFeature(_ feature: SafetyFeature) async {
        await permissions.request(for: feature)
        guard feature == .iphoneScreenshot else { return }
        // すでに常駐していれば管理者ダイアログは出さない。
        if tunneld.status != .running {
            await tunneld.install()
        }
    }
}
