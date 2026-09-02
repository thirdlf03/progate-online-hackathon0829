import Foundation
import Testing

@testable import MihariCore

/// 髪色 × 服の着せ替えを検証する。
///
/// 組み合わせが選べるかは「`variants` に記載があり、かつシートが実在する」で決まるので、
/// 実在の側は一時ディレクトリにダミーのシートを置いて確かめる。
@Suite("ペットの着せ替え")
struct PetWardrobeTests {

    /// テスト用の `wardrobe` 付き `pet.json`。`purple` × `sailor` だけ `variants` に無い。
    private static let manifestJSON = """
        {
          "id": "dressup",
          "displayName": "着せ替え",
          "description": "テスト用",
          "spritesheetPath": "spritesheet.webp",
          "wardrobe": {
            "hairColors": [
              { "id": "black", "label": "黒" },
              { "id": "purple", "label": "紫" }
            ],
            "outfits": [
              { "id": "gothic", "label": "ゴスロリ" },
              { "id": "sailor", "label": "セーラー服" }
            ],
            "default": { "hairColor": "black", "outfit": "gothic" },
            "variants": [
              { "hairColor": "black", "outfit": "gothic", "spritesheetPath": "spritesheet.webp" },
              {
                "hairColor": "black",
                "outfit": "sailor",
                "spritesheetPath": "variants/black-sailor/spritesheet.webp",
                "cutinDirectory": "variants/black-sailor/cutin"
              },
              {
                "hairColor": "purple",
                "outfit": "gothic",
                "spritesheetPath": "variants/purple-gothic/spritesheet.webp"
              }
            ]
          }
        }
        """

    private static func decode(_ json: String) throws -> PetManifest {
        try JSONDecoder().decode(PetManifest.self, from: Data(json.utf8))
    }

    /// 一時ディレクトリに置いたペット。`files` に書いた相対パスへ空のファイルを作る。
    private static func makePet(files: [String]) throws -> PetDefinition {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mihari-wardrobe-\(UUID().uuidString)")
        for path in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        return PetDefinition(
            manifest: try decode(manifestJSON),
            directoryURL: directory,
            speechURL: nil
        )
    }

    private static func remove(_ pet: PetDefinition) {
        try? FileManager.default.removeItem(at: pet.directoryURL)
    }

    @Test("wardrobe を書いた pet.json を読める")
    func decodesWardrobe() throws {
        let wardrobe = try #require(Self.decode(Self.manifestJSON).wardrobe)

        #expect(wardrobe.hairColors.map(\.id) == ["black", "purple"])
        #expect(wardrobe.hairColors.map(\.label) == ["黒", "紫"])
        #expect(wardrobe.outfits.map(\.id) == ["gothic", "sailor"])
        #expect(wardrobe.defaultSelection == WardrobeSelection(hairColor: "black", outfit: "gothic"))
        #expect(wardrobe.variants.count == 3)
        #expect(wardrobe.variants[0].spritesheetPath == "spritesheet.webp")
        #expect(wardrobe.variants[0].cutinDirectory == nil)
        #expect(wardrobe.variants[1].cutinDirectory == "variants/black-sailor/cutin")
    }

