import SwiftUI

/// Discord Bot の設定と、投稿の確認画面。
public struct DiscordView: View {
    @ObservedObject var discord: DiscordController
    @ObservedObject var daemon: DaemonController

    @State private var scheduleTime = "19:00"
    @State private var testMessage = "テスト投稿です。"
    /// 呼びつける相手の Discord ユーザー ID。数字だけを受け付ける。
    @State private var mentionUserID = ""
    /// `discord.status` から ID を書き戻したか。手で編集した内容を上書きしないため 1 回だけにする。
    @State private var hasLoadedMention = false

    /// 認証情報の入力欄。保存したら空に戻す。保存済みの値は読み戻さない。
    @State private var clientIDInput = ""
    @State private var botTokenInput = ""
    @State private var geminiKeyInput = ""
    /// `.env` に値が入っているキー。画面に出すのは「設定済みかどうか」だけにする。
    @State private var configuredKeys: Set<EnvFileStore.Key> = []
    @State private var credentialNotice: String?
    @State private var credentialError: String?

    /// 認証情報の置き場所。既定は `~/.mihari/.env`。
    private let credentials = EnvFileStore()

    public init(discord: DiscordController, daemon: DaemonController) {
        self.discord = discord
        self.daemon = daemon
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                setupSteps
                credentialsSection
                channelSection
                mentionSection
                scheduleSection
                postSection
                if let notice = discord.lastNotice {
                    noticeBox(notice)
                }
                if let error = discord.lastError {
                    errorBox(error)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            configuredKeys = credentials.configuredKeys()
            await discord.refresh(using: daemon.connectedClient)
        }
        .onChange(of: discord.status?.mentionUserID) { _, saved in
            guard !hasLoadedMention else { return }
            hasLoadedMention = true
            mentionUserID = saved ?? ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Discord").font(.title2).bold()
            Text("証拠の投稿も、監視の指示も Discord Bot 経由で行う。Bot は Mac の上で動くので、Mac が落ちている間はコマンドが効かない。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status = discord.status {
                Label(
                    status.summary,
                    systemImage: status.isReadyToPost ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(status.isReadyToPost ? Color.green : Color.orange)
            } else {
                Label("状態を取得できていない", systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("状態を取り直す") { Task { await discord.refresh(using: daemon.connectedClient) } }
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("セットアップ").font(.headline)
            step(1, "Discord Developer Portal でアプリを作る", done: discord.status?.clientIDConfigured == true)
            step(2, "APPLICATION ID と Bot トークンを下の「認証情報」に入れる", done: discord.status?.tokenConfigured == true)
            step(3, "招待 URL から自分のサーバに Bot を入れる", done: discord.status?.botReady == true)
            step(4, "投稿先チャンネルを選ぶ", done: discord.status?.selection != nil)

            HStack(spacing: 10) {
                Button("招待 URL を開く") { discord.openInvite() }
                    .disabled(discord.status?.inviteURL == nil)
                if let missing = discord.status?.missing, !missing.isEmpty {
                    Text("\(missing.joined(separator: " / ")) が未設定")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func step(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(text).font(.callout).foregroundStyle(done ? .secondary : .primary)
            Spacer()
        }
    }

    /// bridge が使う認証情報。値は `~/.mihari/.env` に置き、画面には出さない。
    ///
    /// 配布物にトークンは同梱できないので、各自が自分の Bot と API キーをここに入れる。
    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("認証情報").font(.headline)
            Text(
                "自分で用意した Bot トークンと API キーを入れる。保存先は \(credentials.url.path)"
                    + "(本人だけが読める権限で書く)。入れた値は画面に出さないので、"
                    + "変えるときだけ入力する。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            credentialRow(
                .discordClientID,
                text: $clientIDInput,
                secure: false,
                hint: "Developer Portal →「General Information」の APPLICATION ID"
            )
            credentialRow(
                .discordBotToken,
                text: $botTokenInput,
                secure: true,
                hint: "Developer Portal →「Bot」タブの Reset Token で発行する"
            )
            credentialRow(
                .geminiAPIKey,
                text: $geminiKeyInput,
                secure: true,
                hint: "Google AI Studio で発行する。未設定でも動く(iPhone の画面を読まなくなる)"
            )

            HStack(spacing: 10) {
                Button("保存してデーモンを再起動") { Task { await saveCredentials() } }
                    .disabled(!hasCredentialInput)
                Spacer()
            }

            if let notice = credentialNotice {
                noticeBox(notice)
            }
            if let error = credentialError {
                errorBox(error)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func credentialRow(
        _ key: EnvFileStore.Key,
        text: Binding<String>,
        secure: Bool,
        hint: String
    ) -> some View {
        let isConfigured = configuredKeys.contains(key)
        let placeholder = isConfigured ? "設定済み" : "未設定"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(key.label)
                    .font(.callout)
                    .frame(width: 130, alignment: .leading)
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
                Label(
                    placeholder,
                    systemImage: isConfigured ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(.caption)
                .foregroundStyle(isConfigured ? Color.green : Color.secondary)
                .frame(width: 80, alignment: .leading)
                Button("削除") { Task { await removeCredential(key) } }
                    .controlSize(.small)
                    .disabled(!isConfigured)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 入力欄に何か入っているか。空のまま保存しても変わるものが無いので、そのときは押せない。
    private var hasCredentialInput: Bool {
        [clientIDInput, botTokenInput, geminiKeyInput]
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 入力済みのフィールドだけを書く。空のフィールドは触らない(消すのは「削除」)。
    private func saveCredentials() async {
        do {
            try credentials.save([
                .discordClientID: clientIDInput,
                .discordBotToken: botTokenInput,
                .geminiAPIKey: geminiKeyInput,
            ])
        } catch {
            credentialNotice = nil
            credentialError = error.localizedDescription
            return
        }
        clientIDInput = ""
        botTokenInput = ""
        geminiKeyInput = ""
        await applyCredentialChange(notice: "保存してデーモンを再起動した")
    }

    private func removeCredential(_ key: EnvFileStore.Key) async {
        do {
            try credentials.remove([key])
        } catch {
            credentialNotice = nil
            credentialError = error.localizedDescription
            return
        }
        await applyCredentialChange(notice: "\(key.label) を削除してデーモンを再起動した")
    }

    /// 書き換えたあとの後始末。デーモンを入れ直して、新しいトークンで Discord につなぎ直す。
    private func applyCredentialChange(notice: String) async {
        credentialError = nil
        credentialNotice = nil
        configuredKeys = credentials.configuredKeys()
        await daemon.restart()
        credentialNotice = notice
        await discord.refresh(using: daemon.connectedClient)
    }

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("投稿先").font(.headline)
                Spacer()
                Button("チャンネルを探す") { Task { await discord.refreshChannels(using: daemon.connectedClient) } }
                    .controlSize(.small)
                    .disabled(discord.status?.botReady != true)
            }

            if let selected = discord.status?.selection {
                Label(selected.displayName, systemImage: "number")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if discord.channels.isEmpty {
                Text("まだ探していない。Bot をサーバに入れてから「チャンネルを探す」を押す。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discord.channels) { channel in
                    HStack {
                        Text(channel.displayName).font(.callout)
                        Spacer()
                        Button("ここに送る") {
                            Task { await discord.select(channel, using: daemon.connectedClient) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 証拠を晒すときに呼びつける相手。本文の先頭に付く `<@ID>` は bridge が足す。
    private var mentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("メンション先").font(.headline)
            HStack(spacing: 10) {
                TextField("ユーザー ID(数字だけ)", text: $mentionUserID)
                    .frame(width: 220)
                Button("保存") {
                    Task { await discord.setMention(mentionUserID, using: daemon.connectedClient) }
                }
                .disabled(!isMentionInputValid)
                Button("テスト投稿") {
                    Task { await discord.postTest(using: daemon.connectedClient) }
                }
                .disabled(discord.status?.isReadyToPost != true)
                Spacer()
            }
            if !isMentionInputValid {
                Text("数字だけを入れる。空にして保存するとメンションを外す。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(
                "ID の調べ方: Discord の 設定 → 詳細設定 → 開発者モードを ON → "
                    + "自分のアイコンを右クリック →「ユーザー ID をコピー」。"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 空(＝メンションを外す)か、数字だけなら保存できる。
    private var isMentionInputValid: Bool {
        let trimmed = mentionUserID.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.allSatisfy(\.isNumber)
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("監視の予約").font(.headline)
            Text(discord.status?.schedule.summary ?? "不明")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("HH:MM", text: $scheduleTime).frame(width: 90)
                Button("この時刻から") { Task { await discord.setSchedule(at: scheduleTime, using: daemon.connectedClient) } }
                Button("いますぐ") { Task { await discord.setSchedule(at: nil, using: daemon.connectedClient) } }
                Spacer()
            }
            Text("Discord からは /watch start · /watch at HH:MM · /watch stop · /watch status で操作できる。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var postSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("テスト投稿").font(.headline)
            HStack(spacing: 10) {
                TextField("送る文面", text: $testMessage)
                Button("送る") {
                    Task { await discord.post(text: testMessage, using: daemon.connectedClient) }
                }
                .disabled(discord.status?.isReadyToPost != true)
            }
            if let id = discord.lastPostedMessageID {
                Text("送信済み (message id: \(id))").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func noticeBox(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.green)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
