import Foundation
import Testing

@testable import MihariCore

/// `~/.mihari/.env` への認証情報の読み書きを検証する。
///
/// 値そのものを外へ出さないこと(取れるのは `configuredKeys` だけ)と、手書きの行を
/// 壊さないことが要点。パーミッションとテンポラリの後始末も見る。
@Suite("認証情報の .env ストア")
struct EnvFileStoreTests {

    /// テストごとに空のディレクトリを掘る。
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mihari.test.env.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore() throws -> (EnvFileStore, URL) {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent(".env")
        return (EnvFileStore(url: url), url)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - パース

    @Test("コメント・空行・クォートを読み分ける")
    func parsesEnvFile() {
        let values = EnvFileStore.parse(
            """
            # これはコメント
            DISCORD_CLIENT_ID=123

              GEMINI_API_KEY = 'quoted value'
            DISCORD_BOT_TOKEN="double"
            # GEMINI_API_KEY=commented-out
            壊れた行
            """
        )

        #expect(values["DISCORD_CLIENT_ID"] == "123")
        #expect(values["GEMINI_API_KEY"] == "quoted value")
        #expect(values["DISCORD_BOT_TOKEN"] == "double")
        #expect(values["壊れた行"] == nil)
    }

    @Test("同じキーが複数あれば後勝ち(dotenv と同じ)")
    func lastAssignmentWins() {
        let values = EnvFileStore.parse("GEMINI_API_KEY=old\nGEMINI_API_KEY=new\n")
        #expect(values["GEMINI_API_KEY"] == "new")
    }

    @Test("値が入っているキーだけを設定済みとして返す")
    func reportsConfiguredKeys() throws {
        let (store, url) = try makeStore()
        try "DISCORD_CLIENT_ID=123\nDISCORD_BOT_TOKEN=\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(store.configuredKeys() == [.discordClientID])
    }

    @Test("ファイルが無ければ設定済みは空")
    func missingFileHasNoConfiguredKeys() throws {
        let (store, _) = try makeStore()
        #expect(store.configuredKeys().isEmpty)
    }

    // MARK: - 行置換

    @Test("既存のキーは同じ行で置き換わり、コメントも他のキーも残る")
    func replacesLineInPlace() throws {
        let (store, url) = try makeStore()
        try """
        # 手で書いたコメント
        DISCORD_CLIENT_ID=old
        MIHARI_SCREEN_MODEL=gemini-3.1-flash-lite

        """.write(to: url, atomically: true, encoding: .utf8)

        try store.save([.discordClientID: "new"])

        #expect(
            try read(url) == """
                # 手で書いたコメント
                DISCORD_CLIENT_ID='new'
                MIHARI_SCREEN_MODEL=gemini-3.1-flash-lite

                """
        )
    }

    @Test("同じキーが複数行あれば 1 行にまとめる")
    func collapsesDuplicateLines() throws {
        let (store, url) = try makeStore()
        try "GEMINI_API_KEY=old\nOTHER=1\nGEMINI_API_KEY=older\n"
            .write(to: url, atomically: true, encoding: .utf8)

        try store.save([.geminiAPIKey: "new"])

        #expect(try read(url) == "GEMINI_API_KEY='new'\nOTHER=1\n")
    }

    @Test("無いキーは末尾に足す")
    func appendsMissingKey() throws {
        let (store, url) = try makeStore()
        try "OTHER=1\n".write(to: url, atomically: true, encoding: .utf8)

        try store.save([.discordBotToken: "token"])

        #expect(try read(url) == "OTHER=1\nDISCORD_BOT_TOKEN='token'\n")
    }

    @Test("ファイルが無ければ作る")
    func createsFile() throws {
        let (store, url) = try makeStore()

        try store.save([.geminiAPIKey: "key"])

        #expect(try read(url) == "GEMINI_API_KEY='key'\n")
    }

    @Test("空の値は何も変えない")
    func emptyValueIsIgnored() throws {
        let (store, url) = try makeStore()
        try "DISCORD_CLIENT_ID=123\n".write(to: url, atomically: true, encoding: .utf8)

        try store.save([.discordClientID: "   ", .discordBotToken: ""])

        #expect(try read(url) == "DISCORD_CLIENT_ID=123\n")
    }

    @Test("値の前後の空白は落とす")
    func trimsValue() throws {
        let (store, url) = try makeStore()

        try store.save([.discordBotToken: "  token  "])

        #expect(try read(url) == "DISCORD_BOT_TOKEN='token'\n")
    }

    @Test("囲みを壊す値は保存させない")
    func rejectsQuoteInValue() throws {
        let (store, url) = try makeStore()

        #expect(throws: (any Error).self) { try store.save([.discordBotToken: "to'ken"]) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 削除

    @Test("削除は対象の行だけを消す")
    func removesOnlyTargetLine() throws {
        let (store, url) = try makeStore()
        try "# コメント\nDISCORD_BOT_TOKEN=token\nOTHER=1\n"
            .write(to: url, atomically: true, encoding: .utf8)

        try store.remove([.discordBotToken])

        #expect(try read(url) == "# コメント\nOTHER=1\n")
        #expect(store.configuredKeys().isEmpty)
    }

    @Test("最後の 1 本を消しても壊れない")
    func removesLastLine() throws {
        let (store, url) = try makeStore()
        try store.save([.geminiAPIKey: "key"])

        try store.remove([.geminiAPIKey])

        #expect(try read(url) == "")
    }

    // MARK: - 書き込みの作法

    @Test("ファイルは 0600、ディレクトリは 0700")
    func writesWithRestrictivePermissions() throws {
        let directory = try makeDirectory().appendingPathComponent("mihari", isDirectory: true)
        let url = directory.appendingPathComponent(".env")
        let store = EnvFileStore(url: url)

        try store.save([.geminiAPIKey: "key"])

        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let directoryMode =
            try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.int16Value == 0o600)
        #expect(directoryMode?.int16Value == 0o700)
    }

    @Test("書き込みのあとテンポラリが残らない")
    func leavesNoTemporaryFile() throws {
        let (store, url) = try makeStore()

        try store.save([.discordClientID: "123"])
        try store.save([.discordBotToken: "token"])

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(entries == [".env"])
    }

    @Test("既存ファイルの内容は書き換えの瞬間まで残る(置き換えは rename)")
    func replacesFileInOneStep() throws {
        let (store, url) = try makeStore()
        try "DISCORD_CLIENT_ID=123\n".write(to: url, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber

        try store.save([.discordClientID: "456"])

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        #expect(before != after, "同じ inode を上書きしている(rename で差し替えていない)")
    }

    // MARK: - 置き場所

    @Test("MIHARI_SETTINGS_DIR があればそのディレクトリの .env を使う")
    func honorsSettingsDirectoryEnvironment() throws {
        let directory = try makeDirectory()
        let store = EnvFileStore(environment: ["MIHARI_SETTINGS_DIR": directory.path])

        #expect(store.url.path == directory.appendingPathComponent(".env").path)
    }

    @Test("MIHARI_SETTINGS_DIR が無ければ ~/.mihari/.env")
    func fallsBackToHomeDirectory() {
        let store = EnvFileStore(environment: [:])

        #expect(store.url.path == ("~/.mihari/.env" as NSString).expandingTildeInPath)
    }
}
