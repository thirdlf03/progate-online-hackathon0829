import Foundation

/// `pet.json` の `wardrobe`。髪色 × 服の着せ替えをまとめたもの。
///
/// 書いていないペットは従来どおり `spritesheetPath` の 1 枚だけで動く。
public struct PetWardrobe: Codable, Hashable, Sendable {
    /// 髪色の選択肢。メニューにはこの順で並べる。
    public let hairColors: [PetWardrobeOption]
    /// 服の選択肢。メニューにはこの順で並べる。
    public let outfits: [PetWardrobeOption]
    /// 既定の組み合わせ。保存された選択が使えないときはここへ戻す。
    public let defaultSelection: WardrobeSelection
    /// 絵を用意した組み合わせ。ここに書いていない組み合わせは選べない。
    public let variants: [PetWardrobeVariant]

    private enum CodingKeys: String, CodingKey {
        case hairColors
        case outfits
        // `default` は Swift の予約語なので、プロパティ名だけ読み替える。
        case defaultSelection = "default"
        case variants
    }
}

/// 髪色 / 服 1 つ分の選択肢。
public struct PetWardrobeOption: Codable, Hashable, Sendable {
    /// 保存と組み合わせの判定に使う識別子。
    public let id: String
    /// メニューに出す表示名。
    public let label: String
}

/// 絵を用意した組み合わせ 1 つ分。
public struct PetWardrobeVariant: Codable, Hashable, Sendable {
    /// 髪色の識別子。
    public let hairColor: String
    /// 服の識別子。
    public let outfit: String
    /// `pet.json` と同じディレクトリからの相対パスで書かれたスプライトシートの位置。
    public let spritesheetPath: String
    /// カットイン画像を置いたディレクトリ(同じく相対パス)。書いていなければ `cutin/` を使う。
    public let cutinDirectory: String?

    /// この組み合わせを表す選択。
    var selection: WardrobeSelection {
        WardrobeSelection(hairColor: hairColor, outfit: outfit)
    }
}

/// いま選んでいる髪色と服。
public struct WardrobeSelection: Codable, Hashable, Sendable {
    /// 髪色の識別子。
    public let hairColor: String
    /// 服の識別子。
    public let outfit: String

    public init(hairColor: String, outfit: String) {
        self.hairColor = hairColor
        self.outfit = outfit
    }
}

extension PetDefinition {
    /// 着せ替えの定義。`pet.json` に `wardrobe` が無ければ nil。
    public var wardrobe: PetWardrobe? { manifest.wardrobe }

    /// その組み合わせを選べるか。`variants` に記載があり、かつシートが実在するときだけ true。
    ///
    /// 記載が無いのとファイルが欠けているのは、どちらも「絵が無い」として同じに扱う。
    public func isAvailable(_ selection: WardrobeSelection) -> Bool {
        guard let url = variantSpritesheetURL(for: selection) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 組み合わせに対応するスプライトシート。選べない組み合わせのときは
    /// トップレベルの `spritesheetPath` に落とす。
    public func spritesheetURL(for selection: WardrobeSelection?) -> URL {
        guard let selection, isAvailable(selection) else { return spritesheetURL }
        return variantSpritesheetURL(for: selection) ?? spritesheetURL
    }

    /// 組み合わせに対応するバリアント。`variants` に記載が無ければ nil。
    func wardrobeVariant(for selection: WardrobeSelection) -> PetWardrobeVariant? {
        manifest.wardrobe?.variants.first { $0.selection == selection }
    }

    /// `variants` に書かれたスプライトシートの位置。ファイルが実在するかは見ない。
    private func variantSpritesheetURL(for selection: WardrobeSelection) -> URL? {
        guard let variant = wardrobeVariant(for: selection) else { return nil }
        return directoryURL.appendingPathComponent(variant.spritesheetPath)
    }
}
