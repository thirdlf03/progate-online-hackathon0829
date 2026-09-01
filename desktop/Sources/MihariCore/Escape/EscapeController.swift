import Combine
import Foundation

/// 時間待ちの抽象。テストでは待たずに進められるスタブに差し替える。
public protocol Sleeper: Sendable {
    /// 指定の時間だけ待つ。キャンセルされたら `CancellationError` を投げてもよい。
    func sleep(for duration: Duration) async throws
}

/// `Task.sleep` を使う本物の実装。
public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// 執行猶予脱出(escape)の進行を管理する。
///
/// quitLock でロックされているあいだの正規の出口。戻る時刻を宣言し、10 分の
/// カウントダウンを待って終了できる。カウント中は取り消せる。
/// 時刻(`now`)と待ち時間(`sleeper`)は注入できるようにしてあり、
/// テストでは待たずに最後まで進める。
@MainActor
public final class EscapeController: ObservableObject {

    /// 進行段階。
    public enum Phase: Equatable {
        /// 脱出していない。
        case idle
        /// カウントダウン中。`returnAt` は宣言した復帰時刻、`endsAt` は終了してよい時刻。
        case countingDown(returnAt: Date, endsAt: Date)
        /// カウントダウンが終わった。終了してよい。
        case readyToTerminate(returnAt: Date)
    }

    /// いまの段階。
    @Published public private(set) var phase: Phase = .idle

    /// カウントダウンが終わったときに呼ばれる。本体はここで記録の保存・投稿・終了をする。
    public var onCountdownFinished: ((EscapeRecord) -> Void)?
    /// カウントダウン中、60 秒ごとに呼ばれる。残り秒数を渡す(ペットの引き止めセリフ用)。
    public var onNag: ((TimeInterval) -> Void)?

    private let now: () -> Date
    private let sleeper: Sleeper
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - now: 現在時刻。テストでは固定値を返すクロージャを渡す。
    ///   - sleeper: 待ち時間の実体。テストではすぐ進めるスタブに差し替える。
    public init(
        now: @escaping () -> Date = { Date() },
        sleeper: Sleeper = TaskSleeper()
    ) {
        self.now = now
        self.sleeper = sleeper
    }

    /// カウントダウンを始めてよいか(脱出済み・進行中でない)。
    public var isReadyToTerminate: Bool {
        if case .readyToTerminate = phase { return true }
        return false
    }

    /// カウントダウンを始める。既に始まっていたら(または終わっていたら)何もしない。
    ///
    /// `returnDelay` だけ後の時刻を「戻ると宣言」し、`now + countdown` に終了時刻を置く。
    public func start(returnDelay: TimeInterval, now: Date) {
        guard isIdle else { return }
        let returnAt = now.addingTimeInterval(returnDelay)
        let endsAt = now.addingTimeInterval(EscapePolicy.countdown)
        phase = .countingDown(returnAt: returnAt, endsAt: endsAt)
        task = Task { [weak self] in
            guard let self else { return }
            await self.runCountdown(returnAt: returnAt, endsAt: endsAt)
        }
    }

    /// カウントダウンを取り消して、何もなかったことにする。
    public func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    /// 60 秒ごとに催促(`onNag`)を挟み、終了時刻を過ぎたら `readyToTerminate` に遷移する。
    private func runCountdown(returnAt: Date, endsAt: Date) async {
        while now() < endsAt {
            try? await sleeper.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            let remaining = endsAt.timeIntervalSince(now())
            guard remaining > 0 else { break }
            onNag?(remaining)
        }
        guard !Task.isCancelled else { return }
        phase = .readyToTerminate(returnAt: returnAt)
        onCountdownFinished?(EscapeRecord(escapedAt: now(), returnAt: returnAt))
    }
}

extension EscapeController {

    /// 脱出の記録を「次回起動時に復帰処理をする」ために持ち越す UserDefaults のキー。
    public static let pendingReportKey = "escape.pendingReport"

    /// 復帰処理用の記録を保存する。JSON で保存し、本体が次に起動したときに読む。
    public static func savePendingReport(_ record: EscapeRecord, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: pendingReportKey)
    }

    /// 復帰処理用の記録を取り出して消す。無ければ `nil`。
    public static func consumePendingReport(defaults: UserDefaults = .standard) -> EscapeRecord? {
        guard let data = defaults.data(forKey: pendingReportKey) else { return nil }
        defaults.removeObject(forKey: pendingReportKey)
        return try? JSONDecoder().decode(EscapeRecord.self, from: data)
    }
}
