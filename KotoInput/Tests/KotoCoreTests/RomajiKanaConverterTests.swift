import KotoCore
import Testing

@Suite("RomajiKanaConverter の決定論かな変換")
struct RomajiKanaConverterTests {
    @Test("基本のローマ字文をひらがな化する")
    func basicSentence() {
        #expect(RomajiKanaConverter.normalize("kyou ha ame") == "きょう は あめ")
    }

    @Test("促音を子音の重ねから変換する")
    func sokuon() {
        #expect(RomajiKanaConverter.normalize("gakkou") == "がっこう")
        #expect(RomajiKanaConverter.normalize("kitte") == "きって")
        #expect(RomajiKanaConverter.normalize("matcha") == "まっちゃ")
    }

    @Test("撥音の文脈判定（末尾・子音前・n'・nn・ヘボン式 m）")
    func hatsuon() {
        #expect(RomajiKanaConverter.normalize("mikan") == "みかん")
        #expect(RomajiKanaConverter.normalize("kanji") == "かんじ")
        #expect(RomajiKanaConverter.normalize("kon'ya") == "こんや")
        #expect(RomajiKanaConverter.normalize("konnichiha") == "こんにちは")
        #expect(RomajiKanaConverter.normalize("han'i") == "はんい")
        #expect(RomajiKanaConverter.normalize("shimbun") == "しんぶん")
        #expect(RomajiKanaConverter.normalize("annai") == "あんない")
    }

    @Test("小書きと長音を変換する")
    func smallKanaAndChouon() {
        #expect(RomajiKanaConverter.normalize("xtu") == "っ")
        #expect(RomajiKanaConverter.normalize("dexi") == "でぃ")
        #expect(RomajiKanaConverter.normalize("ko-hi-") == "こーひー")
    }

    @Test("2 つ目の n が次の音節の頭になるケースを正しく分割する")
    func doubleNFollowedBySyllable() {
        #expect(RomajiKanaConverter.normalize("onna") == "おんな")
        #expect(RomajiKanaConverter.normalize("konnyaku") == "こんにゃく")
        #expect(RomajiKanaConverter.normalize("nn") == "ん")
        #expect(RomajiKanaConverter.normalize("nnn") == "んん")
    }

    @Test("音節区切りのアポストロフィを対称に扱う（zen'in / zenn'in）")
    func apostropheSeparatorSymmetry() {
        #expect(RomajiKanaConverter.normalize("zen'in") == "ぜんいん")
        #expect(RomajiKanaConverter.normalize("zenn'in") == "ぜんいん")
        #expect(RomajiKanaConverter.normalize("kin'yuu") == "きんゆう")
    }

    @Test("撥音の区切り以外のアポストロフィを含む語は原文を維持する")
    func apostropheOutsideHatsuonPreserved() {
        #expect(RomajiKanaConverter.normalize("goin'") == "goin'")
        #expect(RomajiKanaConverter.normalize("hon'") == "hon'")
        #expect(RomajiKanaConverter.normalize("kon'") == "kon'")
        #expect(RomajiKanaConverter.normalize("zenn'") == "zenn'")
        #expect(RomajiKanaConverter.normalize("ka'ki") == "ka'ki")
    }

    @Test("外来音 dhu / dhi を変換する")
    func foreignSyllables() {
        #expect(RomajiKanaConverter.normalize("dhu") == "でゅ")
        #expect(RomajiKanaConverter.normalize("dhi") == "でぃ")
    }

