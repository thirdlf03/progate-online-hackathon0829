import Foundation
import Testing

@testable import MihariCore

/// セーフティー設定(値の持ち方・normalized・Codable の互換・モード表示)を検証する。
@Suite("セーフティー設定")
struct SafetySettingsTests {

    @Test("既定値は全 OFF・変更可能・予約なし(セーフティーモード)")
    func defaultsToSafetyMode() {
        let settings = SafetySettings.default

        #expect(settings.enabled.isEmpty)
        #expect(settings.canChangeLater)
        #expect(settings.pendingChange == nil)
        #expect(settings.lastEscapeAt == nil)
        #expect(settings.mode == .safety)
        #expect(settings.mode.label == "セーフティー")
    }

    @Test("isEnabled は ON の機能だけ true を返す")
    func isEnabledReflectsEnabledSet() {
        var settings = SafetySettings()
        settings.enabled = [.macCamera]

        #expect(settings.isEnabled(.macCamera))
        #expect(!settings.isEnabled(.discordExposure))
    }

    @Test("normalized は依存を満たさない ON を落とす")
    func normalizedDropsFeaturesWithoutDependency() {
        // iphoneScreenshot は iphonePresence が前提。前提が無いのに ON はあり得ない。
        var settings = SafetySettings()
        settings.enabled = [.iphoneScreenshot]

        #expect(settings.normalized().enabled.isEmpty)
    }

    @Test("normalized は依存を満たしている ON は残す")
    func normalizedKeepsValidFeatures() {
        var settings = SafetySettings()
        settings.enabled = [.iphonePresence, .iphoneScreenshot, .macCamera]

        #expect(settings.normalized().enabled == [.iphonePresence, .iphoneScreenshot, .macCamera])
    }

    @Test("Codable: 一式を丸ごと往復できる")
    func codableRoundTrip() throws {
        var settings = SafetySettings()
        settings.enabled = [.iphonePresence, .iphoneScreenshot, .quitLock]
        settings.canChangeLater = false
        settings.pendingChange = SafetyPendingChange(
            disabling: [.macCamera],
            restoresChangeability: true,
            effectiveAt: Date(timeIntervalSince1970: 1_000_000)
        )
        settings.lastEscapeAt = Date(timeIntervalSince1970: 2_000_000)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SafetySettings.self, from: data)

        #expect(decoded == settings)
    }

    @Test("Codable: 欠けたキーは既定値で埋まる")
    func codableMissingKeysFallBackToDefaults() throws {
        // 将来のバージョンがキーを足しても、古い保存値が読めなくならないことの確認。
        let empty = try JSONDecoder().decode(SafetySettings.self, from: Data("{}".utf8))
        #expect(empty == .default)

        let partial = try JSONDecoder().decode(
            SafetySettings.self,
            from: Data(#"{"enabled": ["macCamera"]}"#.utf8)
        )
        #expect(partial.enabled == [.macCamera])
        #expect(partial.canChangeLater)  // 欠けたキーの既定値
        #expect(partial.pendingChange == nil)
        #expect(partial.lastEscapeAt == nil)
    }

    @Test("モードは 3 分岐し、ラベルは本数と総数を出す")
    func modeDividesIntoThree() {
        #expect(SafetySettings.default.mode == .safety)

        var custom = SafetySettings()
        custom.enabled = [.macCamera, .iphonePresence, .discordExposure]
        #expect(custom.mode == .custom(enabledCount: 3))
        #expect(custom.mode.label == "カスタム(3/\(SafetyFeature.total))")

        var unlimited = SafetySettings()
        unlimited.enabled = Set(SafetyFeature.allCases)
        #expect(unlimited.mode == .unlimited)
        #expect(unlimited.mode.label == "無制限")
    }

    @Test("SafetyFeature のタイトル・説明・送信先・権限・従属が揃っている")
    func featureMetadataIsComplete() {
        #expect(SafetyFeature.allCases.count == SafetyFeature.total)

        // 従属(requires)の関係だけは仕様で固定されている。
        #expect(SafetyFeature.iphoneScreenshot.requires == .iphonePresence)
        #expect(SafetyFeature.iphonePresence.requires == nil)
        #expect(SafetyFeature.iphonePresence.dependents == [.iphoneScreenshot])
        #expect(SafetyFeature.iphoneScreenshot.dependents.isEmpty)

        // 説明文は空にできない(設定画面に出すため)。
        for feature in SafetyFeature.allCases {
            #expect(!feature.title.isEmpty)
            #expect(!feature.summary.isEmpty)
            #expect(!feature.destination.isEmpty)
            #expect(!feature.permissionNote.isEmpty)
        }

        // デーモンへ渡す 3 本だけが isForwardedToDaemon。
        let forwarded: Set<SafetyFeature> = [
            .iphonePresence, .iphoneScreenshot, .discordExposure,
        ]
        for feature in SafetyFeature.allCases {
            #expect(feature.isForwardedToDaemon == forwarded.contains(feature))
        }
    }
}