    @Test("wardrobe を書いていない pet.json は従来どおり読め、バリアント無しになる")
    func decodesManifestWithoutWardrobe() throws {
        let manifest = try Self.decode(
            """
            {
              "id": "plain",
              "displayName": "素のペット",
              "description": "テスト用",
              "spritesheetPath": "spritesheet.webp"
            }
            """
        )

        #expect(manifest.id == "plain")
        #expect(manifest.spritesheetPath == "spritesheet.webp")
        #expect(manifest.wardrobe == nil)

        let pet = PetDefinition(
            manifest: manifest,
            directoryURL: URL(fileURLWithPath: "/var/empty/mihari-plain"),
            speechURL: nil
        )
        #expect(pet.wardrobe == nil)
        #expect(pet.isAvailable(WardrobeSelection(hairColor: "black", outfit: "gothic")) == false)
        // 着せ替えを持たないペットは、どの選択を渡してもトップレベルのシートを使う。
        #expect(
            pet.spritesheetURL(for: WardrobeSelection(hairColor: "black", outfit: "gothic"))
                == pet.spritesheetURL
        )
    }

    @Test("記載があってシートも実在する組み合わせだけ選べる")
    func availabilityNeedsBothTheEntryAndTheFile() throws {
        let pet = try Self.makePet(files: [
            "spritesheet.webp",
            "variants/purple-gothic/spritesheet.webp",
        ])
        defer { Self.remove(pet) }

        // 記載があり、ファイルも実在する。
        #expect(pet.isAvailable(WardrobeSelection(hairColor: "purple", outfit: "gothic")))
        // 記載はあるが、ファイルを置いていない。
        #expect(pet.isAvailable(WardrobeSelection(hairColor: "black", outfit: "sailor")) == false)
        // variants に記載が無い。
        #expect(pet.isAvailable(WardrobeSelection(hairColor: "purple", outfit: "sailor")) == false)
    }

    @Test("選べる組み合わせはそのシートを、選べない組み合わせはトップレベルのシートを指す")
    func spritesheetFallsBackToTheTopLevelSheet() throws {
        let pet = try Self.makePet(files: [
            "spritesheet.webp",
            "variants/purple-gothic/spritesheet.webp",
        ])
        defer { Self.remove(pet) }

        #expect(
            pet.spritesheetURL(for: WardrobeSelection(hairColor: "purple", outfit: "gothic"))
                == pet.directoryURL.appendingPathComponent("variants/purple-gothic/spritesheet.webp")
        )
        // ファイルが欠けている組み合わせも、記載が無い組み合わせも既定の 1 枚に落とす。
        #expect(
            pet.spritesheetURL(for: WardrobeSelection(hairColor: "black", outfit: "sailor"))
                == pet.spritesheetURL
        )
        #expect(
            pet.spritesheetURL(for: WardrobeSelection(hairColor: "purple", outfit: "sailor"))
                == pet.spritesheetURL
        )
        #expect(pet.spritesheetURL(for: nil) == pet.spritesheetURL)
    }

    @Test("cutinDirectory があればそちらを優先し、無ければ cutin/ に落ちる")
    func cutInDirectoryTakesPriorityOverTheDefault() throws {
        let pet = try Self.makePet(files: [
            "spritesheet.webp",
            "variants/black-sailor/spritesheet.webp",
            "cutin/reach.png",
            "cutin/touched.png",
            "variants/black-sailor/cutin/reach.png",
        ])
        defer { Self.remove(pet) }

        let sailor = WardrobeSelection(hairColor: "black", outfit: "sailor")
        // cutinDirectory に置いてある絵はそちらから取る。
        #expect(
            pet.cutInImageURL(.reach, selection: sailor)
                == pet.directoryURL.appendingPathComponent("variants/black-sailor/cutin/reach.png")
        )
        // cutinDirectory に無い絵は従来の cutin/ に落ちる。
        #expect(
            pet.cutInImageURL(.touched, selection: sailor)
                == pet.directoryURL.appendingPathComponent("cutin/touched.png")
        )
        // どちらにも無ければ nil。
        #expect(pet.cutInImageURL(.failed, selection: sailor) == nil)
        // cutinDirectory を書いていない組み合わせと、選択を渡さないときは cutin/ だけを見る。
        let gothic = WardrobeSelection(hairColor: "black", outfit: "gothic")
        #expect(
            pet.cutInImageURL(.reach, selection: gothic)
                == pet.directoryURL.appendingPathComponent("cutin/reach.png")
        )
        #expect(
            pet.cutInImageURL(.reach) == pet.directoryURL.appendingPathComponent("cutin/reach.png")
        )
    }
}

