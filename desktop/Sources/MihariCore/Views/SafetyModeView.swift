import AppKit
import SwiftUI

/// セーフティーの「モードを選ぶ画面」(オンボーディング 1 枚目)と「設定画面」。
///
/// 見た目は designer 提案(design-54.md)に従う。カードの文言は `SafetyFeature` の
/// `title` / `summary` / `destination` / `permissionNote` をそのまま使い、この View に
/// 文言を書かない。Toggle の操作は必ず `safety.request` を通し、結果の表示は
/// `SafetyModeViewModel` の純粋関数に委ねる(テストはそちらに対して書く)。
@MainActor
public struct SafetyModeView: View {

    /// この画面が置かれる場所。フッターと「設定画面のみ」の表示を出し分ける。
    public enum Context {
        /// オンボーディングの 1 枚目。「次へ」で権限ステップへ進む。
        case onboarding(onNext: () -> Void)
        /// 右クリックメニューから開く設定画面。「閉じる」で閉じる。
        case settings(onClose: () -> Void)
    }

    @ObservedObject private var safety: SafetySettingsStore
    /// いま監視中か。呼び側が渡す(オンボーディングでは常に false)。
    /// 値の変化は呼び側が `@ObservedObject` 経由で View を作り直して映す。
    private let isWatching: Bool
    private let context: Context
    private let onFeatureEnabled: (SafetyFeature) -> Void

