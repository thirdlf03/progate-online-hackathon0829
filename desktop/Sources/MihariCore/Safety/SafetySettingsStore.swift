import Foundation
import os

/// セーフティーモードの設定を持つ。変更は `SafetyPolicy` に問い合わせて
/// 即時 apply / 予約(schedule) / 拒否(reject)を決める。
///
/// 書き込みは MainActor 上だけで行い、他スレッドから同期的に読めるように
/// `gate`(ロックで守った `enabled` のスナップショット)を公開する。
@MainActor
public final class SafetySettingsStore: ObservableObject {

    /// 設定一式を JSON の `Data` として保存するキー。
    public static let defaultsKey = "safety.settings"
    /// モード選択(オンボーディング)を済ませたかのキー。#54 のオンボーディングが立てる。
    public static let modeSelectionCompletedKey = "safety.hasChosenMode"
    /// 旧「スクショに写り込む」のキー。値は引き継がず、見かけたら消す。
    public static let legacyPhotobombKey = "photobombEnabled"
    /// 起動時のみ有効な開発用上書き。値は `all` か `SafetyFeature.rawValue` のカンマ区切り。
    /// **保存しない**(`VoiceModeStore` と同じ思想。次の起動で保存値に戻る)。
    public static let environmentKey = "MIHARI_SAFETY_ENABLE"

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "safety-settings")

    @Published public private(set) var settings: SafetySettings

    /// いまのモード(表示用)。
    public var mode: SafetyMode {
        SafetyMode.of(settings)
    }

    public func isEnabled(_ feature: SafetyFeature) -> Bool {
        settings.isEnabled(feature)
    }

    /// モード選択を一度でも済ませたか(オンボーディング表示の判定に使う)。
    public var hasCompletedModeSelection: Bool {
        defaults.bool(forKey: Self.modeSelectionCompletedKey)
    }

    /// モード選択を済ませたことを記録する。
    public func markModeSelectionCompleted() {
        defaults.set(true, forKey: Self.modeSelectionCompletedKey)
    }

    /// 他スレッドから同期に読める判定口。`settings` が変わるたびにスナップショットを更新する。
    public let gate: SafetyGate

    /// bridge へ渡す形(#50 と共有する契約)。
    public var daemonPayload: SafetyDaemonPayload {
        SafetyDaemonPayload(settings: settings)
    }

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    /// `enabled` のスナップショット。MainActor 外から安全に読めるようロックで守る。
    private let snapshot: OSAllocatedUnfairLock<Set<SafetyFeature>>
    /// 期限が来た予約を 60 秒ごとに適用するタスク。`stop()` / deinit で cancel する。
    private var duePendingTask: Task<Void, Never>?
    /// 予約の適用を回す間隔。#53 のように即時性が要る話ではないので、60 秒で十分。
    private static let pendingCheckInterval: Duration = .seconds(60)

    /// - Parameters:
    ///   - defaults: 保存先。テストでは `UserDefaults(suiteName:)` を渡す。
    ///   - environment: 環境変数。テストでは `[:]` を渡す。
    ///   - now: 現在時刻。テストでは固定値を返すクロージャを渡す。
    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now
        // 読み込み → 期限が来た予約の適用 → normalized → 環境変数による上書き(保存しない)。
        let loaded = Self.load(defaults: defaults, environment: environment, now: now())
        let snapshot = OSAllocatedUnfairLock(initialState: loaded.enabled)
        self.snapshot = snapshot
        self.settings = loaded
        self.gate = SafetyGate(isEnabled: { feature in
            snapshot.withLock { $0.contains(feature) }
        })
        // 起動時に期限の来た予約を 1 回適用して保存する。以降は定期的に回す。
        applyDuePendingChangeIfNeeded()
        startPeriodicApplication()
    }

    /// 予約の適用ループを止める。アプリ終了時やテストで使う。
    public func stop() {
        duePendingTask?.cancel()
        duePendingTask = nil
    }

    deinit {
        duePendingTask?.cancel()
    }

    /// 変更を依頼する。apply / schedule なら保存し、reject なら何もしない。
    ///
    /// - Parameter isWatching: いま監視中か(ロック中も監視中として渡す)。ポリシーは
    ///   `quitLock` を OFF にできるかの判定にだけ使う。
    /// - Returns: ポリシーが下した決定。
    @discardableResult
    public func request(_ change: SafetyChange, isWatching: Bool) -> SafetyDecision {
        let decision = SafetyPolicy.decide(
            change,
            current: settings,
            isWatching: isWatching,
            now: now()
        )
        switch decision {
        case .apply(let newSettings, _):
            commit(newSettings)
        case .schedule(let newSettings, _):
            commit(newSettings)
        case .reject:
            break
        }
        return decision
    }

    /// 執行猶予からの脱出を使ったことを記録する(#52 が使う)。
    public func markEscapeUsed(at date: Date) {
        settings.lastEscapeAt = date
        save()
    }

    /// 期限が来た予約を適用して保存する。来ていなければ何もしない。
    ///
    /// init で 1 回呼び、以降は 60 秒ごとに Task で呼ぶ。アプリが起動している間は
    /// クーリングオフが必ず発効するようにする。
    public func applyDuePendingChangeIfNeeded() {
        let updated = SafetyPolicy.applyingDuePendingChange(settings, now: now())
        guard updated != settings else { return }
        commit(updated)
    }

    // MARK: - 起動時の読み込み

    /// 保存値・移行・期限が来た予約・環境変数をまとめて最初の設定を決める。副作用なし。
    ///
    /// 読み込みの順序: 保存値(無ければ `.default`) → 期限が来た予約の適用 → normalized
    /// → 環境変数による `enabled` の上書き → normalized。環境変数は「開発者が今だけ見たい
    /// 形」だが、依存を欠いた組み合わせ(`iphonePresence` OFF で `iphoneScreenshot` ON)を
    /// そのまま bridge へ渡してしまうので、上書きのあとも整形を通す。
    static func load(
        defaults: UserDefaults,
        environment: [String: String],
        now: Date
    ) -> SafetySettings {
        let stored = defaults.data(forKey: Self.defaultsKey)

        // 移行: 保存値が無く旧キーだけがあれば、その値は引き継がずキーを削除する。
        // 旧実装は「未設定 = 写り込む」だった。全 OFF から始める合意があるため、
        // この書き方のままにすると既存インストールが知らないうちに写り込み続けてしまう。
        if stored == nil, defaults.object(forKey: Self.legacyPhotobombKey) != nil {
            defaults.removeObject(forKey: Self.legacyPhotobombKey)
        }

        // 保存値の JSON は欠けたキーを既定値で埋める(`SafetySettings.init(from:)`)。
        var settings =
            stored.flatMap { try? JSONDecoder().decode(SafetySettings.self, from: $0) }
            ?? .default
        settings = SafetyPolicy.applyingDuePendingChange(settings, now: now)
        settings = settings.normalized()

        // 開発用の上書き。保存しないので、次の起動はまた保存値に戻る。
        if let raw = environment[Self.environmentKey] {
            settings.enabled = Set(Self.parseEnvironment(raw))
            settings = settings.normalized()
        }
        return settings
    }

    /// 環境変数の値をトグル一覧に解釈する。`all` は全 ON、それ以外は rawValue の
    /// カンマ区切り。無効な名前は無視してログに出す。
    static func parseEnvironment(_ raw: String) -> [SafetyFeature] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "all" {
            return SafetyFeature.allCases
        }
        var features: [SafetyFeature] = []
        for name in trimmed.split(separator: ",") {
            let cleaned = name.trimmingCharacters(in: .whitespaces)
            guard let feature = SafetyFeature(rawValue: cleaned) else {
                Self.logger.warning(
                    "MIHARI_SAFETY_ENABLE の無効な名前を無視した: \(cleaned, privacy: .public)"
                )
                continue
            }
            if !features.contains(feature) {
                features.append(feature)
            }
        }
        return features
    }

    // MARK: - 保存

    /// settings を差し替えて保存し、gate のスナップショットを追従させる。
    private func commit(_ newSettings: SafetySettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        save()
        refreshSnapshot()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else {
            Self.logger.error("セーフティー設定を JSON にできない")
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func refreshSnapshot() {
        // withLock のクロージャは @Sendable なので、MainActor 上の settings を閉じ込めない。
        // 先に値を取り出してから書き込む。
        let enabled = settings.enabled
        snapshot.withLock { $0 = enabled }
    }

    private func startPeriodicApplication() {
        duePendingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pendingCheckInterval)
                guard !Task.isCancelled else { return }
                self?.applyDuePendingChangeIfNeeded()
            }
        }
    }
}
