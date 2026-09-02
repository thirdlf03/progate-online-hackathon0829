import Foundation

private struct EnvFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// bridge が使う認証情報を、設定ディレクトリの `.env`(既定は `~/.mihari/.env`)に読み書きする。
///
/// bridge は「実環境変数 > 設定ディレクトリの .env > bridge/.env」の順に読む。ここが書くのは
/// 真ん中で、開発用の `bridge/.env` より優先される。
///
/// 値は画面にもログにも出さない。外から取れるのは「入っているかどうか」だけにする。
public struct EnvFileStore {

    /// このストアが触るキー。これ以外の行(他のキー・コメント・空行)は書き換えない。
    public enum Key: String, CaseIterable, Sendable {
        case discordClientID = "DISCORD_CLIENT_ID"
        case discordBotToken = "DISCORD_BOT_TOKEN"
        case geminiAPIKey = "GEMINI_API_KEY"

        /// 画面に出す名前。
        public var label: String {
            switch self {
            case .discordClientID: "APPLICATION ID"
            case .discordBotToken: "Bot トークン"
            case .geminiAPIKey: "Gemini API キー"
            }
        }
    }

    /// `MIHARI_SETTINGS_DIR` が無いときの設定ディレクトリ。bridge 側と同じ決め方にする。
    static let defaultDirectory = "~/.mihari"

    /// 読み書きするファイル。
    public let url: URL

    private let fileManager: FileManager

    /// - Parameters:
    ///   - environment: 環境変数。`MIHARI_SETTINGS_DIR` があればそのディレクトリを使う。
    ///   - fileManager: テストで差し替える。
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let raw = environment["MIHARI_SETTINGS_DIR"] ?? Self.defaultDirectory
        let directory = URL(
            fileURLWithPath: (raw as NSString).expandingTildeInPath,
            isDirectory: true
        )
        self.init(url: directory.appendingPathComponent(".env"), fileManager: fileManager)
    }

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    /// 値が入っているキー。値そのものは返さない。
    public func configuredKeys() -> Set<Key> {
        let values = Self.parse(read())
        return Set(Key.allCases.filter { !(values[$0.rawValue] ?? "").isEmpty })
    }

    /// 渡したキーだけを書き換える。空文字のキーは何もしない(消すのは `remove`)。
    public func save(_ values: [Key: String]) throws {
        var changes: [Key: String?] = [:]
        for (key, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // 書き出しはシングルクォートで囲む(下記 render)。囲みを壊す文字だけ弾く。
            guard !trimmed.contains("'"), !trimmed.contains(where: \.isNewline) else {
                throw EnvFileError(message: "\(key.label) に ' と改行は使えない")
            }
            changes[key] = trimmed
        }
        guard !changes.isEmpty else { return }
        try write(Self.apply(changes, to: read()))
    }

    /// 渡したキーの行を消す。
    public func remove(_ keys: Set<Key>) throws {
        guard !keys.isEmpty else { return }
        let changes = Dictionary(uniqueKeysWithValues: keys.map { ($0, String?.none) })
        try write(Self.apply(changes, to: read()))
    }

    // MARK: - 中身の組み立て

    /// 対象キーの行だけを置き換え(値が `nil` なら削除し)、他の行はそのまま残す。
    ///
    /// 元のファイルに無いキーは末尾に足す。同じキーが複数行あるときは、最初の 1 行だけを
    /// 結果に残して残りを落とす(dotenv は後勝ちなので、置き換えたはずの古い行が
    /// 生き残らないようにする)。
    static func apply(_ changes: [Key: String?], to text: String) -> String {
        var result: [String] = []
        var replaced: Set<Key> = []

        for line in text.isEmpty ? [] : text.components(separatedBy: "\n") {
            guard let key = keyOfAssignment(in: line), let change = changes[key] else {
                result.append(line)
                continue
            }
            guard !replaced.contains(key) else { continue }
            replaced.insert(key)
            if let value = change {
                result.append(render(key, value))
            }
        }

        // 元のファイル末尾の空行(改行で終わっていれば必ず 1 つ出る)を落としてから足す。
        // 足した行が空行の後ろに来て、間に穴が空くのを防ぐ。
        while result.last?.isEmpty == true {
            result.removeLast()
        }
        for key in Key.allCases where !replaced.contains(key) {
            guard let change = changes[key], let value = change else { continue }
            result.append(render(key, value))
        }

        guard !result.isEmpty else { return "" }
        return result.joined(separator: "\n") + "\n"
    }

    /// `.env` を読んで `キー: 値` にする。コメント行と代入でない行は無視する。
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let raw = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            // 同じキーが複数あれば後勝ち。dotenv の読み方に合わせる。
            values[name] = unquote(raw)
        }
        return values
    }

    /// その行が対象キーへの代入なら、そのキー。コメント行や他のキーなら `nil`。
    private static func keyOfAssignment(in line: String) -> Key? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        return Key(rawValue: name)
    }

    /// シングルクォートで囲む。dotenv はこの形なら変数展開もエスケープ解釈もしないので、
    /// トークンにどんな記号が混じっても読み込み側で化けない。
    private static func render(_ key: Key, _ value: String) -> String {
        "\(key.rawValue)='\(value)'"
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, value.last == first else { return value }
        guard first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - ファイル

    private func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// テンポラリに書いてから rename で差し替える。途中で落ちても壊れた `.env` は残らない。
    ///
    /// パーミッションはファイル 0600・ディレクトリ 0700。rename は元のモードを引き継ぐので、
    /// テンポラリを 0600 で作れば差し替え後も 0600 になる。
    private func write(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw EnvFileError(message: "設定を書き出せなかった")
        }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard
            fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw EnvFileError(message: "一時ファイルを作れなかった: \(temporary.path)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw EnvFileError(message: "\(url.path) に書き込めなかった (errno \(code))")
        }
    }
}