    /// カードの状態行に 3 秒だけ出す文言。機能ごとに持つ。
    @State private var cardMessages: [SafetyFeature: String] = [:]
    /// 3 秒後の消去タスク。前のが残っているうちに次の操作をしたら張り直す。
    @State private var messageTasks: [SafetyFeature: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - isWatching: いま監視中か。設定画面では `AppCoordinator` の `isWatching` を映す。
    ///   - onFeatureEnabled: ON に成功した(`.apply` で新たに ON になった)機能ごとに呼ばれる。
    ///     呼び側が権限要求・tunneld 登録に使う。
    public init(
        safety: SafetySettingsStore,
        isWatching: Bool,
        context: Context,
        onFeatureEnabled: @escaping (SafetyFeature) -> Void
    ) {
        self.safety = safety
        self.isWatching = isWatching
        self.context = context
        self.onFeatureEnabled = onFeatureEnabled
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(.bar)
            Divider()
            ScrollView {
                scrollContent
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }

    // MARK: - 固定ヘッダー

    /// モード名・モードの一言・7 個のインジケータ。どれもスクロールしない。
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    safety.mode.label,
                    systemImage: SafetyModeViewModel.modeIcon(for: safety.mode)
                )
                .font(.title2.bold())
                .foregroundStyle(Self.modeColor(for: safety.mode))
                // モードが変わるとき、色とアイコンだけ 0.15 秒で滑らかに切り替える。
                .animation(.easeInOut(duration: 0.15), value: safety.mode)

                Spacer()

                Button("全部 ON") { applyAllOn() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(
                        safety.settings.enabled.count == SafetyFeature.total || isWatching
                    )
                Button("全部 OFF") { applyAllOff() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(safety.settings.enabled.isEmpty)
            }

            Text(SafetyModeViewModel.modeSubtitle(for: safety.mode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            indicators
                // インジケータの色もモードが変わるときだけ 0.15 秒で滑らかにする。
                .animation(.easeInOut(duration: 0.15), value: safety.mode)
        }
    }

    /// 7 個のインジケータ。ON = アクセント、OFF = 薄いグレー、
    /// 依存で無効 = 輪郭のみ、予約中 = オレンジ。
    private var indicators: some View {
        HStack(spacing: 10) {
            ForEach(SafetyFeature.allCases, id: \.self) { feature in
                indicator(for: feature)
            }
        }
    }

    private func indicator(for feature: SafetyFeature) -> some View {
        VStack(spacing: 2) {
            Circle()
                .frame(width: 8, height: 8)
                .foregroundStyle(indicatorFill(for: feature))
                .overlay {
                    if isDependencyDisabled(feature) {
                        Circle().strokeBorder(Color.secondary, lineWidth: 1)
                    }
                }
            Text(SafetyModeViewModel.shortFeatureName(for: feature))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 44)
    }

    private func indicatorFill(for feature: SafetyFeature) -> Color {
        if isPending(feature) {
            return .orange
        }
        if safety.isEnabled(feature) {
            return .accentColor
        }
        if isDependencyDisabled(feature) {
            return .clear
        }
        return Color.secondary.opacity(0.35)
    }

    // MARK: - カード一覧

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SafetyFeature.allCases, id: \.self) { feature in
                card(for: feature)
            }

            Divider()

            changeLaterRow

            if case .settings = context, isPending {
                bottomPendingBand
            }
        }
    }

    /// 1 枚のカード。依存で無効(iphonePresence が OFF のときの iphoneScreenshot)は
    /// 親カードの下辺から吊り線でぶら下がる形にする。
    @ViewBuilder
    private func card(for feature: SafetyFeature) -> some View {
        if isDependencyDisabled(feature) {
            VStack(alignment: .leading, spacing: 0) {
                // 吊り線: 親カードの下辺から縦 12pt、横 22pt。カード間の 12pt をまたいで
                // 親の下辺に届くよう、ブロックの上端から 12pt 上へずらし、横線はカードの
                // 上端の高さに合わせる。
                HStack(alignment: .bottom, spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 2, height: 12)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 22, height: 2)
                    Spacer(minLength: 0)
                }
                .offset(y: -12)

                if !isWatching {
                    // この行だけ opacity 1(カード本体は 0.5 で沈める)。
                    Label(
                        "「iPhone を見張る」を ON にすると選べます",
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
                    .padding(.bottom, 4)
                }

                cardBody(for: feature)
                    .padding(.leading, 24)
                    .opacity(0.5)
            }
        } else {
            cardBody(for: feature)
        }
    }

    private func cardBody(for feature: SafetyFeature) -> some View {
        HStack(spacing: 0) {
            // 左端の 3pt バー。ON のときだけアクセント、予約中はオレンジ、それ以外は透明。
            Rectangle()
                .fill(leftBarColor(for: feature))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.title)
                            .font(.headline)
                        Text(feature.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if isLockedRowShown(for: feature) {
                        Label("監視中は変更できません", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: toggleBinding(for: feature))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(isToggleDisabled(for: feature))
                }

                // 注意帯。iphoneScreenshot と quitLock の 2 枚だけ。
                if let notice = SafetyModeViewModel.notice(for: feature) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("送り先")
                            .font(.caption)
                            .bold()
                            .foregroundStyle(.secondary)
                        Text(feature.destination)
                            .font(.callout)
                    }
                    GridRow {
                        Text("権限")
                            .font(.caption)
                            .bold()
                            .foregroundStyle(.secondary)
                        Text(feature.permissionNote)
                            .font(.callout)
                    }
                }

                statusRow(for: feature)
            }
            .padding(14)
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 状態行。3 秒だけの文言と、設定画面の予約帯を並べる。
    @ViewBuilder
    private func statusRow(for feature: SafetyFeature) -> some View {
        if let message = cardMessages[feature] {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if case .settings = context, let pending = safety.settings.pendingChange,
            pending.disabling.contains(feature)
        {
            pendingBand(effectiveAt: pending.effectiveAt) {
                _ = safety.request(.cancelPendingChange, isWatching: isWatching)
            }
        }
    }

    /// 予約帯(取り消しボタン付き)。カード内と設定画面の最下部で同じ見た目にする。
    private func pendingBand(effectiveAt: Date, onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(
                SafetyModeViewModel.pendingStatusText(effectiveAt: effectiveAt),
                systemImage: "clock"
            )
            Spacer()
            Button("取り消す", action: onCancel)
                .controlSize(.small)
        }
        .font(.caption)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 設定画面の最下部の予約帯。カードの予約帯より上に「取り消す」の意味を
    /// 1 本にまとめたいときは閉じる側でカード側を隠すこともできるが、design-54.md は
    /// 両方出す形なのでそのままにする。
    private var bottomPendingBand: some View {
        pendingBand(effectiveAt: safety.settings.pendingChange?.effectiveAt ?? Date()) {
            _ = safety.request(.cancelPendingChange, isWatching: isWatching)
        }
    }

    // MARK: - 最下部の行

    /// 「あとで設定を変えられるようにする」。OFF の間は緩める変更が 24 時間後の予約になる。
    private var changeLaterRow: some View {
        Toggle(isOn: changeLaterBinding) {
            VStack(alignment: .leading, spacing: 4) {
                Text("あとで設定を変えられるようにする")
                    .font(.body)
                Text(
                    safety.settings.canChangeLater
                        ? "いつでも設定を変えられます。"
                        : "緩める変更は 24 時間後に効くようになります。"
                )
                .font(.caption)
                .foregroundStyle(safety.settings.canChangeLater ? Color.secondary : Color.orange)
            }
        }
        .toggleStyle(.switch)
    }

    private var changeLaterBinding: Binding<Bool> {
        Binding(
            get: { safety.settings.canChangeLater },
            set: { enabled in
                _ = safety.request(.setCanChangeLater(enabled), isWatching: isWatching)
            }
        )
    }

    // MARK: - 固定フッター

    @ViewBuilder
    private var footer: some View {
        switch context {
        case .onboarding(let onNext):
            HStack {
                Text("全部 OFF のままでも始められます。あとから設定で変えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("次へ", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .settings(let onClose):
            HStack {
                if isWatching {
                    Label("監視中: ON にする変更はできません", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる", action: onClose)
                    .controlSize(.large)
            }
        }
    }

    // MARK: - 操作

    /// カードの Toggle を操作したとき。ポリシーに問い合わせて、結果に応じて
    /// 状態行を見せ、ON になった機能を呼び出し側へ知らせる。
    private func handleToggle(for feature: SafetyFeature, turningOn: Bool) {
        let previous = safety.settings
        let decision = safety.request(
            SafetyModeViewModel.toggleChange(for: feature, turningOn: turningOn),
            isWatching: isWatching
        )
        handleDecision(decision, from: previous, affectedFeature: feature)
    }

    private func applyAllOn() {
        let previous = safety.settings
        let decision = safety.request(.enableAll, isWatching: isWatching)
        // 拒否は起こり得ない(監視中はボタンが押せない)が、来たときの出し先が要るだけ。
        handleDecision(decision, from: previous, affectedFeature: .macCamera)
    }

    private func applyAllOff() {
        let previous = safety.settings
        let decision = safety.request(.disableAll, isWatching: isWatching)
        handleDecision(decision, from: previous, affectedFeature: .macCamera)
    }

    private func handleDecision(
        _ decision: SafetyDecision,
        from previous: SafetySettings,
        affectedFeature: SafetyFeature
    ) {
        switch decision {
        case .apply(let newSettings, let skipped):
            // ON に成功した機能ごとに、呼び側の権限要求・tunneld 登録を促す。
            // 依頼どおりできなかった機能(監視中に残した quitLock など)は状態行で伝える。
            for feature in newSettings.enabled.subtracting(previous.enabled) {
                onFeatureEnabled(feature)
            }
            for feature in skipped {
                showMessage(
                    SafetyModeViewModel.statusMessage(for: decision) ?? "",
                    on: feature
                )
            }
        case .schedule:
            // 予約帯が出て結果を示すので、ここでは何もしない。
            break
        case .reject:
            if let message = SafetyModeViewModel.statusMessage(for: decision) {
                showMessage(message, on: affectedFeature)
            }
        }
    }

    /// 状態行に 3 秒だけメッセージを出す。前のが残っていれば取り消して張り直す。
    private func showMessage(_ message: String, on feature: SafetyFeature) {
        cardMessages[feature] = message
        messageTasks[feature]?.cancel()
        // タスクは @State に持つので、ビューが作り直されても消えない。self は
        // 値型のコピーを捉えるだけで循環はしない。
        messageTasks[feature] = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.cardMessages[feature] = nil
        }
    }

    private func toggleBinding(for feature: SafetyFeature) -> Binding<Bool> {
        Binding(
            get: { safety.isEnabled(feature) },
            set: { turningOn in handleToggle(for: feature, turningOn: turningOn) }
        )
    }

    // MARK: - 状態

    /// 予約中(発効待ち)か。予約の対象になっている機能と設定画面の最下部で使う。
    private var isPending: Bool {
        safety.settings.pendingChange != nil
    }

    private func isPending(_ feature: SafetyFeature) -> Bool {
        safety.settings.pendingChange?.disabling.contains(feature) == true
    }

    /// 前提(`requires`)のトグルが OFF で選べない機能か。
    private func isDependencyDisabled(_ feature: SafetyFeature) -> Bool {
        guard let required = feature.requires else { return false }
        return !safety.isEnabled(required)
    }

    /// Toggle 左に錠の行を出すか。監視中は ON 方向が一切できないので、
    /// OFF のままの機能すべてに出す(ON 中の機能は OFF はできる。quitLock だけ例外)。
    private func isLockedRowShown(for feature: SafetyFeature) -> Bool {
        isWatching && !safety.isEnabled(feature)
    }

    /// Toggle を押せなくするか。
    ///
    /// - 依存で無効: 常に押せない。
    /// - 監視中で OFF の機能: ON 方向がポリシーに拒否されるので押せない。
    /// - quitLock が ON の監視中: OFF も拒否されるが、その理由を状態行で見せるため
    ///   あえて押せるままにする。
    private func isToggleDisabled(for feature: SafetyFeature) -> Bool {
        if isDependencyDisabled(feature) {
            return true
        }
        if isWatching {
            if feature == .quitLock, safety.isEnabled(.quitLock) {
                return false
            }
            return !safety.isEnabled(feature)
        }
        return false
    }

    private func leftBarColor(for feature: SafetyFeature) -> Color {
        if isPending(feature) {
            return .orange
        }
        return safety.isEnabled(feature) ? .accentColor : .clear
    }

    /// モードのシンボルカラー。design-54.md の 3 段階をそのまま映す。
    private static func modeColor(for mode: SafetyMode) -> Color {
        switch mode {
        case .safety: return .green
        case .custom: return .accentColor
        case .unlimited: return .orange
        }
    }
}
