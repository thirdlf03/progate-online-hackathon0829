import Foundation
import Testing

@testable import MihariCore

@Suite("Discord の文面")
struct DiscordMessageTests {

    private func facts(
        evidence: EvidenceKind = .iphoneScreenshot,
        vision: SpeechRequest.VisionLabel = .unknown,
        iphone: SpeechRequest.IPhoneState = .active,
        screen: SpokenLine.ScreenReading? = nil,
        notLookingSeconds: TimeInterval? = nil,
        macIdleSeconds: TimeInterval = 300,
        musicPlayer: String? = nil,
        frontmostApp: String? = nil
    ) -> DiscordMessageFacts {
        DiscordMessageFacts(
            evidence: evidence,
            vision: vision,
            iphone: iphone,
            screen: screen,
            notLookingSeconds: notLookingSeconds,
            macIdleSeconds: macIdleSeconds,
            musicPlayer: musicPlayer,
            frontmostApp: frontmostApp
        )
    }

    private func compose(_ facts: DiscordMessageFacts, seed: UInt64 = 1) -> String {
        var generator = SeededGenerator(seed: seed)
        return DiscordMessageComposer.compose(facts, using: &generator)
    }

    @Test("同じ種なら同じ文面になる")
    func sameSeedGivesSameMessage() {
        let facts = facts(screen: .init(app: "YouTube", activity: "動画を見ている", category: "slacking"))

        #expect(compose(facts, seed: 42) == compose(facts, seed: 42))
    }

