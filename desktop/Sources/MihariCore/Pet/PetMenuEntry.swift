import Foundation

/// ペットメニューの 1 項目。右クリック(NSMenu)とメニューバー(SwiftUI)で同じ並びを出すための共通表現。
public enum PetMenuEntry {
    /// 項目。`isChecked` が true ならチェックを付ける。`isEnabled` が false なら
    /// 灰色にして押せなくする(理由はタイトルに載せる)。
    case item(
        title: String,
        isChecked: Bool = false,
        isEnabled: Bool = true,
        action: @MainActor () -> Void
    )
    /// 入れ子のメニュー。
    case submenu(title: String, entries: [PetMenuEntry])
    /// 区切り線。
    case separator
}

/// ペットメニューの並びを 1 か所で決める。
///
/// 右クリック(`PetContextMenu`)もメニューバー(`PetMenuContent`)もここから作るので、
/// 項目を足すときはここだけを直せばよい。
public enum PetMenuEntries {

    /// メニューの並びを組み立てる。呼ぶたびに、そのときの状態でチェックと文言を決める。
    @MainActor
    public static func make<Actions: PetMenuActions>(
        actions: Actions,
        presenter: LivePetPresenter
    ) -> [PetMenuEntry] {
        let pet = presenter.controller
        var entries: [PetMenuEntry] = [
            // 最上段はセーフティーモードの表示。押すと設定画面(中身は #54)へ。
            .item(
                title: actions.safetyStatusLine,
                action: { actions.openSafetySettings() }
            ),
            .separator,
            .item(
                title: actions.isWatching ? "監視を止める" : "監視を再開する",
                action: {
                    if actions.isWatching {
                        actions.stopWatching()
                    } else {
                        actions.startWatching()
                    }
                }
            ),
            .item(
                title: "在席スタンプを押す",
                action: { actions.stampAttendance() }
            ),
            .item(
                title: actions.isOnBreak ? "休憩を終える" : "休憩する(15 分)",
                action: {
                    if actions.isOnBreak {
                        actions.endBreak()
                    } else {
                        actions.startBreak()
                    }
                }
            ),
            .separator,
            .item(
                title: "セーフティー設定…",
                action: { actions.openSafetySettings() }
            ),
            .item(
                title: "Discord 設定…",
                action: { actions.openDiscordSettings() }
            ),
            .item(
                title: "権限の確認…",
                action: { actions.openPermissions() }
            ),
            .separator,
            .submenu(
                title: "サイズ",
                entries: PetScale.allCases.map { item -> PetMenuEntry in
                    .item(
                        title: item.label,
                        isChecked: pet.scale == item.rawValue,
                        action: { pet.setScale(item.rawValue) }
                    )
                }
            ),
            .item(
                title: "声を出す",
                isChecked: pet.isVoiceEnabled,
                action: { pet.setVoiceEnabled(!pet.isVoiceEnabled) }
            ),
            .item(
                title: "状態パネルを表示",
                isChecked: actions.isStatusPanelVisible,
                action: { actions.toggleStatusPanel() }
            ),
            .item(
                title: "スクショに写り込む",
                isChecked: actions.isPhotobombEnabled,
                action: { actions.setPhotobombEnabled(!actions.isPhotobombEnabled) }
            ),
        ]
        // 執行猶予脱出は quitLock が ON でロック中のときだけ出す(#52)。
        switch actions.escapeMenuState {
        case .available:
            entries.append(
                .item(title: "どうしても終了する…", action: { actions.openEscapeDialog() })
            )
        case .coolingDown(let remaining):
            // 冷却中は灰色にして押せなくする。理由はタイトルに載せて伝える。
            entries.append(
                .item(
                    title: "どうしても終了する(あと\(EscapePolicy.durationDescription(remaining))で使えます)",
                    isEnabled: false,
                    action: {}
                )
            )
        case .countingDown(let remaining):
            entries.append(
                .item(
                    title: "終了を取り消す(あと\(EscapePolicy.durationDescription(remaining)))",
                    action: { actions.cancelEscape() }
                )
            )
        case .hidden:
            break
        }
        // デバッグメニューは開発中だけ出す。一般ユーザーの右クリックから消すのと同時に、
        // その直前の区切り線も消して「実在しない見た目の項目」を残さない。
        if actions.isDebugMenuVisible {
            entries.append(.separator)
            entries.append(
                .submenu(
                    title: "デバッグ",
                    entries: PetDebugMenuEntries.make(actions: actions, presenter: presenter)
                )
            )
        }
        return entries
    }
}
