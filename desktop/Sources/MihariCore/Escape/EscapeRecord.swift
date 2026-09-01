import Foundation

/// 執行猶予脱出の記録 1 本分。
///
/// 本体アプリが終了するときに書き、watchdog(別プロセス)と次の起動がこれを読んで
/// 「宣言時刻まで起こさない」「戻ってきたかを投稿する」の判断に使う。
public struct EscapeRecord: Codable, Equatable, Sendable {
    /// 脱出(10 分カウントダウンが終わって終了)した時刻。
    public var escapedAt: Date
    /// 戻ると宣言した時刻。この時刻を過ぎるまで watchdog は本体を起こさない。
    public var returnAt: Date

    public init(escapedAt: Date, returnAt: Date) {
        self.escapedAt = escapedAt
        self.returnAt = returnAt
    }
}

/// 執行猶予脱出の記録の保存先。
///
/// watchdog(本体とは別プロセス)も読むため、UserDefaults ではなくファイルに置く。
/// パスは `~/Library/Application Support/Mihari/escape.json`。
public enum EscapeRecordStore {

    /// 記録の保存先。テストでは一時ディレクトリを渡す。
    public static func url(
        applicationSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser,
        filename: String = "escape.json"
    ) -> URL {
        applicationSupport.appendingPathComponent("Mihari", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// 読み込む。無ければ `nil`。
    public static func load(from url: URL) -> EscapeRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EscapeRecord.self, from: data)
    }

    /// 保存する。
    public static func save(_ record: EscapeRecord, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 途中で書き込みが割れても古い記録が読まれないよう、atomic で置き換える。
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    /// 削除する。無ければ何もしない。
    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
