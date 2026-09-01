import Foundation

@testable import MihariCore

/// メニューの並びを組み立てるためだけの `PetMenuActions`。押された項目を記録する。
@MainActor
final class StubPetMenuActions: ObservableObject, PetMenuActions {
    var isWatching = false
    var isOnBreak = false
    var isStatusPanelVisible = false
    var isPhotobombEnabled = true
    var isDebugMenuVisible = true
    var voiceMode: VoiceMode = .bundled
    var focusStreakIntervalSeconds: TimeInterval = 900
    var isFastThresholds = false
    var escapeMenuState: EscapeMenuState = .hidden
    /// セーフティーモードの 1 行表示。テストでは固定値で十分。
    var safetyStatusLine = "モード: セーフティー"
    /// 「集中継続のセリフを再現」が押された回数。
    private(set) var focusStreakReplays = 0
    /// 「実際に進める」で投げられた操作。
    private(set) var detectionSteps: [DetectionDebugStep] = []
    /// 「どうしても終了する…」が押された回数。
    private(set) var escapeDialogOpens = 0
    /// 「終了を取り消す」が押された回数。
    private(set) var escapeCancels = 0
    /// 設定画面を開いた回数。
    private(set) var settingsOpens = 0
    /// 最後に `openSettings(tab:)` に渡されたタブ。`nil` は「前回のタブのまま」。
    private(set) var lastSettingsTab: SettingsTab?
    /// 「状態パネルを表示」が押された回数。
    private(set) var statusPanelToggles = 0

    func startWatching() {}
    func stopWatching() {}
    func stampAttendance() {}
    func startBreak() {}
    func endBreak() {}
    func openSettings(tab: SettingsTab?) {
        settingsOpens += 1
        lastSettingsTab = tab
    }
    func toggleStatusPanel() {
        statusPanelToggles += 1
        isStatusPanelVisible.toggle()
    }
    func setPhotobombEnabled(_ enabled: Bool) { isPhotobombEnabled = enabled }
    func setVoiceMode(_ mode: VoiceMode) { voiceMode = mode }
    func setFocusStreakInterval(_ seconds: TimeInterval) { focusStreakIntervalSeconds = seconds }
    func setFastThresholds(_ enabled: Bool) { isFastThresholds = enabled }
    func replayFocusStreak() { focusStreakReplays += 1 }
    func runDetectionStep(_ step: DetectionDebugStep) { detectionSteps.append(step) }
    func openEscapeDialog() { escapeDialogOpens += 1 }
    func cancelEscape() { escapeCancels += 1 }
}
