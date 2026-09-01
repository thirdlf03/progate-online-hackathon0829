import SwiftUI

/// 執行猶予脱出の宣言ダイアログ。
///
/// 戻るまでの時間を選び、「終了を始める」で 10 分のカウントダウンに入る。
/// 選べる時間は `EscapePolicy.returnDelayChoices` が決める(15 分刻み、ロック解除まで)。
public struct EscapeDialogView: View {
    /// 戻るまでの時間の選択肢。
    private let choices: [TimeInterval]
    /// 「終了を始める」を押したときの処理。選ばれた戻るまでの時間を渡す。
    private let onStart: (TimeInterval) -> Void
    /// 「やめる」を押したときの処理。
    private let onCancel: () -> Void

    @State private var selected: TimeInterval

    public init(
        choices: [TimeInterval],
        onStart: @escaping (TimeInterval) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.choices = choices
        self.onStart = onStart
        self.onCancel = onCancel
        _selected = State(initialValue: choices.first ?? EscapePolicy.minReturnDelay)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("どうしても終了する…").font(.headline)

            Text("10 分後に終了します。宣言した時刻に自動で戻ってきて、監視を再開します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("戻ってくる時刻", selection: $selected) {
                ForEach(choices, id: \.self) { delay in
                    Text(EscapePolicy.durationDescription(delay)).tag(delay)
                }
            }

            HStack {
                Button("やめる") { onCancel() }
                Spacer()
                Button("終了を始める") { onStart(selected) }
                    .buttonStyle(.borderedProminent)
                    // 選択肢が 1 つも無い(ロックの残りが 15 分未満)ときは押せない。
                    .disabled(choices.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
