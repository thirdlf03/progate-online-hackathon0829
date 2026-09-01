import Foundation

/// 「起動してから何時間かは絶対に終了できない」を管理する。
///
/// Touch ID のような「認証を求めておいて結果を無視する」ことは絶対にしない。
/// ロック中は「まだロック中で、あと何分か」を正直に伝えるだけで、時間さえ来れば
/// 終了の意思は必ず尊重する。認証の体裁を取らないぶん、時間による強制だけが
/// 唯一の抑止力になる ―― その代わり嘘はつかない。
public struct QuitTimeLock: Equatable {

    /// この時刻を過ぎるまで終了できない。`nil` はまだロックが設定されていない
    /// (= 監視がまだ始まっていない)状態を表す。
    public private(set) var unlockAt: Date?

    /// 仮ロックか。デーモンに繋がって解除時刻を確定するまでのあいだ、既定時間で
    /// 暫定的に塞いでいる状態を表す。仮ロックのときだけ本ロックで引き直してよい。
    public private(set) var isProvisional: Bool

    public init(unlockAt: Date? = nil, isProvisional: Bool = false) {
        self.unlockAt = unlockAt
        self.isProvisional = isProvisional
    }

    /// 監視を始めるときに 1 度だけ呼ぶ。`hours` 時間後を解除時刻にする。
    public mutating func lock(for hours: Double, from now: Date = Date()) {
        unlockAt = now.addingTimeInterval(hours * 3600)
        isProvisional = false
    }

    /// 起動直後の仮ロック。#52。
    ///
    /// 解除時刻はデーモン(Discord の `/watch lock`)に繋がってからでないと確定しないが、
    /// 繋がるまでの数秒を `unlockAt == nil`(= 解除済み)のまま放っておくと、その間だけ
    /// Cmd+Q / SIGTERM が素通りする。#5 は「起動した瞬間から効く」ので、まず既定時間で
    /// 塞いでおき、確定したら `establishing` で引き直す。
    public static func provisional(hours: Double, from now: Date) -> QuitTimeLock {
        QuitTimeLock(unlockAt: now.addingTimeInterval(hours * 3600), isProvisional: true)
    }

    /// 本ロックの解除時刻で引き直してよいか。まだロックしていないか、仮ロック中のときだけ。
    public var acceptsFreshDeadline: Bool {
        unlockAt == nil || isProvisional
    }

    /// いま終了してよいか。
    public func isUnlocked(now: Date = Date()) -> Bool {
        guard let unlockAt else { return true }
        return now >= unlockAt
    }

    /// 終了ロックの復元を決める。#52(quitLock トグル化)。
    ///
    /// UserDefaults などに保存されていた解除時刻(`persisted`)が未来ならそれを引き継ぐ。
    /// 監視を再開した拍子に 4 時間へ延び直して、ユーザーの宣言した時刻を無視しないため。
    /// 無いか過去なら `fallbackHours` で新規にロックする(過去の保存値は取り残し)。
    public static func resume(persisted: Date?, now: Date, fallbackHours: Double) -> QuitTimeLock {
        if let persisted, persisted > now {
            return QuitTimeLock(unlockAt: persisted)
        }
        var lock = QuitTimeLock()
        lock.lock(for: fallbackHours, from: now)
        return lock
    }

    /// デーモンに繋がったあとの本ロックを決める。#52。
    ///
    /// - 本ロック中(保存値を引き継いだなど)なら、そのまま据え置く。宣言された時刻を
    ///   接続のたびに引き直さない。
    /// - 仮ロック中なら `hours` で引き直す。このとき保存値は自分が書いた仮の時刻なので
    ///   引き継がない ―― 引き継ぐと、デーモンから取れた時間が永遠に効かなくなる。
    /// - まだロックしていなければ、従来どおり保存値を優先して復元する。
    public static func establishing(
        from current: QuitTimeLock,
        persisted: Date?,
        now: Date,
        hours: Double
    ) -> QuitTimeLock {
        guard current.acceptsFreshDeadline else { return current }
        return resume(
            persisted: current.isProvisional ? nil : persisted,
            now: now,
            fallbackHours: hours
        )
    }

    /// 「あとN時間M分」の表示/読み上げ用文言。ロックしていなければ `nil`。
    public func remainingDescription(now: Date = Date()) -> String? {
        guard let unlockAt, !isUnlocked(now: now) else { return nil }
        let remainingSeconds = Int(unlockAt.timeIntervalSince(now).rounded(.up))
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        if hours > 0 {
            return "あと\(hours)時間\(minutes)分"
        }
        return "あと\(max(minutes, 1))分"
    }
}
