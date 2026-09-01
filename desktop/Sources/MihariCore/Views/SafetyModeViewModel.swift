import Foundation

/// セーフティー画面(モード選択 / 設定)の表示ロジック。
///
/// SwiftUI の View はテストハーネスが無いので、判定と文言をここに純粋関数として
/// 切り出し、テストはこちらに対して書く(`SafetyModeViewModelTests`)。
/// View 側は文言を持たず、この関数の返り値をそのまま表示する。
public enum SafetyModeViewModel {

    /// Toggle の操作をポリシーへの依頼(`SafetyChange`)に変換する。
    public static func toggleChange(for feature: SafetyFeature, turningOn: Bool) -> SafetyChange {
        turningOn ? .enable(feature) : .disable(feature)
    }

    /// `SafetyDecision` から「状態行」に出す 1 行の文言を決める。
    ///
    /// - Returns: 表示すべき文言。何も出さないときは `nil`。
    ///
    /// - Note: `.schedule` は予約帯を出して結果を示すため、状態行には何も書かない。
    ///   `.apply` は `skipped`(監視中の `disableAll` で残した `quitLock` など)が
    ///   あるときだけ、その旨を伝える。
    public static func statusMessage(for decision: SafetyDecision) -> String? {
        switch decision {
        case .apply(_, let skipped):
            // 監視中に「全部 OFF」を頼むと quitLock だけ残る。残したことを明かさないと
            // 「全部 OFF にしたのに終了できない」と誤解させるため、ここで伝える。
            if !skipped.isEmpty {
                return "監視中なので「監視中は終了させない」は残しました"
            }
            return nil
        case .schedule:
            return nil
        case .reject(let reason):
            switch reason {
            case .enablingWhileWatching:
                return "監視中は ON にできません"
            case .quitLockWhileWatching:
                return "監視中は OFF にできません"
            case .dependencyMissing:
                return "「iPhone を見張る」を先に ON にしてください"
            }
        }
    }

    /// 予約の発効時刻の表示文字列。`Date.FormatStyle` で `M/d HH:mm` の形にする。
    public static func pendingTimeText(effectiveAt: Date) -> String {
        effectiveAt.formatted(
            Date.FormatStyle()
                .month(.defaultDigits)
                .day(.defaultDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    /// カードの中に出す予約バッジの文言。「9/2 14:30 に ON」の形。
    ///
    /// 設定画面の最下部と違って、そのカード 1 枚のことだけを言う。
    public static func pendingFeatureText(effectiveAt: Date) -> String {
        "\(pendingTimeText(effectiveAt: effectiveAt)) に ON"
    }

    /// 設定画面の最下部に出す予約帯の文言。予約の中身で出し分ける。
    ///
    /// 予約に載るのは緩める方向(機能の ON・「あとで設定を変えられるようにする」の復帰)
    /// だけなので、どちらが載っているかで文を変える。両方なら 1 文にまとめる。
    public static func pendingStatusText(for pending: SafetyPendingChange) -> String {
        let time = pendingTimeText(effectiveAt: pending.effectiveAt)
        // 表示順はトグルの並び順に合わせる(Set のままだと順序が安定しない)。
        let names = SafetyFeature.allCases
            .filter { pending.enabling.contains($0) }
            .map(\.title)
        let changeability = "「あとで設定を変えられるようにする」"
        switch (names.isEmpty, pending.restoresChangeability) {
        case (false, false):
            return "\(time) に ON になります(\(names.joined(separator: ", ")))"
        case (false, true):
            return "\(time) に ON になります(\(names.joined(separator: ", "))、\(changeability))"
        case (true, true):
            return "\(time) に\(changeability)が ON に戻ります"
        case (true, false):
            // 中身が空の予約は積まれない(`SafetyPolicy.removing` が消す)ので、保険。
            return "\(time) に発効します"
        }
    }

    /// オンボーディングのステップ 2(権限画面)を飛ばしてよいか。
    ///
    /// トグルが要求している権限が 1 つも無く、かつ tunneld も不要(iphoneScreenshot が
    /// OFF)なら、ステップ 2 に見せるものが無いので直ちに `onStart` する。
    ///
    /// モーションのようにトグルと紐づかない権限(`feature == nil`)は全 OFF でも一覧に
    /// 出るが、任意なので「見せるものがある」とは数えない。
    public static func shouldSkipPermissionsStep(
        relevantKinds: [PermissionKind],
        isIPhoneScreenshotEnabled: Bool
    ) -> Bool {
        relevantKinds.allSatisfy { $0.feature == nil } && !isIPhoneScreenshotEnabled
    }

    // MARK: - 見た目の文言(design-54.md)

    /// モードの一言。
    public static func modeSubtitle(for mode: SafetyMode) -> String {
        switch mode {
        case .safety:
            return "撮らない・晒さない・縛らない。ペットが浮くだけ。"
        case .custom(let enabledCount):
            return "\(enabledCount) 個の機能を許しています。"
        case .unlimited:
            return "Mihari が本気になります。終了も 4 時間できません。"
        }
    }

    /// モードのアイコン。
    public static func modeIcon(for mode: SafetyMode) -> String {
        switch mode {
        case .safety:
            return "checkmark.shield.fill"
        case .custom:
            return "slider.horizontal.3"
        case .unlimited:
            return "flame.fill"
        }
    }

    /// ヘッダーの 7 インジケータに並べる短い名前。トグルの並び順どおり。
    public static func shortFeatureName(for feature: SafetyFeature) -> String {
        switch feature {
        case .macCamera: return "Mac"
        case .iphonePresence: return "iPhone"
        case .iphoneScreenshot: return "画面"
        case .discordExposure: return "Discord"
        case .sermonTakeover: return "占領"
        case .quitLock: return "終了"
        case .photobomb: return "写込"
        }
    }

    /// 従属(`requires` を持つ機能)のカードに添える 1 行の文言。
    ///
    /// 前提が OFF なら選べないので、その理由を出す。前提が予約中(発効待ちの ON に
    /// 載っている)なら従属も同じ予約に積めるので、選べないのではなく「一緒に ON に
    /// なる」ことを伝える。
    ///
    /// - Returns: 出す文言。前提が ON で添える必要が無いときは nil。
    public static func dependencyNote(
        isRequiredEnabled: Bool,
        isRequiredPending: Bool
    ) -> String? {
        if isRequiredEnabled {
            return nil
        }
        if isRequiredPending {
            return "「iPhone を見張る」の予約と一緒に ON になります"
        }
        return "「iPhone を見張る」を ON にすると選べます"
    }

    /// カードの注意帯の文言。対象は iphoneScreenshot と quitLock の 2 本だけ。
    public static func notice(for feature: SafetyFeature) -> String? {
        switch feature {
        case .iphoneScreenshot:
            return "画面の内容は Google Gemini に送られて読み取られます"
        case .quitLock:
            return "起動した瞬間から、決めた時間(既定 4 時間)は終了できません"
        default:
            return nil
        }
    }
}
