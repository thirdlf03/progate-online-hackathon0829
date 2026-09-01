import AppKit
import SwiftUI

/// 起動時に出す権限オンボーディング。
///
/// Mihari は本人の顔と画面を Discord に送るアプリなので、
/// 「どの権限が何に使われるか」を最初に見せることを画面の役割の中心に置いている。
public struct OnboardingView: View {
    @ObservedObject var model: PermissionsModel
    /// iPhone スクショに必要な tunneld の常駐状態。TCC の権限ではないが、
    /// 「最初に 1 回だけ承認する」という意味でこの画面に並べる。
    /// 解除(ON→OFF)は `AppCoordinator` がトグル購読で行うため、こちらで持たない。
    @ObservedObject var tunneld: TunneldModel
    /// 「始める」を押したときの処理。必須権限が揃うまでボタンは押せない。
    private let onStart: (() -> Void)?
    /// 「閉じる」を押したときの処理。すでに見張っている状態で開き直したときに使う。
    private let onClose: (() -> Void)?

    /// - Parameters:
    ///   - onStart: 渡すと「始める」ボタンを出す。必須権限が揃うまで押せない。
    ///   - onClose: 渡すと「閉じる」ボタンを出す。`onStart` を渡したときはそちらが優先される。
    public init(
        model: PermissionsModel,
        tunneld: TunneldModel,
        onStart: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.model = model
        self.tunneld = tunneld
        self.onStart = onStart
        self.onClose = onClose
    }

    public var body: some View {
        // 権限の行数だけ縦に伸びるので、ウィンドウを縮めてもヘッダーが見切れないようスクロールさせる。
        ScrollView {
            content
        }
        .task {
            model.refresh()
            await tunneld.refresh()
            await model.requestOnFirstLaunchIfNeeded()
        }
        // システム設定で許可してから戻ってきたときに、押し直さなくても反映されるようにする。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
            Task { await tunneld.refresh() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 0) {
                ForEach(Array(model.relevantKinds.enumerated()), id: \.element.id) { index, kind in
                    PermissionRow(
                        kind: kind,
                        state: model.state(for: kind),
                        onRequest: { Task { await model.request(kind) } },
                        onOpenSettings: { model.openSettings(for: kind) }
                    )
                    if index < model.relevantKinds.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if model.settings.isEnabled(.iphoneScreenshot) {
                tunneldSection
            }

            if let message = model.lastMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            footer

            notes
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 画面を閉じて先へ進むためのボタン。呼び出し側が渡した処理に応じて出し分ける。
    @ViewBuilder private var footer: some View {
        if let onStart {
            HStack(spacing: 10) {
                Button("始める", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.isRequiredSatisfied)

                if !model.isRequiredSatisfied {
                    Text("必須の権限が足りません: \(model.missingRequired.map(\.title).joined(separator: " / "))")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        } else if let onClose {
            HStack {
                Button("閉じる", action: onClose)
                    .controlSize(.large)
                Spacer()
            }
        }
    }

    /// iPhone スクショ(iOS 17+)に必要な tunneld の常駐を、この画面から登録できるようにする。
    /// tunneld は root でしか動かせないため、管理者パスワードダイアログを 1 回だけ出して
    /// launchd(LaunchDaemon)に任せる。以後は再起動しても自動で立ち上がる。
    private var tunneldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone スクショの常駐(tunneld)").font(.headline)
                    Text("iOS 17+ のスクショに必要なトンネルを OS に常駐させます。登録は管理者パスワードで 1 回だけです")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch tunneld.status {
                case .running:
                    Label("常駐中", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .installing:
                    ProgressView().controlSize(.small)
                case .checking, .unknown:
                    Text("確認中…").font(.callout).foregroundStyle(.secondary)
                case .notRunning:
                    Button("登録する…") { Task { await tunneld.install() } }
                }
            }
            if let message = tunneld.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("権限の確認").font(.title2).bold()
            Text("ステップ 1 で ON にした機能に必要な権限だけ確認します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let names = enabledFeatureNames {
                Text("ON にした機能: \(names)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("まとめて許可を求める") { Task { await model.requestAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRequesting)

                Button("すべて再チェック") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isRequesting)

                if let at = model.lastCheckedAt {
                    Text("最終チェック: \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(summary)
                    .font(.callout)
                    .foregroundStyle(model.pending.isEmpty ? .green : .orange)
            }
            .padding(.top, 4)
        }
    }

    /// ON にしている機能の名前を並べた 1 行。1 つも ON でなければ nil。
    ///
    /// 「何のためにこの権限を聞かれているのか」は、ON にした機能を並べて示す。
    private var enabledFeatureNames: String? {
        let names = SafetyFeature.allCases
            .filter { model.settings.isEnabled($0) }
            .map(\.title)
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var summary: String {
        let pending = model.pending
        if pending.isEmpty {
            return "すべて許可済み"
        }
        return "未許可: \(pending.map(\.title).joined(separator: " / "))"
    }

    /// TCC の挙動についての注記。開発者向けなので `MIHARI_DEBUG_UI=1` のときだけ出す。
    @ViewBuilder private var notes: some View {
        if AppCoordinator.isDebugUIRequested {
            VStack(alignment: .leading, spacing: 6) {
                noteText(
                    "TCC の許可はプロセスではなくバンドルの署名単位で記録されます。ad-hoc 署名は再ビルドで署名が変わりうるため、一度許可した権限が再ビルド後に効かなくなることがあります。その場合はシステム設定から一度削除して登録し直してください。"
                )
                noteText(
                    "「画面収録」は事前照会の API が CGPreflightScreenCaptureAccess しかなく、未決定と拒否済みを区別できません。false のときは灰色で出ます。"
                )
                noteText(
                    "「オートメーション」は対象アプリ(Music)が起動していないと判定できません。プロンプトは実際に命令を送った瞬間にだけ出ます。"
                )
            }
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
