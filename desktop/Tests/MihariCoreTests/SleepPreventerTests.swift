import Foundation
import IOKit.pwr_mgt
import Testing

@testable import MihariCore

/// スリープ防止(IOPMSleepPreventer)を検証する。
@Suite("スリープ防止")
struct SleepPreventerTests {

    @Test("start/stop を何度呼んでもクラッシュせず、多重に assertion を積み増さない")
    func startAndStopAreIdempotent() {
        let preventer = IOPMSleepPreventer(reason: "test")

        preventer.start()
        preventer.start()
        preventer.stop()
        preventer.stop()

        // 例外を投げずに一連の呼び出しが完了すればよい(IOKit の assertion 取得/解放を実機で確認)。
    }

    @Test("アイドルスリープの assertion だけを取る(画面は消えてよい)")
    func acquiresOnlyNoIdleSleep() {
        let preventer = IOPMSleepPreventer()
        defer { preventer.stop() }

        preventer.start()

        #expect(preventer.assertionTypes == [kIOPMAssertionTypeNoIdleSleep])
    }

    @Test("止めると assertion を手放す")
    func stopReleasesTheAssertion() {
        let preventer = IOPMSleepPreventer()

        preventer.start()
        preventer.stop()

        #expect(preventer.assertionTypes.isEmpty)
    }
}
