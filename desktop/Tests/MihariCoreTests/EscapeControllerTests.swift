import Foundation
import Testing

@testable import MihariCore

/// 執行猶予脱出(EscapeController)の進行を、注入した時計と sleeper で検証する。
@Suite("執行猶予脱出の進行")
@MainActor
struct EscapeControllerTests {

    /// `now()` と sleeper が共有する、進む時計。
    private final class TestClock: @unchecked Sendable {
        var date: Date
        init(date: Date) { self.date = date }
    }

    /// 呼ばれるたびに時計を 60 秒進める sleeper。10 分のカウントダウンを待たずに
    /// 最後まで進めるために使う。
    private struct AdvancingSleeper: Sleeper {
        let clock: TestClock

        func sleep(for duration: Duration) async throws {
            clock.date = clock.date.addingTimeInterval(60)
        }
    }

    private func makeController(clock: TestClock) -> EscapeController {
        EscapeController(now: { clock.date }, sleeper: AdvancingSleeper(clock: clock))
    }

    /// 段階が変わるまで(短い実時間で)待つ。
    private func waitUntil(
        _ condition: (EscapeController.Phase) -> Bool,
        controller: EscapeController
    ) async throws {
        for _ in 0..<200 {
            if condition(controller.phase) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("段階の変化を待ちきれなかった: \(controller.phase)")
    }

    @Test("宣言するとカウントダウンに入り、催促してから終了してよい状態になる")
    func countdownNagsThenFinishes() async throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 0))
        let controller = makeController(clock: clock)
        var nags: [TimeInterval] = []
        var finished: EscapeRecord?
        controller.onNag = { nags.append($0) }
        controller.onCountdownFinished = { finished = $0 }

        controller.start(returnDelay: 90 * 60, now: clock.date)

        // 宣言直後はカウントダウン中。終了は 10 分後、復帰は宣言どおり 90 分後。
        #expect(
            controller.phase
                == .countingDown(
                    returnAt: Date(timeIntervalSince1970: 90 * 60),
                    endsAt: Date(timeIntervalSince1970: 10 * 60)
                )
        )

        try await waitUntil(
            { phase in
                if case .readyToTerminate = phase { return true }
                return false
            },
            controller: controller
        )

        #expect(controller.isReadyToTerminate)
        // 60 秒刻みで 10 回進めるが、最後の 1 回は終了時刻と重なるので催促は 9 回。
        #expect(nags.count == 9)
        #expect(nags.first == Double(9 * 60))
        #expect(nags.last == Double(60))
        #expect(
            finished
                == EscapeRecord(
                    escapedAt: Date(timeIntervalSince1970: 10 * 60),
                    returnAt: Date(timeIntervalSince1970: 90 * 60)
                )
        )
    }

    @Test("取り消すと何もなかったことになる")
    func cancelReturnsToIdle() async throws {
        // 実時間の sleeper のままにすると、取り消す前に 60 秒待ってしまう。
        let clock = TestClock(date: Date(timeIntervalSince1970: 0))
        let controller = EscapeController(now: { clock.date })
        var finished = false
        controller.onCountdownFinished = { _ in finished = true }

        controller.start(returnDelay: 15 * 60, now: clock.date)
        // カウントダウンのタスクが最初の待ちに入ったことを、ごく短く待ってから取り消す。
        try await Task.sleep(for: .milliseconds(20))
        controller.cancel()

        #expect(controller.phase == .idle)
        #expect(!controller.isReadyToTerminate)
        #expect(!finished)
    }

    @Test("カウントダウン中に start し直しても無視される")
    func startIsIgnoredWhileCountingDown() async throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 0))
        let controller = EscapeController(now: { clock.date })
        defer { controller.cancel() }

        controller.start(returnDelay: 15 * 60, now: clock.date)
        let first = controller.phase

        controller.start(returnDelay: 15 * 60, now: clock.date.addingTimeInterval(120))

        #expect(controller.phase == first)
    }
}
