import Foundation
import Testing

@testable import MihariCore

@Suite("起動からの終了ロック")
struct QuitTimeLockTests {

    @Test("ロックしていなければ、いつでも解除済み")
    func unlockedByDefault() {
        let lock = QuitTimeLock()

        #expect(lock.isUnlocked())
        #expect(lock.remainingDescription() == nil)
    }

    @Test("ロック直後は解除されていない")
    func lockedImmediatelyAfterLocking() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)

        lock.lock(for: 4, from: now)

        #expect(!lock.isUnlocked(now: now))
    }

    @Test("ロック時間ちょうどで解除される")
    func unlocksExactlyAtTheDeadline() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        #expect(lock.isUnlocked(now: now.addingTimeInterval(3600)))
    }

    @Test("ロック時間の1秒前はまだ解除されていない")
    func staysLockedOneSecondBeforeTheDeadline() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        #expect(!lock.isUnlocked(now: now.addingTimeInterval(3600 - 1)))
    }

    @Test("残り時間の表示は時間と分を含む")
    func remainingDescriptionIncludesHoursAndMinutes() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 2.5, from: now)

        let description = lock.remainingDescription(now: now.addingTimeInterval(3600 + 600))

        #expect(description == "あと1時間20分")
    }

    @Test("残り1時間未満は分だけの表示になる")
    func remainingDescriptionOmitsHoursWhenUnderOne() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        let description = lock.remainingDescription(now: now.addingTimeInterval(3600 - 300))

        #expect(description == "あと5分")
    }

    @Test("解除済みなら残り時間の表示は無い")
    func remainingDescriptionIsNilWhenUnlocked() {
        var lock = QuitTimeLock()
        let now = Date(timeIntervalSince1970: 0)
        lock.lock(for: 1, from: now)

        #expect(lock.remainingDescription(now: now.addingTimeInterval(3600)) == nil)
    }

    @Test("resume は未来の保存値を引き継ぐ(4 時間に延び直さない)")
    func resumeKeepsFuturePersistedDeadline() {
        let persisted = Date(timeIntervalSince1970: 3600)

        let lock = QuitTimeLock.resume(
            persisted: persisted,
            now: Date(timeIntervalSince1970: 0),
            fallbackHours: 4
        )

        #expect(lock.unlockAt == persisted)
        #expect(!lock.isUnlocked(now: Date(timeIntervalSince1970: 1800)))
        #expect(lock.isUnlocked(now: Date(timeIntervalSince1970: 3600)))
    }

    @Test("resume は過去の保存値を無視して新規ロックする")
    func resumeIgnoresPastPersistedDeadline() {
        let persisted = Date(timeIntervalSince1970: -3600)

        let lock = QuitTimeLock.resume(
            persisted: persisted,
            now: Date(timeIntervalSince1970: 0),
            fallbackHours: 2
        )

        #expect(lock == QuitTimeLock(unlockAt: Date(timeIntervalSince1970: 2 * 3600)))
    }

    @Test("resume は保存値が無ければ新規ロックする")
    func resumeLocksFreshWithoutPersistedValue() {
        let lock = QuitTimeLock.resume(
            persisted: nil,
            now: Date(timeIntervalSince1970: 0),
            fallbackHours: 4
        )

        #expect(lock == QuitTimeLock(unlockAt: Date(timeIntervalSince1970: 4 * 3600)))
    }
}

/// 起動した瞬間から効かせるための仮ロックと、デーモンに繋がってからの引き直し。#52。
@Suite("仮ロックと本ロック")
struct QuitTimeLockProvisionalTests {

    private let now = Date(timeIntervalSince1970: 0)

    @Test("仮ロックはその場から効き、引き直しを受け付ける")
    func provisionalLocksImmediatelyAndAcceptsAFreshDeadline() {
        let lock = QuitTimeLock.provisional(hours: 4, from: now)

        #expect(!lock.isUnlocked(now: now))
        #expect(lock.unlockAt == Date(timeIntervalSince1970: 4 * 3600))
        #expect(lock.isProvisional)
        #expect(lock.acceptsFreshDeadline)
    }

    @Test("仮ロック中は、デーモンから取れた時間で引き直す(保存値は引き継がない)")
    func establishingOverridesTheProvisionalLock() {
        // 保存値は仮ロック自身が書いた 4 時間。引き継ぐと 2 時間が永遠に効かなくなる。
        let provisional = QuitTimeLock.provisional(hours: 4, from: now)

        let established = QuitTimeLock.establishing(
            from: provisional,
            persisted: provisional.unlockAt,
            now: now,
            hours: 2
        )

        #expect(established == QuitTimeLock(unlockAt: Date(timeIntervalSince1970: 2 * 3600)))
        #expect(!established.isProvisional)
    }

    @Test("保存値を引き継いだ本ロック中は、引き直さない")
    func establishingKeepsAnEstablishedLock() {
        // 再起動を跨いで拾った解除時刻。宣言された時刻を接続のたびに延ばさない。
        let established = QuitTimeLock.resume(
            persisted: Date(timeIntervalSince1970: 3600),
            now: now,
            fallbackHours: 4
        )

        let after = QuitTimeLock.establishing(
            from: established,
            persisted: Date(timeIntervalSince1970: 3600),
            now: now,
            hours: 8
        )

        #expect(after == established)
    }

    @Test("まだロックしていなければ、従来どおり保存値を優先して復元する")
    func establishingRestoresThePersistedDeadlineWhenUnlocked() {
        let after = QuitTimeLock.establishing(
            from: QuitTimeLock(),
            persisted: Date(timeIntervalSince1970: 3600),
            now: now,
            hours: 8
        )

        #expect(after == QuitTimeLock(unlockAt: Date(timeIntervalSince1970: 3600)))
    }

    @Test("lock で引き直したら仮ロックではなくなる")
    func lockingClearsTheProvisionalFlag() {
        var lock = QuitTimeLock.provisional(hours: 4, from: now)

        lock.lock(for: 2, from: now)

        #expect(!lock.isProvisional)
        #expect(!lock.acceptsFreshDeadline)
    }
}
