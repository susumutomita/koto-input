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

    @Test("アラビア語はキー割当の無い表現可能ターゲットで、言語キーから解決しない（ADR-0010）")
    func arabicIsNotResolvedFromLanguageKey() {
        #expect(ConversionTarget(languageKey: "a") == nil)
        #expect(ConversionTarget(languageKey: "A") == nil)
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
        #expect(ConversionTarget.arabic.languageName == "Arabic")
    }

    @Test("全ターゲットは日本語 + 翻訳 7 言語の 8 つ")
    func allCasesCoverEightTargets() {
        #expect(ConversionTarget.allCases.count == 8)
        #expect(ConversionTarget.allCases.first == .japanese)
    }

    // MARK: - ターゲット言語のメタデータ（ADR-0010）

    @Test("localeIdentifier は BCP 47 のロケール識別子を返す")
    func localeIdentifierIsBCP47() {
        #expect(ConversionTarget.japanese.localeIdentifier == "ja")
        #expect(ConversionTarget.english.localeIdentifier == "en")
        #expect(ConversionTarget.chineseSimplified.localeIdentifier == "zh-Hans")
        #expect(ConversionTarget.korean.localeIdentifier == "ko")
        #expect(ConversionTarget.french.localeIdentifier == "fr")
        #expect(ConversionTarget.german.localeIdentifier == "de")
        #expect(ConversionTarget.spanish.localeIdentifier == "es")
        #expect(ConversionTarget.arabic.localeIdentifier == "ar")
    }

    @Test("localeIdentifier は全ターゲットで一意")
    func localeIdentifierIsUnique() {
        let identifiers = ConversionTarget.allCases.map(\.localeIdentifier)
        #expect(Set(identifiers).count == ConversionTarget.allCases.count)
    }

    @Test("displayName は設定 UI・候補ラベル用の日本語名を返す")
    func displayNameIsJapaneseLabel() {
        #expect(ConversionTarget.japanese.displayName == "日本語")
        #expect(ConversionTarget.english.displayName == "英語")
        #expect(ConversionTarget.chineseSimplified.displayName == "中国語（簡体字）")
        #expect(ConversionTarget.korean.displayName == "韓国語")
        #expect(ConversionTarget.french.displayName == "フランス語")
        #expect(ConversionTarget.german.displayName == "ドイツ語")
        #expect(ConversionTarget.spanish.displayName == "スペイン語")
        #expect(ConversionTarget.arabic.displayName == "アラビア語")
    }

    @Test("isRightToLeft はアラビア語のみ true")
    func isRightToLeftOnlyForArabic() {
        for target in ConversionTarget.allCases {
            #expect(target.isRightToLeft == (target == .arabic))
        }
    }
}