    @Test("保護語はかな化から除外される")
    func protectedTermsExcluded() {
        #expect(
            RomajiKanaConverter.normalize("tamago wo taberu", protecting: ["tamago"])
                == "tamago を たべる"
        )
        #expect(
            RomajiKanaConverter.normalize("kyou ha ame", protecting: [])
                == "きょう は あめ"
        )
    }

    @Test("保護語は語境界で照合し、語の途中の部分一致では保護しない")
    func protectedTermsRespectWordBoundaries() {
        #expect(RomajiKanaConverter.normalize("tabun", protecting: ["bun"]) == "たぶん")
        #expect(RomajiKanaConverter.normalize("kotoba", protecting: ["koto"]) == "ことば")
        #expect(RomajiKanaConverter.normalize("shibunka", protecting: ["bun"]) == "しぶんか")
        // 保護されなくても大文字を含む語は原文維持の安全規則に落ちる。
        #expect(RomajiKanaConverter.normalize("Codeo", protecting: ["Code"]) == "Codeo")
    }

    @Test("句読点が後続する保護語も語境界として保護する")
    func protectedTermFollowedByPunctuation() {
        #expect(RomajiKanaConverter.normalize("sudo,", protecting: ["sudo"]) == "sudo,")
        #expect(
            RomajiKanaConverter.normalize("sudo, jikkou", protecting: ["sudo"])
                == "sudo, じっこう"
        )
    }

    @Test("複数語フレーズの保護語は出現箇所全体を保護する")
    func multiWordProtectedPhrase() {
        #expect(
            RomajiKanaConverter.normalize("bun run wo tukau", protecting: ["bun run"])
                == "bun run を つかう"
        )
        #expect(RomajiKanaConverter.normalize("bun run wo tukau") == "ぶん るん を つかう")
    }

    @Test("同じ位置に重なる保護語は長い候補を優先する")
    func longerProtectedTermWins() {
        #expect(
            RomajiKanaConverter.normalize(
                "Claude Code de naosu",
                protecting: ["Claude", "Claude Code"]
            ) == "Claude Code で なおす"
        )
    }

    @Test("保護語の前後空白は trim し、空白のみの保護語は無視する")
    func protectedTermsAreSanitized() {
        #expect(
            RomajiKanaConverter.normalize("make wo tukau", protecting: [" make ", "  ", ""])
                == "make を つかう"
        )
    }

    @Test("ローマ字として解釈できない英単語はそのまま残す")
    func englishWordsPreserved() {
        #expect(
            RomajiKanaConverter.normalize("kono application layer dake de check suru")
                == "この application layer だけ で check する"
        )
    }

    @Test("大文字を含む単語（固有名詞）はそのまま残す")
    func uppercaseWordsPreserved() {
        #expect(RomajiKanaConverter.normalize("Claude Code de naosu") == "Claude Code で なおす")
    }

    @Test("パス・識別子に隣接する単語は変換しない")
    func pathsAndIdentifiersPreserved() {
        #expect(RomajiKanaConverter.normalize("scripts/foo.sh wo naosu") == "scripts/foo.sh を なおす")
        #expect(RomajiKanaConverter.normalize("user_id") == "user_id")
        #expect(RomajiKanaConverter.normalize("a.out") == "a.out")
        #expect(RomajiKanaConverter.normalize("node.js") == "node.js")
        #expect(RomajiKanaConverter.normalize("file.txt") == "file.txt")
        #expect(
            RomajiKanaConverter.normalize("./scripts/foo.sh wo jikkou")
                == "./scripts/foo.sh を じっこう"
        )
    }

    @Test("かな化した語に隣接する語末・語間の . , は 。、 へ変換する")
    func sentencePunctuationAllowed() {
        #expect(RomajiKanaConverter.normalize("abunai.") == "あぶない。")
        #expect(RomajiKanaConverter.normalize("soudesu.") == "そうです。")
        #expect(RomajiKanaConverter.normalize("hai,soudesu.") == "はい、そうです。")
        #expect(RomajiKanaConverter.normalize("hai, sou desu") == "はい、 そう です")
        // かな化されない語に隣接する句読点は原文のまま残す。
        #expect(RomajiKanaConverter.normalize("check, please") == "check, please")
        // 。、へ変換できない記号は変換せずに残す。
        #expect(RomajiKanaConverter.normalize("kyou; ashita") == "きょう; あした")
    }

    @Test("行頭の Markdown マーカーを壊さない")
    func markdownMarkerPreserved() {
        #expect(RomajiKanaConverter.normalize("- kyou no task") == "- きょう の task")
    }

    @Test("アポストロフィ付き英単語（don't 等）はそのまま残す")
    func apostropheEnglishPreserved() {
        #expect(RomajiKanaConverter.normalize("don't") == "don't")
    }

    @Test("既にひらがな・漢字のテキストは変化しない（冪等）")
    func idempotentOnJapanese() {
        let text = "きょうは雨です。"
        #expect(RomajiKanaConverter.normalize(text) == text)
    }
}