    @Test("2 行目は Discord の小文字表示にする")
    func subtextIsPrefixed() {
        let message = compose(facts())
        let lines = message.components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("-# "))
    }

    @Test("差し込みの穴が残らない")
    func everyPlaceholderIsFilled() {
        // 種を変えるとプールの引きが変わるので、どの組み合わせでも埋まっているかを見る。
        for seed in UInt64(0)..<32 {
            let message = compose(
                facts(
                    screen: .init(app: "X", activity: "眺めている", category: "slacking"),
                    notLookingSeconds: 30,
                    musicPlayer: "Spotify",
                    frontmostApp: "Slack"
                ),
                seed: seed
            )
            #expect(!message.contains("{"))
        }
    }

    @Test("画面を読めていれば、アプリ名と中身に触れる")
    func headlineMentionsTheScreen() {
        for seed in UInt64(0)..<16 {
            let message = compose(
                facts(screen: .init(app: "YouTube", activity: "動画を見ている", category: "slacking")),
                seed: seed
            )
            #expect(message.contains("YouTube"))
            #expect(message.contains("動画を見ている"))
        }
    }

    @Test("アプリ名が分からなければ画面の中身には触れない")
    func headlineStaysVagueWithoutAnApp() {
        let unknown = [
            "画面、暗くて読めなかった。でもスマホ握ってたのは分かってる。",
            "何見てたか言えないなら、それでいいよ。撮ったから。",
        ]
        for seed in UInt64(0)..<16 {
            let message = compose(
                facts(screen: .init(app: nil, activity: "分からない", category: "slacking")),
                seed: seed
            )
            #expect(unknown.contains { message.contains($0) })
            #expect(!message.contains("分からない"))
        }
    }

    @Test("画面を読ませていなければ、撮ったことだけを言う")
    func headlineFallsBackWhenTheScreenWasNotRead() {
        let unread = [
            "スマホの画面、撮っておいたから。逃げられると思った?",
            "今スマホ見てたよね。証拠、ここに置いとくね。",
            "私より画面が大事なんだ。…いいよ、みんなに見せるから。",
        ]
        for seed in UInt64(0)..<16 {
            let message = compose(facts(screen: nil), seed: seed)
            #expect(unread.contains { message.contains($0) })
        }
    }

    @Test("カメラで撮ったときは見立てで 1 行目が変わる")
    func cameraHeadlineFollowsTheVisionLabel() {
        let sleeping = ["寝てるよね。寝顔、撮っちゃった。", "私を置いて寝るんだ。記録しとくね。"]
        let absent = ["どこ行ったの。席、空っぽだよ。", "いなくなった。探すの、私じゃなくてみんなに頼むね。"]
        let other = ["顔、見えてるよ。今なにしてたの?", "手が止まってる。こっち向いて。"]

        for seed in UInt64(0)..<16 {
            let asleep = compose(facts(evidence: .macCamera, vision: .sleeping, iphone: .idle), seed: seed)
            #expect(sleeping.contains { asleep.contains($0) })

            let away = compose(facts(evidence: .macCamera, vision: .absent, iphone: .idle), seed: seed)
            #expect(absent.contains { away.contains($0) })

            let looking = compose(facts(evidence: .macCamera, vision: .lookingAway, iphone: .idle), seed: seed)
            #expect(other.contains { looking.contains($0) })
        }
    }

    @Test("証拠を撮らない設定なら、1 行目は noEvidencePool から選ばれる")
    func noEvidenceHeadlineComesFromItsOwnPool() {
        let pool = [
            "写真も画面も撮らない設定にしてるんだね。でも、サボってたのは分かってる。",
            "撮らないでって頼まれたから撮らないよ。その代わり、ずっと待ってたことはみんなに言うね。",
            "証拠は残さない約束にしてるんだった。それでも、私が数えてた時間は消えないよ。",
            "カメラもスマホも使わないでいても、気づかないと思った?手が止まってたんだよ。",
        ]
        for seed in UInt64(0)..<16 {
            let message = compose(facts(evidence: .none, iphone: .unreachable), seed: seed)
            #expect(pool.contains { message.contains($0) })
        }
    }

    @Test("2 行目には、当てはまる事実だけを並べる")
    func subtextListsOnlyWhatApplies() {
        let message = compose(
            facts(
                screen: .init(app: "YouTube", activity: "動画を見ている", category: "slacking"),
                notLookingSeconds: nil,
                macIdleSeconds: 300,
                musicPlayer: nil,
                frontmostApp: nil
            )
        )

        // 無操作は常に入る。300 秒 = 5 分。
        #expect(message.contains("5分"))
        // 目を離した秒数・音楽・直前のアプリは、材料が無ければ出さない。
        #expect(!message.contains("目を離してた"))
        #expect(!message.contains("見てなかったね"))
        #expect(!message.contains("流したまま"))
        #expect(!message.contains("最後に開いてたの"))
    }

    @Test("材料が揃っていれば、全部 2 行目に並ぶ")
    func subtextCarriesEveryFact() {
        let actives = ["その間ずっとスマホ握ってたんでしょ。", "代わりにスマホは忙しかったみたいだね。"]
        for seed in UInt64(0)..<16 {
            let message = compose(
                facts(
                    screen: nil,
                    notLookingSeconds: 30,
                    macIdleSeconds: 300,
                    musicPlayer: "Spotify",
                    frontmostApp: "Slack"
                ),
                seed: seed
            )
            #expect(message.contains("30秒"))
            #expect(message.contains("5分"))
            #expect(actives.contains { message.contains($0) })
            #expect(message.contains("Spotify"))
            #expect(message.contains("Slack"))
        }
    }

    @Test("iPhone の様子ごとに言い方が変わる")
    func subtextFollowsThePhoneState() {
        let idle = ["スマホは置いたままだったね。じゃあ何してたの?", "スマホも触ってない。…どこ見てたの。"]
        let unreachable = ["スマホ、返事しなかったね。隠した?", "スマホの様子が分からなかった。持ち出した?"]

        for seed in UInt64(0)..<16 {
            let quiet = compose(facts(evidence: .macCamera, iphone: .idle), seed: seed)
            #expect(idle.contains { quiet.contains($0) })

            let gone = compose(facts(evidence: .macCamera, iphone: .unreachable), seed: seed)
            #expect(unreachable.contains { gone.contains($0) })
        }
    }

    @Test("メンションは含めない")
    func messageCarriesNoMention() {
        // `<@ID>` を先頭に足すのは bridge 側。二重に付けない。
        for seed in UInt64(0)..<16 {
            let message = compose(
                facts(screen: .init(app: "YouTube", activity: "動画を見ている", category: "work")),
                seed: seed
            )
            #expect(!message.contains("<@"))
        }
    }

    // MARK: - 執行猶予脱出 (#52)

    @Test("逃げた投稿は 逃げたプール + 戻ると宣言の副文になる")
    func escapedMessageHasReturnDeclaration() {
        var generator = SeededGenerator(seed: 7)
        let now = Date(timeIntervalSince1970: 0)

        let message = DiscordMessageComposer.escaped(
            returnAt: now.addingTimeInterval(90 * 60),
            now: now,
            using: &generator
        )

        // 2 行目は小文字表示で、「N 時間 M 分後(HH:mm)に戻ると宣言」を添える。
        let lines = message.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("-# "))
        #expect(message.contains("分後("))
        #expect(message.hasSuffix("に戻ると宣言。"))
    }

    @Test("戻ってきた投稿と戻っていなかった投稿はそれぞれ文面になる")
    func returnMessagesAreSentences() {
        #expect(DiscordMessageComposer.returned().hasSuffix("。"))
        #expect(DiscordMessageComposer.didNotReturn().hasSuffix("。"))
        // 意味が逆なので、同じ文面にはならない。
        #expect(DiscordMessageComposer.returned() != DiscordMessageComposer.didNotReturn())
    }
}
