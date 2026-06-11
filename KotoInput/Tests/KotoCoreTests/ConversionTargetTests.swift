import KotoCore
import Testing

@Suite("ConversionTarget の言語キー解決と言語名")
struct ConversionTargetTests {
    @Test(
        "言語キーから対応するターゲットを解決する",
        arguments: [
            (Character("e"), ConversionTarget.english),
            (Character("c"), ConversionTarget.chineseSimplified),
            (Character("k"), ConversionTarget.korean),
            (Character("f"), ConversionTarget.french),
            (Character("g"), ConversionTarget.german),
            (Character("s"), ConversionTarget.spanish),
        ]
    )
    func resolvesLanguageKey(key: Character, expected: ConversionTarget) {
        #expect(ConversionTarget(languageKey: key) == expected)
    }

    @Test("大文字の言語キーも同じターゲットへ解決する（Shift 併用で大文字が届く）")
    func resolvesUppercaseLanguageKey() {
        #expect(ConversionTarget(languageKey: "E") == .english)
        #expect(ConversionTarget(languageKey: "C") == .chineseSimplified)
        #expect(ConversionTarget(languageKey: "K") == .korean)
        #expect(ConversionTarget(languageKey: "F") == .french)
        #expect(ConversionTarget(languageKey: "G") == .german)
        #expect(ConversionTarget(languageKey: "S") == .spanish)
    }

    @Test("未知の文字は言語キーとして解決しない")
    func unknownLanguageKeyReturnsNil() {
        #expect(ConversionTarget(languageKey: "x") == nil)
        #expect(ConversionTarget(languageKey: "1") == nil)
        #expect(ConversionTarget(languageKey: " ") == nil)
        #expect(ConversionTarget(languageKey: "あ") == nil)
    }

    @Test("日本語は Shift + Space が担うため言語キーから解決しない")
    func japaneseIsNotResolvedFromLanguageKey() {
        #expect(ConversionTarget(languageKey: "j") == nil)
        #expect(ConversionTarget(languageKey: "J") == nil)
    }

    @Test("languageName はプロンプトでモデルに指示する英語名を返す")
    func languageNameIsEnglishName() {
        #expect(ConversionTarget.japanese.languageName == "Japanese")
        #expect(ConversionTarget.english.languageName == "English")
        #expect(ConversionTarget.chineseSimplified.languageName == "Simplified Chinese")
        #expect(ConversionTarget.korean.languageName == "Korean")
        #expect(ConversionTarget.french.languageName == "French")
        #expect(ConversionTarget.german.languageName == "German")
        #expect(ConversionTarget.spanish.languageName == "Spanish")
    }

    @Test("全ターゲットは日本語 + 翻訳 6 言語の 7 つ")
    func allCasesCoverSevenTargets() {
        #expect(ConversionTarget.allCases.count == 7)
        #expect(ConversionTarget.allCases.first == .japanese)
    }
}
