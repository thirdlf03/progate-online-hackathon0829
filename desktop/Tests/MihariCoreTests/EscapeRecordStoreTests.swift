import Foundation
import Testing

@testable import MihariCore

/// 執行猶予脱出の記録(EscapeRecord)のファイル保存を検証する。
@Suite("執行猶予脱出の記録")
struct EscapeRecordStoreTests {

    /// 実行のたびに一時ディレクトリを作り、テスト同士がファイルを共有しないようにする。
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mihari.test.escape.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("escape.json")
    }

    @Test("保存して読み込むと元の記録が戻る")
    func saveAndLoadRoundTrip() throws {
        let url = makeURL()
        let record = EscapeRecord(
            escapedAt: Date(timeIntervalSince1970: 100),
            returnAt: Date(timeIntervalSince1970: 200)
        )

        try EscapeRecordStore.save(record, to: url)

        #expect(EscapeRecordStore.load(from: url) == record)
    }

    @Test("何も無ければ読み込みは nil")
    func loadReturnsNilWhenMissing() {
        let url = makeURL()

        #expect(EscapeRecordStore.load(from: url) == nil)
    }

    @Test("削除すると読み込めなくなる。無ければ何もしない")
    func removeDeletesTheRecord() throws {
        let url = makeURL()
        let record = EscapeRecord(
            escapedAt: Date(timeIntervalSince1970: 100),
            returnAt: Date(timeIntervalSince1970: 200)
        )
        try EscapeRecordStore.save(record, to: url)

        EscapeRecordStore.remove(at: url)

        #expect(EscapeRecordStore.load(from: url) == nil)
        // 2 回目は何も起きない(例外も出さない)。
        EscapeRecordStore.remove(at: url)
    }
}
