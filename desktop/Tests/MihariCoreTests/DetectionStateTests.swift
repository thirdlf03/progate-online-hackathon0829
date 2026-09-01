import Foundation
import Testing

@testable import MihariCore

/// 証拠の取り先が、セーフティートグルに従うかを確かめる。
@Suite("証拠の取り先とセーフティートグル")
struct DetectionStateTests {

    private func gate(_ enabled: Set<SafetyFeature>) -> SafetyGate {
        SafetyGate(isEnabled: { enabled.contains($0) })
    }

    @Test("iPhone を触っているときは、画面を撮るトグルが ON なら撮る")
    func activePhoneUsesScreenshotWhenAllowed() {
        #expect(
            EvidenceKind.forEvidence(iphone: .active, gate: gate([.iphoneScreenshot]))
                == .iphoneScreenshot
        )
    }

    @Test("iPhone を触っているのに画面を撮る設定が無ければ、Mac のカメラにも倒さず何も撮らない")
    func activePhoneWithoutTheToggleCapturesNothing() {
        // 「Mac は放置して iPhone を触っている」のに Mac のカメラで撮るのは合意から外れる。
        #expect(EvidenceKind.forEvidence(iphone: .active, gate: gate([.iphonePresence])) == .none)
        #expect(EvidenceKind.forEvidence(iphone: .active, gate: .denyAll) == .none)
    }

    @Test("iPhone が置かれたままなら、カメラのトグルが ON のときだけ顔を撮る")
    func idlePhoneUsesTheCameraWhenAllowed() {
        #expect(EvidenceKind.forEvidence(iphone: .idle, gate: gate([.macCamera])) == .macCamera)
        #expect(EvidenceKind.forEvidence(iphone: .idle, gate: gate([.discordExposure])) == .none)
    }

    @Test("iPhone から返事が無くても、カメラのトグルが OFF なら何も撮らない")
    func unreachablePhoneWithoutTheToggleCapturesNothing() {
        #expect(EvidenceKind.forEvidence(iphone: .unreachable, gate: gate([.macCamera])) == .macCamera)
        #expect(EvidenceKind.forEvidence(iphone: .unreachable, gate: gate([.discordExposure])) == .none)
    }

    @Test("ゲート無し版は全機能 ON と同じ振る舞い")
    func oneArgumentVersionTreatsEverythingAsAllowed() {
        #expect(EvidenceKind.forEvidence(iphone: .active) == .iphoneScreenshot)
        #expect(EvidenceKind.forEvidence(iphone: .idle) == .macCamera)
        #expect(EvidenceKind.forEvidence(iphone: .unreachable) == .macCamera)
    }
}
