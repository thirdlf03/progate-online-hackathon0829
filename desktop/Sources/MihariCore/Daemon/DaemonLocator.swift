import Foundation

/// デーモンをどこから動かすか。
///
/// 配布した `.app` には PyInstaller で固めた `device-bridge` を同梱してある。
/// この形なら uv も Python も要らない。リポジトリで開発している間は、
/// 手元の `bridge/` を `uv run` 越しに動かす。
public enum DaemonSource: Equatable, Sendable {

    /// `.app` に同梱した実行ファイル一式が入っているディレクトリ。
    /// `device-bridge` と `pymobiledevice3` の 2 本が並んでいる。
    case bundled(directory: String)

    /// リポジトリの `bridge/` を `uv run` で動かす(開発時)。
    case source(bridgeDirectory: String, uvPath: String)
}

/// tunneld の登録/解除スクリプトの置き場と、そこへ渡す `pymobiledevice3`。
///
/// tunneld は root でしか起動できないため、アプリからは直接触れず、
/// スクリプトを管理者パスワードダイアログ越しに 1 回だけ実行する。
public struct TunneldScriptLocation: Equatable, Sendable {

    /// `install_tunneld_daemon.sh` などが入っているディレクトリ。
    public let scriptsDirectory: String

    /// スクリプトに `PYMOBILEDEVICE3_PATH` として渡すバイナリ。
    /// ソース経路なら `nil` で、スクリプトが自分で `uv` を探す。
    public let pymobiledevice3Path: String?

    public init(scriptsDirectory: String, pymobiledevice3Path: String?) {
        self.scriptsDirectory = scriptsDirectory
        self.pymobiledevice3Path = pymobiledevice3Path
    }
}

/// デーモンの実体(同梱バイナリ、または `uv` と `bridge/`)の場所を決める。
///
/// 環境変数での上書きを許すのは、リポジトリの外から `.app` を動かす場合に
/// パスの推測が当てにならないため。
public struct DaemonLocator: Sendable {

    public typealias FileCheck = @Sendable (String) -> Bool

    /// `.app` の `Contents/Resources` 直下に置く同梱物のディレクトリ名。
    /// `desktop/build.sh` の `BUNDLE_BRIDGE=1` がここへコピーする。
    public static let bundledDirectoryName = "device-bridge"

    private let environment: [String: String]
    private let isExecutable: FileCheck
    private let directoryExists: FileCheck
    private let resourcesPath: String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping FileCheck = { FileManager.default.isExecutableFile(atPath: $0) },
        directoryExists: @escaping FileCheck = { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        },
        resourcesPath: String? = Bundle.main.resourcePath
    ) {
        self.environment = environment
        self.isExecutable = isExecutable
        self.directoryExists = directoryExists
        self.resourcesPath = resourcesPath
    }

    /// どの形でデーモンを動かすかを決める。
    ///
    /// 優先順は次のとおり。
    ///
    /// 1. `DEVICE_BRIDGE_DIR` があれば、そこを `uv` で動かす。手元の `bridge/` を
    ///    差し込むための明示指定なので、同梱バイナリより優先する
    /// 2. `.app` に同梱した `device-bridge` があればそれ(uv も Python も要らない)
    /// 3. ソース位置から逆算した `<root>/bridge` を `uv` で動かす
    public func resolve(home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> DaemonSource {
        if environment["DEVICE_BRIDGE_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) == nil,
            let directory = bundledDirectory()
        {
            return .bundled(directory: directory)
        }
        return .source(bridgeDirectory: try bridgeDirectory(), uvPath: try uvPath(home: home))
    }

    /// `.app` に同梱した実行ファイル一式のディレクトリ。同梱していなければ `nil`。
    public func bundledDirectory() -> String? {
        guard let resourcesPath, !resourcesPath.isEmpty else { return nil }
        let directory = resourcesPath + "/" + Self.bundledDirectoryName
        guard isExecutable(directory + "/device-bridge") else { return nil }
        return directory
    }

    /// 同梱した `pymobiledevice3`。tunneld の登録スクリプトに渡す。無ければ `nil`。
    public func bundledPymobiledevice3Path() -> String? {
        guard let directory = bundledDirectory() else { return nil }
        let path = directory + "/pymobiledevice3"
        return isExecutable(path) ? path : nil
    }

    /// tunneld のスクリプトをどこから実行するか。
    ///
    /// 優先順は `resolve()` と揃える(`DEVICE_BRIDGE_DIR` → 同梱 → リポジトリ)。
    /// 同梱スクリプトを使うときは、同じ同梱物の `pymobiledevice3` を渡すので
    /// ユーザーの Mac に uv も Python も要らない。
    public func tunneldScripts() throws -> TunneldScriptLocation {
        if environment["DEVICE_BRIDGE_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) == nil,
            let directory = bundledDirectory(),
            isExecutable(directory + "/scripts/install_tunneld_daemon.sh")
        {
            return TunneldScriptLocation(
                scriptsDirectory: directory + "/scripts",
                pymobiledevice3Path: bundledPymobiledevice3Path()
            )
        }
        return TunneldScriptLocation(
            scriptsDirectory: try bridgeDirectory() + "/scripts",
            pymobiledevice3Path: nil
        )
    }

    /// `uv` の探索順。`UV_PATH` があればそれだけを見る。
    public static func uvCandidates(home: String) -> [String] {
        [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
    }

    public func uvPath(home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> String {
        if let path = environment["UV_PATH"], !path.isEmpty {
            guard isExecutable(path) else { throw DaemonError.uvNotFound }
            return path
        }
        for candidate in Self.uvCandidates(home: home) where isExecutable(candidate) {
            return candidate
        }
        throw DaemonError.uvNotFound
    }

    /// `bridge/` の場所。`DEVICE_BRIDGE_DIR` があればそれを優先する。
    public func bridgeDirectory(defaultPath: String = Self.repositoryBridgePath) throws -> String {
        let path = environment["DEVICE_BRIDGE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
        guard directoryExists(path) else {
            throw DaemonError.bridgeDirectoryNotFound(path: path)
        }
        return path
    }

    /// ソース位置からリポジトリルートを逆算した `bridge/`。
    /// desktop/Sources/MihariCore/Daemon/DaemonLocator.swift → <root>/bridge
    public static var repositoryBridgePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Daemon
            .deletingLastPathComponent()  // MihariCore
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // desktop
            .deletingLastPathComponent()  // <root>
            .appendingPathComponent("bridge")
            .path
    }
}
