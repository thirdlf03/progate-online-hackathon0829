import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// アプリ全体の取りまとめ役。
///
/// ここが唯一「全機能を知っている」場所。各機能は互いを知らずに作ってあり、
/// 検知エンジンの実行部にそれぞれを差し込むことで初めて 1 つのアプリになる。
/// 画面(ペット・補助ウィンドウ・メニュー)からの操作もすべてここを通る。
@MainActor
public final class AppCoordinator: ObservableObject, PetMenuActions {

    /// 検証用の 10 タブ画面を出すかどうかを決める環境変数。
    static let debugUIEnvironmentKey = "MIHARI_DEBUG_UI"

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "app-coordinator")

    public let permissions: PermissionsModel
    public let daemon = DaemonController()
    public let voice: VoiceController
    /// 同封音声か live か。ペット・検知・説教のすべてがここを見る。
    public let voiceModeStore: VoiceModeStore
    /// セーフティートグルの設定とポリシー。#49。
    public let safety: SafetySettingsStore
    public let discord = DiscordController()
    public let attendance: AttendanceModel
    public let detection: DetectionEngine
    public let pet: LivePetPresenter
    public let questioner = HeadGestureQuestioner()
    /// 執行猶予脱出(宣言・10 分待ち・冷却・自動復帰)の進行。#52。
    public let escape = EscapeController()

    /// 音楽を止めて聞かせる全画面オーバーレイ。
    ///
    /// セリフの取得と読み上げを注入するため、`self` を参照できる `lazy var` にしてある。
    /// 注入しないと、音楽が鳴っている場面(`interrupt` 経路)で一言も喋らないまま暗転する。
    public lazy var overlay: OverlayModel = makeOverlay()

    // 以下は検証用の 10 タブ画面でしか使わないので、開かれるまで作らない。
    public lazy var capture = CaptureViewModel(
        service: CaptureService(camera: CameraCaptureService(gate: safety.gate)),
        iphoneScreenshot: { [daemon] in
            guard let client = await daemon.connectedClient else { throw DaemonError.notRunning }
            return try await client.iphoneScreenshot()
        },
        speak: { [voice, daemon] request in
            // 喋れなかったときに前回の記録を返してしまわないよう、成否を先に見る。
            guard await voice.speak(request, using: daemon.connectedClient) != nil else { return nil }
            return voice.history.first
        }
    )
    public lazy var vision = FaceVisionViewModel()
    public lazy var headGesture = HeadGestureController()

    /// 監視中か。メニューの表示に使う。
    @Published public private(set) var isWatching = false
    /// 休憩中か。メニューの表示に使う。
    @Published public private(set) var isOnBreak = false
    /// 状態パネルを出しているか。メニューの表示に使う。
    @Published public private(set) var isStatusPanelVisible = false
    /// スクショに写り込むか。メニューの表示に使う。セーフティートグル(.photobomb)を映す。
    public var isPhotobombEnabled: Bool {
        safety.isEnabled(.photobomb)
    }

    /// 在席スタンプのカットインを出す層。
    private let cutIn: AttendanceCutInPresenting = AttendanceCutInPresenter()
    /// 在席スタンプ / 疑い 1 の演出をしている最中か。押し直しでカットインが重なるのを防ぐ。
    private var isStampCeremonyRunning = false
    /// 演出の世代。畳まれたら 1 つ進めて、結末の演出を出さずにカットインだけ閉じる。
    private var ceremonyGeneration = 0

    /// カットインを出してから認証ダイアログを出すまでの間(秒)。
    private static let cutInLeadInSeconds: TimeInterval = 0.45
    /// 結末の絵に差し替えてからカットインを閉じるまでの時間(秒)。
    private static let cutInHoldSeconds: TimeInterval = 1.8

    /// 音を出す口。検知のセリフとペットのひとりごとで 1 つを共有する。
    private let speechPlayer: SpeechPlayer
    /// アプリの外(Claude Code のフックなど)からの合図の受け口。
    private let externalTrigger = ExternalTriggerListener()
    /// スクリーンショットが保存されたのを見張る。
    private let photobombWatcher = ScreenshotPhotobombWatcher()
    /// 保存されたスクショにペットのスプライトを描き足す層。
    ///
    /// セリフをペットの吹き出しに繋ぐため、`self` を参照できる `lazy var` にしてある。
    private lazy var photobomb = ScreenshotPhotobombCompositor(
        say: { [weak self] line in
            self?.pet.controller.say(line)
        }
    )
    private let windows = AuxiliaryWindows()
    private let statusPanel = StatusPanelController()
    /// 監視中はディスプレイ/システムのアイドルスリープを止める。
    private let sleepPreventer: SleepPreventing
    /// 起動してから何時間かは終了そのものを受け付けない。
    private var quitTimeLock = QuitTimeLock()
    /// `quitTimeLock` に渡す既定のロック時間。デーモン(Discord の `/watch lock`)から
    /// 取れなかったときのフォールバック。
    private static let defaultLockHours: Double = 4
    /// ロックの解除時刻(`quitTimeLock.unlockAt`)をまたいで覚えておく UserDefaults のキー。
    /// 値は `Date`。kill されて再起動しても、宣言した解除時刻を引き継ぐために置いておく(#52)。
    private static let quitLockDeadlineKey = "quitLock.unlockAt"
    /// kill されて落ちても次回ログインで自動的に立ち上がるよう登録する。
    private let loginItemRegistrar: LoginItemRegistering
    /// 本体が kill されても、こちらの監視プロセスが数秒以内に起こす。
    private let watchdogRegistrar: WatchdogRegistering
    /// 前回、正常に終了できていたか(kill されて起こされたのかを見分けるため)。
    private let lifecycleMarker: AppLifecycleMarking
    private var cancellables: Set<AnyCancellable> = []
    /// すでに見張り始めたか。`begin()` を何度呼んでも 1 回しか効かないようにする。
    private var hasBegun = false
    /// 監視プロセスの登録を定期的に見直すループ。`launchctl bootout` で外から
    /// 消されても、Touch ID を経ずには長続きさせないためのもの。
    private var watchdogReassertionTask: Task<Void, Never>?
    /// 上の見直しの間隔。短すぎると無駄に `launchctl` を叩き、長すぎると
    /// 「外から消されてから戻るまで」のすきまが意味を持ち始める。
    private static let watchdogReassertionInterval: Duration = .seconds(20)
    /// quitLock トグルのひとつ前の ON/OFF。購読直後は「いまの状態」を覚えるだけで
    /// 何もしない(begin() が適用済みのため)。
    private var quitLockPolicyState: Bool?
    /// 前回の執行猶予脱出からの復帰で「戻ってきた」か。デーモン接続後の投稿までためておく。
    private var pendingEscapeReturn: Bool?
    /// quitLock の解除時刻などの保存先。
    private let defaults: UserDefaults

    /// - Parameters:
    ///   - sleepPreventer: スリープ防止の実体。テストでは呼び出し回数だけ記録するスタブに差し替える。
    ///   - loginItemRegistrar: ログイン項目への登録処理。テストでは何もしないスタブに差し替える。
    ///   - watchdogRegistrar: 監視プロセスの登録処理。テストでは何もしないスタブに差し替える。
    ///   - lifecycleMarker: 前回の終了が正常だったかの記録。テストでは固定値を返すスタブに差し替える。
    ///   - safety: セーフティートグルの設定。テストでは `UserDefaults(suiteName:)` の store を渡す。
    ///   - defaults: quitLock の解除時刻などの保存先。テストでは `UserDefaults(suiteName:)` を渡す。
    public init(
        sleepPreventer: SleepPreventing = IOPMSleepPreventer(),
        loginItemRegistrar: LoginItemRegistering = SMAppServiceLoginItemRegistrar(),
        watchdogRegistrar: WatchdogRegistering = LaunchAgentWatchdogRegistrar(),
        lifecycleMarker: AppLifecycleMarking = UserDefaultsLifecycleMarker(),
        safety: SafetySettingsStore = SafetySettingsStore(),
        defaults: UserDefaults = .standard
    ) {
        let player = SpeechPlayer()
        let attendance = AttendanceModel()
        self.speechPlayer = player
        self.attendance = attendance
        self.permissions = PermissionsModel()
        self.voice = VoiceController(player: player)
        self.voiceModeStore = VoiceModeStore()
        self.safety = safety
        // 在席スタンプ直後の猶予を効かせるため、検知エンジンに在席の記録を渡す。
        self.detection = DetectionEngine(attendance: attendance)
        self.pet = LivePetPresenter(controller: PetController(speechPlayer: player))
        self.isStatusPanelVisible = statusPanel.isVisible
        self.sleepPreventer = sleepPreventer
        self.loginItemRegistrar = loginItemRegistrar
        self.watchdogRegistrar = watchdogRegistrar
        self.lifecycleMarker = lifecycleMarker
        self.defaults = defaults
        observeVoiceMode()
    }

    /// 音声モードの切り替えを、喋る側すべてに配る。
    ///
    /// メニューから切り替えた瞬間に効かせたいので、`@Published` を購読して押し込む。
    private func observeVoiceMode() {
        voiceModeStore.$mode
            .sink { [weak self] mode in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 検知のセリフは同封音声で固定なので、切り替えるのはペットのひとりごとと説教。
                    self.pet.controller.voiceMode = mode
                    // メニューバー側のチェックを描き直させる。
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 起動

    /// 起動直後に一度だけ呼ぶ。権限が揃っているかで、権限画面を出すか見張り始めるかを決める。
    public func launch() {
        permissions.refresh()

        if Self.isDebugUIRequested {
            showDebugWindow()
        }

        // 初回起動、または必須権限が欠けているうちは見張らない。
        // 撮れも送れもしない状態で常駐しても、黙って失敗し続けるだけになる。
        if !permissions.hasCompletedFirstLaunch || !permissions.isRequiredSatisfied {
            showPermissionWindow(canStart: true)
        } else {
            begin()
        }
    }

    /// ペットを出して見張り始める。2 回目以降は何もしない。
    public func begin() {
        guard !hasBegun else { return }
        hasBegun = true

        // 前回、執行猶予脱出で終了していれば、復帰の判定を済ませておく。
        // 投稿はデーモンに繋がってからにするので、ここでは「戻ってきたか」まで(#52)。
        handleEscapeReturnIfNeeded()

        // quitLock トグルに従って、常駐の仕掛け(スリープ防止・ログイン項目・watchdog・
        // 解除時刻)を一式そろえる。OFF なら以前 ON だったときの登録を掃除する(#52)。
        applyQuitLockPolicy()

        // 前回、正常に終了できていなければ(= kill か crash で消えたのを監視プロセスに
        // 起こされたのなら)、記録を上書きする前に見ておく。
        let wasKilled = !lifecycleMarker.wasPreviousSessionGraceful()
        lifecycleMarker.markSessionStarted()

        // 右クリックメニューはウィンドウを作る前に差し込む。
        pet.controller.contextMenuBuilder = { [weak self] in
            guard let self else { return NSMenu() }
            return PetContextMenu.makeMenu(PetMenuEntries.make(actions: self, presenter: pet))
        }
        pet.show()
        if wasKilled {
            pet.controller.say(RevivalAngerLine.random())
        }
        statusPanel.restore { statusPanelView }
        observeDetection()
        observeDaemonEvents()
        observeSafety()
        wireEscape()

        // Claude Code の Stop フック(notifyutil -p)からの「応答を終えた」合図。
        externalTrigger.listen(name: ExternalTriggerListener.claudeDoneName) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pet.controller.say("終わったよー")
            }
        }

        // 保存されたスクショに、あとからペットのスプライトを描き足して写り込む。
        if isPhotobombEnabled {
            startPhotobombWatching()
        }

        Task { [weak self] in
            guard let self else { return }
            await daemon.start()
            // セーフティートグルをデーモンへ伝える。サーバ側の受信は #50 で実装される。
            pushSafetyToDaemon()
            wireDetection()
            // 常駐して見張るアプリなので、始めたら見張り続ける。
            detection.start()

            // 前回の執行猶予脱出からの復帰を、デーモンに繋がったいま投稿する(#52)。
            postEscapeReturnIfPending()

            // ロックの解除時刻は、デーモンに繋がってから確定させる。保存値の引き継ぎ
            // (applyQuitLockPolicy)で既にロック済みなら、ここでは何もしない(#52)。
            if safety.isEnabled(.quitLock) {
                await establishFreshQuitLockDeadline()
            }
        }
    }

    /// 終了時の後片付け。見張りを止めて、子プロセスのデーモンも落とす。
    public func shutdown() {
        detection.stop()
        photobombWatcher.stop()
        daemon.stop()
        sleepPreventer.stop()
        watchdogReassertionTask?.cancel()
        watchdogReassertionTask = nil
    }

    /// 終了(Cmd+Q・Dock「終了」・kill によるシグナル)してよいか。
    ///
    /// - quitLock OFF: 見張り中の対話的な終了(Cmd+Q など)にだけ「監視中です。終了しますか?」
    ///   の確認を 1 枚出し、OK なら true。非対話(シグナル)か監視外なら素通しする。
    ///   watchdog / ログイン項目は登録していないので解除しない(呼んでも害はない)。
    /// - quitLock ON: 従来どおり、ロック中は認証のふりをせず断る(ペットのセリフ)。
    ///   ただし執行猶予脱出のカウントダウンが終わっている(`escape.isReadyToTerminate`)なら
    ///   true —— そのとき watchdog / ログイン項目は**解除しない**。宣言時刻に復帰するための
    ///   仕掛けを残しておく。ロックが解けていれば従来どおり登録を解いて true。
    ///
    /// - Parameter interactive: ユーザーが画面から操作した終了か。シグナル経由なら false。
    public func confirmQuit(interactive: Bool) async -> Bool {
        guard hasBegun else { return true }

        if safety.isEnabled(.quitLock) {
            let allowed = escape.isReadyToTerminate || quitTimeLock.isUnlocked()
            guard allowed else {
                if let remaining = quitTimeLock.remainingDescription() {
                    pet.controller.say("まだロック中。\(remaining)は消せないよ。")
                }
                return false
            }
            // 脱出の完了による終了は、監視プロセスとログイン項目を残したまま終わる
            // (宣言時刻に自動で戻って監視を再開させるため、ここでは解除しない)。
            if !escape.isReadyToTerminate {
                watchdogRegistrar.unregister()
                loginItemRegistrar.unregister()
            }
            lifecycleMarker.markGracefulShutdown()
            return true
        }

        // quitLock OFF。見張っている最中に対話的な終了を頼まれたら、確認を 1 枚出す。
        var allowed = true
        if interactive && isWatching {
            let alert = NSAlert()
            alert.messageText = "監視中です。終了しますか?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "終了する")
            alert.addButton(withTitle: "キャンセル")
            allowed = alert.runModal() == .alertFirstButtonReturn
        }
        guard allowed else { return false }
        // 登録はしていないが、残っていた登録を掃除する(呼んでも害はない)。
        watchdogRegistrar.unregister()
        loginItemRegistrar.unregister()
        lifecycleMarker.markGracefulShutdown()
        return true
    }

    // MARK: - quitLock トグルと執行猶予脱出 (#52)

    /// quitLock トグルのいまの状態に、常駐の仕掛けを合わせる。
    ///
    /// `begin()` と、quitLock が OFF→ON に変わったとき(監視外でしか起きない)に呼ぶ。
    /// ON のときはスリープ防止・ログイン項目・watchdog(+見直しループ)を入れ、
    /// 保存されていた解除時刻(`quitLock.unlockAt`)が未来ならそれを引き継ぐ。
    /// OFF のときは以前 ON だったときの登録を掃除する。ON→OFF はロック中には起きない
    /// (SafetyPolicy が弾く)ので、掃除だけで足りる。
    private func applyQuitLockPolicy() {
        if safety.isEnabled(.quitLock) {
            sleepPreventer.start()
            loginItemRegistrar.ensureRegistered()
            watchdogRegistrar.ensureRegistered()
            startWatchdogReassertion()
            resumePersistedQuitLockDeadline()
        } else {
            releaseQuitLock()
        }
    }

    /// 終了ブロックを OFF にしたときの後片付け。登録を解き、解除時刻と保存を取り消す。
    private func releaseQuitLock() {
        watchdogRegistrar.unregister()
        loginItemRegistrar.unregister()
        watchdogReassertionTask?.cancel()
        watchdogReassertionTask = nil
        sleepPreventer.stop()
        quitTimeLock = QuitTimeLock()
        defaults.removeObject(forKey: Self.quitLockDeadlineKey)
    }

    /// 監視プロセスの登録を定期的に見直すループを始める。既に走っていれば何もしない。
    ///
    /// `launchctl bootout` で登録だけ外からむしり取られても、Touch ID を経ない解除を
    /// 長続きさせない。解除側(`releaseQuitLock`)で止めてから OFF→ON されたときは
    /// 最初からやり直せるよう、止めたら nil に戻してある。
    private func startWatchdogReassertion() {
        guard watchdogReassertionTask == nil else { return }
        watchdogReassertionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogReassertionInterval)
                guard !Task.isCancelled else { return }
                self?.watchdogRegistrar.reassertIfMissing()
            }
        }
    }

    /// 保存されていた解除時刻(`quitLock.unlockAt`)が未来なら、そのまま引き継ぐ。
    /// 監視を再開した拍子に 4 時間へ延び直さないためのもの。同期で済ませて、デーモン
    /// に繋がる前でもロックが効いている状態にする。
    private func resumePersistedQuitLockDeadline() {
        guard quitTimeLock.unlockAt == nil else { return }
        guard let persisted = defaults.object(forKey: Self.quitLockDeadlineKey) as? Date,
            persisted > Date()
        else { return }
        quitTimeLock = QuitTimeLock(unlockAt: persisted)
    }

    /// 終了ロックの解除時刻を確定する。デーモンに繋がったあとに呼ぶ。
    ///
    /// 保存値の引き継ぎ(`resumePersistedQuitLockDeadline`)で既にロックされていれば
    /// 何もしない。そうでなければ Discord の `/watch lock` の値(取れなければ既定 4 時間)
    /// で新規ロックして保存する ―― 取れないからロックしない、は「ロックできない状況を
    /// 作れば終了できる」という抜け道になってしまう。
    private func establishFreshQuitLockDeadline() async {
        guard quitTimeLock.unlockAt == nil else { return }
        var hours: Double?
        if let client = daemon.connectedClient {
            hours = try? await client.lockHours()
        }
        // lockHours を待っているあいだに別経路で確定されたら、それを尊重する。
        guard quitTimeLock.unlockAt == nil else { return }
        quitTimeLock = QuitTimeLock.resume(
            persisted: defaults.object(forKey: Self.quitLockDeadlineKey) as? Date,
            now: Date(),
            fallbackHours: hours ?? Self.defaultLockHours
        )
        defaults.set(quitTimeLock.unlockAt, forKey: Self.quitLockDeadlineKey)
    }

    /// 執行猶予脱出のメニュー項目の状態(quitLock が ON でロック中のときだけ出す)。
    public var escapeMenuState: EscapeMenuState {
        guard hasBegun, safety.isEnabled(.quitLock), !quitTimeLock.isUnlocked() else {
            return .hidden
        }
        switch escape.phase {
        case .idle:
            // 冷却中なら理由を添えただけで押せない項目にし、使えるときだけダイアログへ。
            if let remaining = EscapePolicy.cooldownRemaining(
                lastEscapeAt: safety.settings.lastEscapeAt,
                now: Date()
            ) {
                return .coolingDown(remaining: remaining)
            }
            return .available
        case .countingDown(_, let endsAt):
            return .countingDown(remaining: max(0, endsAt.timeIntervalSinceNow))
        case .readyToTerminate:
            // もう終了が始まるだけなので、メニュー項目は出さない。
            return .hidden
        }
    }

    /// 執行猶予脱出の宣言ダイアログを開く。
    public func openEscapeDialog() {
        let choices = EscapePolicy.returnDelayChoices(
            now: Date(),
            unlockAt: quitTimeLock.unlockAt
        )
        windows.showEscape {
            EscapeDialogView(
                choices: choices,
                onStart: { [weak self] delay in self?.startEscape(returnDelay: delay) },
                onCancel: { [weak self] in self?.windows.closeEscape() }
            )
        }
    }

    /// 執行猶予脱出のカウントダウンを取り消す。
    public func cancelEscape() {
        escape.cancel()
        pet.controller.say("…うん、行かないんだ。ここにいて。")
    }

    /// 執行猶予脱出を始める。宣言ダイアログを閉じ、10 分のカウントダウンに入る。
    private func startEscape(returnDelay: TimeInterval) {
        windows.closeEscape()
        escape.start(returnDelay: returnDelay, now: Date())
        pet.controller.say("…行くの? 10 分だけ、待ってる。")
    }

    /// 執行猶予脱出のコールバックを配線する。
    private func wireEscape() {
        escape.onNag = { [weak self] remaining in
            guard let self else { return }
            let minutes = EscapePolicy.durationDescription(remaining)
            guard let line = Self.escapeNagPool.randomElement() else { return }
            // 音声ファイルは用意しない。吹き出しだけ出す(読み上げない)。
            self.pet.controller.say(
                line.replacingOccurrences(of: "{minutes}", with: minutes),
                voiced: false
            )
        }
        escape.onCountdownFinished = { [weak self] record in
            guard let self else { return }
            self.finishEscape(record: record)
        }
    }

    /// カウントダウン中の引き止めセリフの候補。`{minutes}` に残り時間(「5 分」など)が入る。
    private static let escapeNagPool = [
        "あと {minutes}。まだ、いてくれる?",
        "{minutes}待ったら、ちゃんと戻ってくるよね?",
        "あと {minutes}だけ。私のところにいて。",
    ]

    /// 執行猶予脱出のカウントダウンが終わった。記録を残して終了する。
    ///
    /// 1. 記録を保存(次回起動の復帰判定と、watchdog の「宣言時刻まで起こさない」に使う)。
    /// 2. 「逃げた」を Discord に投稿(晒しが ON のとき)。
    /// 3. 終了する。watchdog とログイン項目は**解除しない** —— 宣言時刻に自動で立ち上がって
    ///    監視を再開するために使う。
    private func finishEscape(record: EscapeRecord) {
        let url = EscapeRecordStore.url()
        do {
            try EscapeRecordStore.save(record, to: url)
        } catch {
            Self.logger.error("escape の記録を保存できなかった: \(error.localizedDescription, privacy: .public)")
        }
        safety.markEscapeUsed(at: record.escapedAt)
        EscapeController.savePendingReport(record, defaults: defaults)
        // 投稿はデーモンを落とす(shutdown)前に済ませる。接続を切ってからでは届かない。
        Task { [weak self] in
            guard let self else { return }
            if self.safety.isEnabled(.discordExposure) {
                await self.discord.post(
                    text: DiscordMessageComposer.escaped(returnAt: record.returnAt),
                    image: nil,
                    mention: true,
                    using: self.daemon.connectedClient
                )
            }
            self.shutdown()
            NSApp.terminate(nil)
        }
    }

    /// 前回の執行猶予脱出からの復帰を処理する。
    ///
    /// `pendingReport` があれば、宣言どおり再起動されてきたということ。watchdog が宣言
    /// 時刻に記録を消して起こしているので、残っていればここで消す。Mac を触っている
    /// (= 無操作 60 秒以内)なら「戻ってきた」、触っていなければ「戻っていなかった」を、
    /// デーモンに繋がってから投稿する。
    private func handleEscapeReturnIfNeeded() {
        guard EscapeController.consumePendingReport(defaults: defaults) != nil else { return }
        // watchdog が宣言時刻に消しているはずだが、残っていれば(手動で立ち上げた等)消す。
        EscapeRecordStore.remove(at: EscapeRecordStore.url())
        let returned = EscapePolicy.didReturn(idleSeconds: MacIdleMonitor().idleSeconds())
        pendingEscapeReturn = returned
    }

    /// 執行猶予脱出からの復帰の投稿を、デーモンに繋がったいま送る。
    private func postEscapeReturnIfPending() {
        guard let returned = pendingEscapeReturn else { return }
        pendingEscapeReturn = nil
        guard safety.isEnabled(.discordExposure) else { return }
        Task { [discord, daemon] in
            await discord.post(
                text: returned ? DiscordMessageComposer.returned() : DiscordMessageComposer.didNotReturn(),
                image: nil,
                // 戻っていなかったときだけ呼びつける(戻ってきたなら呼ぶ必要がない)。
                mention: !returned,
                using: daemon.connectedClient
            )
        }
    }

    /// Dock のアイコンがクリックされた。
    ///
    /// - Returns: AppKit に既定の処理(ウィンドウを開き直す)を続けさせるか。
    ///   見張り始めたあとはペットを出すだけで、ウィンドウは開かない。
    public func handleReopen() -> Bool {
        guard hasBegun else { return true }
        pet.show()
        return false
    }

    /// 検証用の 10 タブ画面が要求されているか。
    private static var isDebugUIRequested: Bool {
        ProcessInfo.processInfo.environment[debugUIEnvironmentKey] == "1"
    }

    /// デバッグメニューを出すか(メニュー項目の露出制御)。
    public var isDebugMenuVisible: Bool {
        Self.isDebugUIRequested
    }

    // MARK: - ウィンドウ

    /// 権限の確認画面を出す。
    ///
    /// - Parameter canStart: まだ見張り始めていないなら true。「始める」ボタンを出す。
    ///   すでに見張っているときは押す意味がないので「閉じる」にする。
    private func showPermissionWindow(canStart: Bool) {
        windows.showPermissions {
            if canStart {
                OnboardingView(
                    model: permissions,
                    onStart: { [weak self] in
                        guard let self else { return }
                        windows.closePermissions()
                        begin()
                    }
                )
            } else {
                OnboardingView(
                    model: permissions,
                    onClose: { [weak self] in self?.windows.closePermissions() }
                )
            }
        }
    }

    private func showDebugWindow() {
        windows.showDebug { RootView(coordinator: self) }
    }

    // MARK: - PetMenuActions

    public func startWatching() {
        // 「監視を再開する」を押した相手を休憩中のまま放置しない。
        if isOnBreak { detection.endBreak() }
        detection.start()
    }

    public func stopWatching() {
        // 休憩には触れない。休憩と監視の開始 / 停止は別の話。
        detection.stop()
    }

    /// 在席スタンプを押す。ペットが指を差し出し、Touch ID に指を置いて「指を合わせる」演出にする。
    ///
    /// 演出中に押し直されても何もしない。カットインが二重に出てしまうため。
    /// 押した時点で「いま席にいる」と示されたことになるので、進んでいた疑いはここで畳む。
    public func stampAttendance() {
        detection.acknowledgePresence()
        guard !isStampCeremonyRunning else { return }
        isStampCeremonyRunning = true
        Task { [weak self] in
            guard let self else { return }
            await runCeremony(.stamp)
            isStampCeremonyRunning = false
        }
    }

    /// 疑い 1 の Touch ID チェック。在席スタンプと同じ演出を、疑い用のセリフで流す。
    ///
    /// 成功しても履歴には残さない(`verify()`)。促されて置いた指で 5 分間見逃されては
    /// チェックの意味が無い。
    private func confirmPresence(onPhone: Bool) async -> AttendanceStampOutcome {
        guard !isStampCeremonyRunning else { return .failed }
        isStampCeremonyRunning = true
        defer { isStampCeremonyRunning = false }
        return await runCeremony(.suspect(onPhone: onPhone))
    }

    /// 走っている Touch ID の演出を畳む。ダイアログを閉じ、結末を出さずにカットインも引っ込める。
    private func cancelPresenceCheck() {
        ceremonyGeneration += 1
        attendance.cancelAuthentication()
        cutIn.dismiss()
    }

    /// Touch ID の演出をひと続きで進める。
    @discardableResult
    private func runCeremony(_ variant: AttendanceCeremonyVariant) async -> AttendanceStampOutcome {
        ceremonyGeneration += 1
        let generation = ceremonyGeneration

        attendance.refreshAvailability()
        let definition = pet.controller.currentPet
        // パスワードにフォールバックする環境では「指を合わせる」が成立しないので、
        // カットインは出さずにペットの動きとセリフだけにする。
        let useCutIn = attendance.isBiometricsAvailable && (definition?.hasCutInImages ?? false)

        let opening = AttendanceCeremonyScript.opening(variant)
        pet.controller.playOnce(opening.animation)
        pet.controller.say(opening.kind)
        if useCutIn, let definition, let image = opening.cutInImage {
            cutIn.present(image, of: definition, on: pet.controller.currentScreen)
            // スライドインを見せてから認証ダイアログを出す。
            try? await Task.sleep(for: .seconds(Self.cutInLeadInSeconds))
        }

        let outcome = variant == .stamp ? await attendance.stamp() : await attendance.verify()

        // 待っているあいだに畳まれていたら、結末の演出は出さない(カットインは畳んだ側が閉じている)。
        guard generation == ceremonyGeneration else { return outcome }

        let closing = AttendanceCeremonyScript.closing(outcome, variant: variant)
        pet.controller.playOnce(closing.animation)
        pet.controller.say(closing.kind)
        guard useCutIn, let image = closing.cutInImage else { return outcome }
        cutIn.swap(to: image, flash: outcome == .stamped)
        try? await Task.sleep(for: .seconds(Self.cutInHoldSeconds))
        cutIn.dismiss()
        return outcome
    }

    public func startBreak() {
        detection.startBreak()
    }

    public func endBreak() {
        detection.endBreak()
    }

    public func openDiscordSettings() {
        windows.showDiscord { DiscordView(discord: discord, daemon: daemon) }
    }

    public func openPermissions() {
        showPermissionWindow(canStart: !hasBegun)
    }

    public func toggleStatusPanel() {
        statusPanel.toggle { statusPanelView }
        isStatusPanelVisible = statusPanel.isVisible
    }

    /// スクショへの写り込みを入れる / 切る。
    ///
    /// フラグはセーフティートグル(.photobomb)として扱う。ON の監視中はポリシーが
    /// 拒否するので、切り替え結果はメニューのチェックが次に組み立てられるときに映る。
    public func setPhotobombEnabled(_ enabled: Bool) {
        safety.request(
            enabled ? .enable(.photobomb) : .disable(.photobomb),
            isWatching: isWatchingForSafety
        )
        // メニューのチェックを描き直させる。
        objectWillChange.send()
    }

    /// ロック中は、監視していなくても「監視中」として扱う。SafetyPolicy への問い合わせに使う。
    ///
    /// ロックは監視を外すための仕掛けなので、検知を止めた状態(= 監視外)でトグルを弄って
    /// 終了ブロックごと外す抜け道を作らない(#52)。ロックが解けたらもとの判定に戻る。
    private var isWatchingForSafety: Bool {
        isWatching || (hasBegun && !quitTimeLock.isUnlocked())
    }

    /// 保存されたスクショを見張り始める。すでに見張っていれば何も起きない。
    private func startPhotobombWatching() {
        photobombWatcher.start { [weak self] url in
            Task { @MainActor [weak self] in
                await self?.photobomb.photobomb(url)
            }
        }
    }

    public var voiceMode: VoiceMode { voiceModeStore.mode }

    public func setVoiceMode(_ mode: VoiceMode) {
        voiceModeStore.set(mode)
    }

    public var focusStreakIntervalSeconds: TimeInterval {
        detection.thresholds.focusStreakIntervalSeconds
    }

    public func setFocusStreakInterval(_ seconds: TimeInterval) {
        detection.thresholds = detection.thresholds.withFocusStreakInterval(seconds)
        objectWillChange.send()
    }

    public var isFastThresholds: Bool {
        detection.thresholds == .fast
    }

    /// 検知の閾値を preset ごと差し替える。
    /// 「集中継続の間隔」で個別に変えていた値も preset の値に戻る。
    public func setFastThresholds(_ enabled: Bool) {
        detection.thresholds = enabled ? .fast : .standard
        objectWillChange.send()
    }

    public func replayFocusStreak() {
        pet.sayFocusStreak()
    }

    public func runDetectionStep(_ step: DetectionDebugStep) {
        detection.runDebugStep(step)
    }

    /// 説教オーバーレイを組み立てる。セリフの取得と読み上げの停止はこのアプリのものを渡す。
    private func makeOverlay() -> OverlayModel {
        let voice = self.voice
        let daemon = self.daemon
        let modes = self.voiceModeStore
        let player = self.speechPlayer
        return OverlayModel(
            presenter: ScreenSaverOverlayPresenter(),
            speak: { request in
                // 同封音声のときは bridge に作らせず、同封の説教から 1 本選んでその場で鳴らす。
                if modes.mode == .bundled {
                    guard let sermon = BundledVoiceLines.shared.pick(.sermon) else { return nil }
                    if let audio = sermon.audio { player.play(audio: audio, priority: .detection) }
                    return sermon.text
                }
                return await voice.speak(request, using: daemon.connectedClient)
            },
            stopSpeaking: { [weak voice] in voice?.stopSpeaking() },
            // トグルが OFF なら音楽停止も含めて何もしない(検知側には知らせない)。
            gate: safety.gate
        )
    }

    /// 状態パネルの中身。エンジンとデーモンの `@Published` をそのまま映す。
    private var statusPanelView: StatusPanelView {
        StatusPanelView(engine: detection, daemon: daemon)
    }

    // MARK: - 配線

    /// 検知エンジンの実行部に、実際の機能を配線する。
    ///
    /// どの実行部も「失敗したら諦めて次へ」に倒してある。カメラが使えない、
    /// VOICEVOX が起動していない、Discord のトークンが無い、はどれも起こりうる。
    /// 1 つ転んだせいで見張りが死ぬのが一番まずい。
    private func wireDetection() {
        // セーフティートグル(.macCamera)の OFF は撮影の先頭で弾かれる。
        let capture = CaptureService(camera: CameraCaptureService(gate: safety.gate))
        detection.actions = DetectionEngine.Actions(
            captureMacPhoto: { await Self.photoData(from: capture) },
            captureIPhoneScreenshot: { [daemon] in
                try? await daemon.connectedClient?.iphoneScreenshot()
            },
            speak: { [voice, daemon] request in
                // 音声はここでは鳴らさない。吹き出しが出る瞬間に鳴らせるよう、ペットまで運ぶ。
                guard let line = await voice.fetchLine(request, using: daemon.connectedClient) else {
                    return nil
                }
                return SpokenSpeech(text: line.text, audio: line.audioData, screen: line.screen)
            },
            readScreen: { [daemon] request in
                guard let client = await daemon.connectedClient else { return nil }
                return try? await client.readScreen(request)
            },
            interrupt: { [overlay] request in
                await MainActor.run { overlay.show(request: request) }
            },
            post: { [discord, daemon] text, image, filename, mention in
                await discord.post(
                    text: text,
                    image: image,
                    filename: filename,
                    mention: mention,
                    using: daemon.connectedClient
                )
            },
            classify: { data in
                Self.visionLabel(for: data)
            },
            askHeadGesture: { [questioner] question, answerWindow in
                await questioner.ask(prompt: question, answerWindow: answerWindow)
            },
            confirmPresence: { [weak self] onPhone in
                guard let self else { return .unavailable }
                return await self.confirmPresence(onPhone: onPhone)
            },
            cancelPresenceCheck: { [weak self] in
                await MainActor.run { self?.cancelPresenceCheck() }
            }
        )
        detection.onEvent = { [pet] event in
            pet.present(event)
        }
        detection.onPromptDismissed = { [pet] in
            pet.dismissPrompt()
        }
        detection.onFocusStreak = { [pet] in
            pet.sayFocusStreak()
        }
    }

    /// 監視の状態をペットとメニューに映す。
    private func observeDetection() {
        detection.$isWatching
            .combineLatest(detection.$breakUntil)
            .sink { [weak self] isWatching, breakUntil in
                MainActor.assumeIsolated {
                    self?.applyMonitoring(isWatching: isWatching, breakUntil: breakUntil)
                }
            }
            .store(in: &cancellables)
    }

    private func applyMonitoring(isWatching: Bool, breakUntil: Date?) {
        let onBreak = breakUntil.map { Date() < $0 } ?? false
        self.isWatching = isWatching
        self.isOnBreak = onBreak

        if onBreak {
            pet.setMonitoring(.onBreak)
        } else if isWatching {
            pet.setMonitoring(.watching)
        } else {
            pet.setMonitoring(.paused)
        }
    }

    /// SSE で届いたイベントを検知エンジンに反映する。
    ///
    /// `@Published` の通知は値が入る**前**に来るので、`daemon.events` を読み直さず
    /// 流れてきた値をそのまま使う。
    private func observeDaemonEvents() {
        daemon.$events
            .compactMap(\.first)
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
            .store(in: &cancellables)
    }

    private func handle(_ event: DaemonEvent) {
        switch event.name {
        case "iphone.state":
            applyIPhoneState(event)
        case "watch.start":
            // Discord の /watch から始めた場合。すでに見張っていれば何も起きない。
            detection.start()
        case "watch.stop":
            detection.stop()
        default:
            break
        }
    }

    /// セーフティートグルの変化を、実行部とデーモンへ配る。
    private func observeSafety() {
        // photobomb が ON になったら写り込みの見張りを始め、OFF になったら止める。
        // `begin()` は自分で一度 `startPhotobombWatching()` を呼ぶので、ここで拾うのは
        // 始めたあとの変化だけ。
        safety.$settings
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if settings.isEnabled(.photobomb) {
                        guard self.hasBegun else { return }
                        self.startPhotobombWatching()
                    } else {
                        self.photobombWatcher.stop()
                    }
                }
            }
            .store(in: &cancellables)

        // トグルの変化をデーモンへ伝える。初回の配信は現在値で、begin() が明示的に
        // 送るぶんと重なるので落とす。
        safety.$settings
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pushSafetyToDaemon()
                }
            }
            .store(in: &cancellables)

        // quitLock の ON/OFF に合わせて、終了ブロックの仕掛けを入れ / 解く。
        // ON→OFF はロック中には起きない(SafetyPolicy が弾く)。begin() 自身も
        // applyQuitLockPolicy() を呼んでいるので、初回の配信は状態を覚えるだけ。
        safety.$settings
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let isOn = settings.isEnabled(.quitLock)
                    guard let previous = self.quitLockPolicyState else {
                        self.quitLockPolicyState = isOn
                        return
                    }
                    guard previous != isOn else { return }
                    self.quitLockPolicyState = isOn
                    self.applyQuitLockPolicy()
                    if isOn {
                        // デーモンは起動済みなので、そのまま解除時刻を確定できる。
                        Task { await self.establishFreshQuitLockDeadline() }
                    }
                }
            }
            .store(in: &cancellables)

        // デーモン(SSE)の接続が回復したときにも再送する。接続はデーモンの再起動の
        // たびに切れて張り直されるので、その間に変わった設定を取り戻す。
        daemon.$isStreamConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pushSafetyToDaemon()
                }
            }
            .store(in: &cancellables)
    }

    /// いまのセーフティートグルをデーモンへ伝える。
    ///
    /// サーバ側の受信は #50 で実装される。まだ実装されていなくても失敗するだけで、
    /// 送る側は握りつぶして続ける(次に設定が変わるか接続が戻ったときに再送される)。
    /// 失敗の理由だけはログに残す。
    private func pushSafetyToDaemon() {
        let client = daemon.connectedClient
        let payload = safety.daemonPayload
        Task {
            do {
                try await client?.updateSafety(payload)
            } catch {
                Self.logger.error(
                    "セーフティー設定をデーモンに送れなかった: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func applyIPhoneState(_ event: DaemonEvent) {
        guard let raw = event.payload["activity"] else { return }
        switch raw {
        case "active": detection.iphoneState = .active
        case "idle": detection.iphoneState = .idle
        // Python 側は状態取得を "unresponsive"、セリフ生成を "unreachable" と呼んでいる。
        // どちらも「iPhone から返事が無い」で、Swift では同じ 1 つの値に寄せる。
        default: detection.iphoneState = .unreachable
        }
        // 触っていないときの「前に開いていたアプリ」は古い情報でしかない。持ち越さない。
        guard raw == "active" else {
            detection.iphoneForegroundApp = nil
            return
        }
        detection.iphoneForegroundApp =
            Self.payloadText(event.payload["foreground_app_name"])
            ?? Self.payloadText(event.payload["foreground_bundle_id"])
    }

    /// payload の文字列から「中身のある値」だけを取り出す。
    ///
    /// `DaemonEvent` は payload を表示用の文字列に潰すので、JSON の null は `"null"` という
    /// 文字列で届く。空文字と併せて、無かったことにする。
    private static func payloadText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }
        return trimmed
    }

    // Vision の解析は画面の都合と無関係なので、メインアクタから外して実行する。
    nonisolated private static func photoData(from capture: CaptureService) async -> Data? {
        guard let artifact = try? await capture.capturePhoto() else { return nil }
        let data = try? Data(contentsOf: artifact.url)
        // 送信のあとに残す理由がない。読み終えたらすぐ消す。
        try? artifact.delete()
        return data
    }

    nonisolated private static func visionLabel(for data: Data) -> SpeechRequest.VisionLabel {
        guard let image = try? CaptureImageCodec.decode(data) else { return .unknown }
        return VisionLabelClassifier.classify(outcome: FaceVisionAnalyzer.analyze(image))
    }
}
