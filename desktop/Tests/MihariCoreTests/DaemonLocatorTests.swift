import Testing

@testable import MihariCore

@Suite("uv と bridge/ の場所の解決")
struct DaemonLocatorTests {

    @Test("UV_PATH があればそれを使う")
    func honorsUVPath() throws {
        let locator = DaemonLocator(
            environment: ["UV_PATH": "/custom/uv"],
            isExecutable: { $0 == "/custom/uv" },
            directoryExists: { _ in true }
        )
        #expect(try locator.uvPath(home: "/Users/x") == "/custom/uv")
    }

    @Test("UV_PATH が実行できなければ、他を探さずに失敗する")
    func brokenUVPathFails() {
        // 指定されたのに動かない場合、黙って別の uv を使うと原因が分からなくなる。
        let locator = DaemonLocator(
            environment: ["UV_PATH": "/custom/uv"],
            isExecutable: { $0 == "/opt/homebrew/bin/uv" },
            directoryExists: { _ in true }
        )
        #expect(throws: DaemonError.uvNotFound) { try locator.uvPath(home: "/Users/x") }
    }

    @Test("UV_PATH がなければ既定の候補を順に探す")
    func fallsBackToCandidates() throws {
        let locator = DaemonLocator(
            environment: [:],
            isExecutable: { $0 == "/opt/homebrew/bin/uv" },
            directoryExists: { _ in true }
        )
        #expect(try locator.uvPath(home: "/Users/x") == "/opt/homebrew/bin/uv")
    }

    @Test("候補の探索順はホーム配下 → homebrew → /usr/local")
    func candidateOrder() {
        #expect(
            DaemonLocator.uvCandidates(home: "/Users/x") == [
                "/Users/x/.local/bin/uv",
                "/opt/homebrew/bin/uv",
                "/usr/local/bin/uv",
            ]
        )
    }

    @Test("どこにも uv がなければ失敗する")
    func missingUVFails() {
        let locator = DaemonLocator(environment: [:], isExecutable: { _ in false }, directoryExists: { _ in true })
        #expect(throws: DaemonError.uvNotFound) { try locator.uvPath(home: "/Users/x") }
    }

    @Test("DEVICE_BRIDGE_DIR があればそれを使う")
    func honorsBridgeDir() throws {
        let locator = DaemonLocator(
            environment: ["DEVICE_BRIDGE_DIR": "/somewhere/bridge"],
            isExecutable: { _ in true },
            directoryExists: { $0 == "/somewhere/bridge" }
        )
        #expect(try locator.bridgeDirectory(defaultPath: "/default/bridge") == "/somewhere/bridge")
    }

    @Test("bridge/ が存在しなければ、探したパスを添えて失敗する")
    func missingBridgeDirFails() {
        let locator = DaemonLocator(environment: [:], isExecutable: { _ in true }, directoryExists: { _ in false })
        #expect(throws: DaemonError.bridgeDirectoryNotFound(path: "/default/bridge")) {
            try locator.bridgeDirectory(defaultPath: "/default/bridge")
        }
    }

    @Test("リポジトリから逆算した既定のパスは bridge で終わる")
    func repositoryPathEndsWithBridge() {
        #expect(DaemonLocator.repositoryBridgePath.hasSuffix("/bridge"))
    }
}

@Suite("同梱バイナリと uv のどちらで動かすかの決定")
struct DaemonSourceResolutionTests {

    /// `.app` に同梱されている状況を作る。Resources/device-bridge に 2 本並んでいる。
    private func bundledLocator(
        environment: [String: String] = [:],
        executables: Set<String> = [
            "/App.app/Contents/Resources/device-bridge/device-bridge",
            "/App.app/Contents/Resources/device-bridge/pymobiledevice3",
        ]
    ) -> DaemonLocator {
        DaemonLocator(
            environment: environment,
            isExecutable: { executables.contains($0) },
            directoryExists: { _ in true },
            resourcesPath: "/App.app/Contents/Resources"
        )
    }

    @Test("同梱バイナリがあればそれを使う(uv は要らない)")
    func prefersBundledBinary() throws {
        let locator = bundledLocator()
        #expect(
            try locator.resolve(home: "/Users/x")
                == .bundled(directory: "/App.app/Contents/Resources/device-bridge")
        )
    }

    @Test("DEVICE_BRIDGE_DIR があれば同梱バイナリより優先する")
    func explicitBridgeDirWins() throws {
        // 開発中に手元の bridge/ を差し込むための明示指定なので、同梱物に勝つ。
        let locator = bundledLocator(
            environment: ["DEVICE_BRIDGE_DIR": "/repo/bridge", "UV_PATH": "/custom/uv"],
            executables: [
                "/App.app/Contents/Resources/device-bridge/device-bridge",
                "/App.app/Contents/Resources/device-bridge/pymobiledevice3",
                "/custom/uv",
            ]
        )
        #expect(
            try locator.resolve(home: "/Users/x")
                == .source(bridgeDirectory: "/repo/bridge", uvPath: "/custom/uv")
        )
    }

    @Test("同梱されていなければ uv と bridge/ を探す")
    func fallsBackToSource() throws {
        let locator = DaemonLocator(
            environment: [:],
            isExecutable: { $0 == "/opt/homebrew/bin/uv" },
            directoryExists: { _ in true },
            resourcesPath: "/App.app/Contents/Resources"
        )
        #expect(
            try locator.resolve(home: "/Users/x")
                == .source(bridgeDirectory: DaemonLocator.repositoryBridgePath, uvPath: "/opt/homebrew/bin/uv")
        )
    }

    @Test("同梱もされておらず uv も無ければ失敗する")
    func missingBothFails() {
        let locator = DaemonLocator(
            environment: [:],
            isExecutable: { _ in false },
            directoryExists: { _ in true },
            resourcesPath: "/App.app/Contents/Resources"
        )
        #expect(throws: DaemonError.uvNotFound) { try locator.resolve(home: "/Users/x") }
    }

    @Test("同梱した pymobiledevice3 のパスを返す")
    func findsBundledPymobiledevice3() {
        let locator = bundledLocator()
        #expect(
            locator.bundledPymobiledevice3Path()
                == "/App.app/Contents/Resources/device-bridge/pymobiledevice3"
        )
    }

    @Test("device-bridge だけあって pymobiledevice3 が無ければ nil")
    func missingBundledPymobiledevice3IsNil() {
        let locator = bundledLocator(
            executables: ["/App.app/Contents/Resources/device-bridge/device-bridge"]
        )
        #expect(locator.bundledPymobiledevice3Path() == nil)
    }

    @Test("Resources が分からなければ同梱物は無いものとして扱う")
    func noResourcesPathMeansNoBundle() {
        let locator = DaemonLocator(
            environment: [:],
            isExecutable: { _ in true },
            directoryExists: { _ in true },
            resourcesPath: nil
        )
        #expect(locator.bundledDirectory() == nil)
        #expect(locator.bundledPymobiledevice3Path() == nil)
    }
}
