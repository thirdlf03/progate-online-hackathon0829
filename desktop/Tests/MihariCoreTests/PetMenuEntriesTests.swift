import Foundation
import Testing

@testable import MihariCore

/// ペットメニューの並びが、そのときの状態をチェックに映すかを検証する。
@Suite("ペットメニューの並び")
@MainActor
struct PetMenuEntriesTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が表示設定を共有しないようにする。
    private func makePresenter() -> LivePetPresenter {
        let suiteName = "mihari.test.petMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LivePetPresenter(controller: PetController(defaults: defaults))
    }

    /// タイトルの一致する項目を探す。
    private func findItem(
        _ title: String,
        in entries: [PetMenuEntry]
    ) -> (isChecked: Bool, action: @MainActor () -> Void)? {
        for entry in entries {
            if case .item(let itemTitle, let isChecked, let action) = entry, itemTitle == title {
                return (isChecked, action)
            }
        }
        return nil
    }

    @Test("「スクショに写り込む」のチェックは写り込みの入り / 切りを映し、押すと切り替わる")
    func photobombEntryReflectsAndTogglesTheSetting() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let enabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(enabled.isChecked)

        enabled.action()
        #expect(actions.isPhotobombEnabled == false)

        let disabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(disabled.isChecked == false)
    }

    @Test("デバッグメニューは isDebugMenuVisible == false ならサブメニューごと出ない")
    func debugSubmenuDisappearsWhenHidden() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        actions.isDebugMenuVisible = false

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)

        // 「デバッグ」サブメニューと、その直前の区切り線が一緒に消える。
        let hasDebugSubmenu = entries.contains { entry in
            if case .submenu(let title, _) = entry { return title == "デバッグ" }
            return false
        }
        #expect(!hasDebugSubmenu)
        let separatorCount = entries.reduce(into: 0) { count, entry in
            if case .separator = entry { count += 1 }
        }
        // (監視 / 在席 / 休憩)と(Discord / 権限)の区切り 2 本だけになる。
        #expect(separatorCount == 2)

        // 見える設定なら(既定どおり)デバッグサブメニューが最後に付く。
        let visible = StubPetMenuActions()
        let visibleEntries = PetMenuEntries.make(actions: visible, presenter: presenter)
        let last = try #require(visibleEntries.last)
        guard case .submenu("デバッグ", _) = last else {
            Issue.record("デバッグサブメニューが最後に付いていない")
            return
        }
    }

    @Test("執行猶予脱出の項目は状態どおりに出る(冷却中は押しても何もしない)")
    func escapeEntriesReflectTheState() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        // 使えるとき: 宣言ダイアログを開く。
        actions.escapeMenuState = .available
        let open = try #require(
            findItem("どうしても終了する…", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        open.action()
        #expect(actions.escapeDialogOpens == 1)

        // カウントダウン中: 取り消し項目に変わり、残り時間を出す。
        actions.escapeMenuState = .countingDown(remaining: 2 * 60)
        let cancel = try #require(
            findItem("終了を取り消す(あと2 分)", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        cancel.action()
        #expect(actions.escapeCancels == 1)
        #expect(findItem("どうしても終了する…", in: PetMenuEntries.make(actions: actions, presenter: presenter)) == nil)

        // 冷却中: 押せない(何もしない)項目として、理由をタイトルに載せる。
        actions.escapeMenuState = .coolingDown(remaining: 23 * 3600)
        let cooling = try #require(
            findItem("どうしても終了する(あと23 時間 0 分で使えます)", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        cooling.action()
        #expect(actions.escapeDialogOpens == 1)
        #expect(actions.escapeCancels == 1)

        // ロック外など hidden のときはどちらも出ない。
        actions.escapeMenuState = .hidden
        let hidden = PetMenuEntries.make(actions: actions, presenter: presenter)
        #expect(findItem("どうしても終了する…", in: hidden) == nil)
        #expect(findItem("終了を取り消す", in: hidden) == nil)
    }
}
