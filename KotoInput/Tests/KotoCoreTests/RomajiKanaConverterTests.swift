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
        #expect(RomajiKanaConverter.normalize("kon'") == "こん")
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
    }

    @Test("文末の句読点に隣接していても変換する")
    func sentencePunctuationAllowed() {
        #expect(RomajiKanaConverter.normalize("abunai.") == "あぶない.")
        #expect(RomajiKanaConverter.normalize("hai, sou desu") == "はい, そう です")
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
