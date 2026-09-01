import Foundation
import Testing

@testable import MihariCore

/// 執行猶予脱出(escape)の純粋ロジックを検証する。
@Suite("執行猶予脱出のポリシー")
struct EscapePolicyTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("選択肢は 15 分刻みで 15 分〜8 時間")
    func returnDelayChoicesAre15MinSteps() {
        let choices = EscapePolicy.returnDelayChoices(now: now, unlockAt: nil)
        // 8 時間 = 15 分刻みの 32 段。
        let expected: [TimeInterval] = (1...32).map { TimeInterval($0) * 15 * 60 }

        #expect(choices == expected)
        #expect(choices.first == EscapePolicy.minReturnDelay)
        #expect(choices.last == Double(EscapePolicy.maxReturnDelay))
        #expect(choices.count == Int(EscapePolicy.maxReturnDelay / EscapePolicy.returnDelayStep))
    }

    @Test("unlockAt があると、それを超える選択肢は落とす")
    func returnDelayChoicesStopAtUnlockAt() {
        // ロックの残りが 1 時間 15 分。ちょうどの選択肢までは残り、次の 1 時間 30 分は落ちる。
        let choices = EscapePolicy.returnDelayChoices(
            now: now,
            unlockAt: now.addingTimeInterval(75 * 60)
        )
        let expected: [TimeInterval] = [15, 30, 45, 60, 75].map { $0 * 60 }

        #expect(choices == expected)
    }

    @Test("unlockAt が 8 時間より遠いときは 8 時間が上限になる")
    func returnDelayChoicesCapAtEightHoursEvenWhenUnlockAtIsFar() {
        let choices = EscapePolicy.returnDelayChoices(
            now: now,
            unlockAt: now.addingTimeInterval(24 * 60 * 60)
        )

        #expect(choices.last == EscapePolicy.maxReturnDelay)
    }

    @Test("unlockAt まで 15 分未満なら選択肢は無い")
    func returnDelayChoicesAreEmptyWhenUnlockAtIsTooNear() {
        let choices = EscapePolicy.returnDelayChoices(
            now: now,
            unlockAt: now.addingTimeInterval(10 * 60)
        )

        #expect(choices.isEmpty)
    }

    @Test("used していなければ冷却は無い")
    func noCooldownWithoutLastEscape() {
        #expect(EscapePolicy.cooldownRemaining(lastEscapeAt: nil, now: now) == nil)
    }

    @Test("脱出から 24 時間以内は残り時間を返す")
    func cooldownRemainingCountsDownFrom24Hours() throws {
        let last = now.addingTimeInterval(-24 * 3600 + 3600)

        let remaining = try #require(
            EscapePolicy.cooldownRemaining(lastEscapeAt: last, now: now)
        )

        #expect(remaining == 3600)
    }

    @Test("脱出から 24 時間経てば冷却は終わる")
    func cooldownExpiresAfter24Hours() {
        let last = now.addingTimeInterval(-24 * 3600)

        #expect(EscapePolicy.cooldownRemaining(lastEscapeAt: last, now: now) == nil)
    }

    @Test("無操作 60 秒以内なら戻ってきた")
    func didReturnWithin60SecondsOfIdle() {
        #expect(EscapePolicy.didReturn(idleSeconds: 0))
        #expect(EscapePolicy.didReturn(idleSeconds: 60))
        #expect(!EscapePolicy.didReturn(idleSeconds: 61))
        #expect(!EscapePolicy.didReturn(idleSeconds: 1800))
    }

    @Test("残り時間の表記は 分 / 時間+分 に揃う")
    func durationDescriptionFormatsHoursAndMinutes() {
        #expect(EscapePolicy.durationDescription(5 * 60) == "5 分")
        #expect(EscapePolicy.durationDescription(90 * 60) == "1 時間 30 分")
        #expect(EscapePolicy.durationDescription(1) == "1 分")
    }
}
