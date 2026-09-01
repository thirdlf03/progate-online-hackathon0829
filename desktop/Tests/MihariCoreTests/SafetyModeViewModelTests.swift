import Foundation
import Testing

@testable import MihariCore

/// セーフティー画面(モード選択 / 設定)の表示ロジック。
///
/// SwiftUI の View にはテストハーネスが無いので、`SafetyModeViewModel` に切り出した
/// 純粋関数の変換・文言・判定をここで検証する。
@Suite("セーフティー画面の表示ロジック")
struct SafetyModeViewModelTests {

    @Test("Toggle の操作が ON/OFF の方向で SafetyChange に変換される")
    func toggleChangeFollowsDirection() {
        #expect(SafetyModeViewModel.toggleChange(for: .macCamera, turningOn: true) == .enable(.macCamera))
        #expect(SafetyModeViewModel.toggleChange(for: .macCamera, turningOn: false) == .disable(.macCamera))

        // 従属(iphoneScreenshot)も同じ規則で方向だけ変わる。
        #expect(SafetyModeViewModel.toggleChange(for: .iphoneScreenshot, turningOn: true) == .enable(.iphoneScreenshot))
    }

    @Test("拒否の理由が状態行の文言に変換される")
    func rejectionReasonsBecomeStatusMessages() {
        #expect(
            SafetyModeViewModel.statusMessage(for: .reject(.enablingWhileWatching))
                == "監視中は ON にできません"
        )
        #expect(
            SafetyModeViewModel.statusMessage(for: .reject(.quitLockWhileWatching))
                == "監視中は OFF にできません"
        )
        #expect(
            SafetyModeViewModel.statusMessage(for: .reject(.dependencyMissing(.iphonePresence)))
                == "「iPhone を見張る」を先に ON にしてください"
        )
    }

    @Test("apply はスキップされた機能があるときだけ状態行に文言を出す")
    func applySpeaksOnlyWhenSomethingWasSkipped() {
        let settings = SafetySettings()
        #expect(
            SafetyModeViewModel.statusMessage(for: .apply(settings, skipped: [.quitLock]))
                == "監視中なので「監視中は終了させない」は残しました"
        )
        #expect(SafetyModeViewModel.statusMessage(for: .apply(settings, skipped: [])) == nil)
    }

    @Test("schedule は予約帯で示すので状態行には何も出さない")
    func scheduleProducesNoStatusMessage() {
        let settings = SafetySettings()
        #expect(SafetyModeViewModel.statusMessage(for: .schedule(settings)) == nil)
    }

    @Test("予約の発効時刻は M/d HH:mm の形で表示する")
    func pendingTimeTextUsesMonthDayAnd24HourClock() throws {
        // 実行環境のローカルタイムゾーンのグレゴリオ暦で 9/2 14:30 を作り、
        // 表示も同じタイムゾーンで整形されることを確かめる。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = 2025
        components.month = 9
        components.day = 2
        components.hour = 14
        components.minute = 30
        let date = try #require(calendar.date(from: components))

        #expect(SafetyModeViewModel.pendingTimeText(effectiveAt: date) == "9/2 14:30")
        #expect(SafetyModeViewModel.pendingStatusText(effectiveAt: date) == "9/2 14:30 に OFF になります")
    }

    @Test("オンボーディングのステップ 2 は要求権限が空かつスクショ OFF なら飛ばす")
    func permissionsStepIsSkippedWhenNothingToShow() {
        #expect(SafetyModeViewModel.shouldSkipPermissionsStep(relevantKinds: [], isIPhoneScreenshotEnabled: false))

        // 要求すべき権限が 1 本でもあれば、飛ばさず権限画面を見せる。
        #expect(
            !SafetyModeViewModel.shouldSkipPermissionsStep(relevantKinds: [.camera], isIPhoneScreenshotEnabled: false)
        )
        // tunneld が要る(iphoneScreenshot が ON の)ときも、登録画面を見せる。
        #expect(!SafetyModeViewModel.shouldSkipPermissionsStep(relevantKinds: [], isIPhoneScreenshotEnabled: true))
    }
}