/// 着せ替えの選択が `PetController` にどう出るかを検証する。
@Suite("ペットの着せ替えの選択")
@MainActor
struct PetControllerWardrobeTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が選択を共有しないようにする。
    private func makeDefaults(_ label: String) -> UserDefaults {
        let suiteName = "mihari.test.wardrobe.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("保存が無ければ pet.json の default になる")
    func startsFromTheDefaultSelection() throws {
        let controller = PetController(defaults: makeDefaults("default"))
        let pet = try #require(controller.currentPet)
        let wardrobe = try #require(pet.wardrobe)

        #expect(controller.wardrobeSelection == wardrobe.defaultSelection)
    }

    @Test("保存された組み合わせが選べないなら default に戻す")
    func fallsBackToTheDefaultWhenTheStoredSelectionIsUnavailable() throws {
        let defaults = makeDefaults("unavailable")
        // 絵を用意しようのない髪色。あとから画像が増えても選べないままになる。
        defaults.set("no-such-color", forKey: "pet.wardrobe.mauve.hairColor")
        defaults.set("gothic", forKey: "pet.wardrobe.mauve.outfit")

        let controller = PetController(defaults: defaults)
        let pet = try #require(controller.currentPet)
        let wardrobe = try #require(pet.wardrobe)

        #expect(controller.wardrobeSelection == wardrobe.defaultSelection)
    }

    @Test("選べる髪色 / 服だけが available に出る")
    func availableOptionsAreTheOnesWithASheet() throws {
        let controller = PetController(defaults: makeDefaults("available"))
        let pet = try #require(controller.currentPet)
        let selection = try #require(controller.wardrobeSelection)

        #expect(
            controller.availableHairColors.map(\.id)
                == (pet.wardrobe?.hairColors ?? []).map(\.id).filter {
                    pet.isAvailable(WardrobeSelection(hairColor: $0, outfit: selection.outfit))
                }
        )
        #expect(
            controller.availableOutfits.map(\.id)
                == (pet.wardrobe?.outfits ?? []).map(\.id).filter {
                    pet.isAvailable(WardrobeSelection(hairColor: selection.hairColor, outfit: $0))
                }
        )
        // 既定の組み合わせは必ず選べるので、いま選んでいるものは必ず候補に入る。
        #expect(controller.availableHairColors.contains { $0.id == selection.hairColor })
        #expect(controller.availableOutfits.contains { $0.id == selection.outfit })
    }

    @Test("選べない組み合わせに変えようとしたら default に戻す")
    func settingAnUnavailableOptionFallsBackToTheDefault() throws {
        let controller = PetController(defaults: makeDefaults("set"))
        let pet = try #require(controller.currentPet)
        let wardrobe = try #require(pet.wardrobe)

        controller.setHairColor("no-such-color")

        #expect(controller.wardrobeSelection == wardrobe.defaultSelection)
    }

    @Test("メニューの「髪色」「服」は「サイズ」の直後に並び、選んでいるものにチェックが付く")
    func menuShowsTheWardrobeSubmenus() throws {
        let controller = PetController(defaults: makeDefaults("menu"))
        let presenter = LivePetPresenter(controller: controller)
        let entries = PetMenuEntries.make(actions: StubPetMenuActions(), presenter: presenter)
        let pet = try #require(controller.currentPet)
        let wardrobe = try #require(pet.wardrobe)
        let selection = try #require(controller.wardrobeSelection)

        let titles = entries.map { entry -> String in
            switch entry {
            case .item(let title, _, _, _): return title
            case .submenu(let title, _): return title
            case .separator: return "―"
            }
        }
        let sizeIndex = try #require(titles.firstIndex(of: "サイズ"))
        #expect(titles[sizeIndex + 1] == "髪色")
        #expect(titles[sizeIndex + 2] == "服")

        guard case .submenu(_, let hairEntries) = entries[sizeIndex + 1],
            case .submenu(_, let outfitEntries) = entries[sizeIndex + 2]
        else {
            Issue.record("髪色 / 服 がサブメニューでない")
            return
        }

        // 一覧は wardrobe に書いた順のまま全部出す。
        #expect(hairEntries.count == wardrobe.hairColors.count)
        #expect(outfitEntries.count == wardrobe.outfits.count)

        for (entry, option) in zip(hairEntries, wardrobe.hairColors) {
            guard case .item(let title, let isChecked, let isEnabled, _) = entry else {
                Issue.record("髪色の項目が item でない")
                return
            }
            #expect(title == option.label)
            #expect(isChecked == (option.id == selection.hairColor))
            // 絵が無い組み合わせは灰色にする。
            #expect(isEnabled == controller.availableHairColors.contains { $0.id == option.id })
        }
        for (entry, option) in zip(outfitEntries, wardrobe.outfits) {
            guard case .item(let title, let isChecked, let isEnabled, _) = entry else {
                Issue.record("服の項目が item でない")
                return
            }
            #expect(title == option.label)
            #expect(isChecked == (option.id == selection.outfit))
            #expect(isEnabled == controller.availableOutfits.contains { $0.id == option.id })
        }
    }
}
