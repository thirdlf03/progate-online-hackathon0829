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

    @Test("先頭はモード行で、その直後に区切り線が来る")
    func firstEntriesAreTheModeLine() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        guard case .item(let title, _, _) = entries.first else {
            Issue.record("先頭が項目でない")
            return
        }
        #expect(title == actions.safetyStatusLine)
        guard case .separator = entries[1] else {
            Issue.record("モード行の直後に区切り線が無い")
            return
        }
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
        // (モード)と(監視 / 在席 / 休憩)と(Discord / 権限)の区切り 3 本だけになる。
        #expect(separatorCount == 3)

        // 見える設定なら(既定どおり)デバッグサブメニューが最後に付く。
        let visible = StubPetMenuActions()
        let visibleEntries = PetMenuEntries.make(actions: visible, presenter: presenter)
        let last = try #require(visibleEntries.last)
        guard case .submenu("デバッグ", _) = last else {
            Issue.record("デバッグサブメニューが最後に付いていない")
            return
        }
    }
}
