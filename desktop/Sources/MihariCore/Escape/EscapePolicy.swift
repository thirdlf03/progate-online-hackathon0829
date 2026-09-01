import Foundation

/// 執行猶予脱出(escape)の純粋ロジック。時刻・間隔・復帰判定を決める。
///
/// quitLock でロックされているあいだの正規の出口。戻る時刻を宣言して 10 分待てば
/// 終了できる。ここに書くのは副作用のない計算だけにして、保存や投稿は呼び出し側に任せる。
public enum EscapePolicy {

    /// 宣言してから実際に終了するまでの待ち時間。
    public static let countdown: TimeInterval = 10 * 60
    /// 脱出を使ったあと、次の脱出まで待たせる時間。
    public static let cooldown: TimeInterval = 24 * 60 * 60
    /// 選べる「戻るまでの時間」の下限。
    public static let minReturnDelay: TimeInterval = 15 * 60
    /// 選べる「戻るまでの時間」の上限。
    public static let maxReturnDelay: TimeInterval = 8 * 60 * 60
    /// 「戻るまでの時間」の刻み。
    public static let returnDelayStep: TimeInterval = 15 * 60

    /// 選べる「戻るまでの時間」の一覧。15 分刻みで 15 分〜8 時間。
    ///
    /// `unlockAt` があればそれを超える選択肢は落とす。ロックの残り時間より長い
    /// 帰還を許すと、「宣言しておけばロックのまま逃げられる」ことになってしまうため。
    public static func returnDelayChoices(now: Date, unlockAt: Date?) -> [TimeInterval] {
        // 上限は 8 時間と「ロック解除まで」の短い方。ロックの残りが負(もう解けている)なら
        // 選択肢は無い。
        let limit: TimeInterval
        if let unlockAt {
            limit = min(max(unlockAt.timeIntervalSince(now), 0), maxReturnDelay)
        } else {
            limit = maxReturnDelay
        }
        guard limit >= minReturnDelay else { return [] }
        var choices: [TimeInterval] = []
        var value = minReturnDelay
        while value <= limit {
            choices.append(value)
            value += returnDelayStep
        }
        return choices
    }

    /// 冷却中なら残り時間を返す(使えるなら nil)。
    ///
    /// 脱出は「10 分待てば終了できる」だけでも十分強い抜け道なので、何度も使って
    /// 常駐の意味をなくさせないためのクールダウン。
    public static func cooldownRemaining(lastEscapeAt: Date?, now: Date) -> TimeInterval? {
        guard let lastEscapeAt else { return nil }
        let elapsed = now.timeIntervalSince(lastEscapeAt)
        guard elapsed < cooldown else { return nil }
        return cooldown - elapsed
    }

    /// 復帰時の判定。Mac の無操作秒数が 60 秒以内なら「戻ってきた」。
    ///
    /// 宣言時刻に Mac を触っていれば戻ったとみなす。触っていない(= まだ席を外している)
    /// なら「戻っていなかった」になり、監視を再開して待ち続ける。
    public static func didReturn(idleSeconds: TimeInterval) -> Bool {
        idleSeconds <= 60
    }

    /// 宣言ダイアログの選択肢 1 つの表示文言。「1 時間 30 分後(18:00)」の形。
    ///
    /// 「1 時間 30 分後」だけだと何時に戻る約束をしたのか計算させることになるので、
    /// 実際の時刻まで書く。
    public static func returnChoiceDescription(_ delay: TimeInterval, from now: Date) -> String {
        "\(durationDescription(delay))後(\(clockText(now.addingTimeInterval(delay))))"
    }

    /// 時刻だけの表示文字列。`HH:mm` の形にする。
    static func clockText(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    /// 残り時間の「N 時間 M 分」表記。1 分未満は 1 分に繰り上げる。
    ///
    /// メニューの冷却表示・カウントダウン表示・ペットの催促セリフで共通で使う。
    /// 例: 90 分 → "1 時間 30 分"、5 分 → "5 分"。
    public static func durationDescription(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours) 時間 \(minutes) 分"
        }
        return "\(minutes) 分"
    }
}
