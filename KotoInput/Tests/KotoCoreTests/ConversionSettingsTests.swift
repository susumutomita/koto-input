import Foundation
import KotoCore
import Testing

@Suite("ConversionSettings の OutputProfile と後方互換 decode")
struct ConversionSettingsTests {
    @Test("OutputProfile は多言語出力の 5 トーンを網羅する")
    func outputProfileCoversFiveTones() {
        #expect(
            OutputProfile.allCases == [
                .neutral, .polite, .business, .casual, .technical,
            ]
        )
    }

    @Test("outputProfile の既定値は .neutral で、日本語変換の既定動作を変えない")
    func defaultOutputProfileIsNeutral() {
        #expect(ConversionSettings.default.outputProfile == .neutral)
        #expect(ConversionSettings().outputProfile == .neutral)
        // 既存フィールドの既定値も変わらない。
        #expect(ConversionSettings.default.style == .neutral)
        #expect(ConversionSettings.default.customInstruction == "")
        #expect(ConversionSettings.default.maximumExpansionRatio == 4.0)
    }

    @Test("outputProfile フィールドの無い旧 JSON は既定値で decode に成功する")
    func decodesLegacyJSONWithoutOutputProfile() throws {
        let json = """
            {
              "style": "polite",
              "customInstruction": "簡潔に。",
              "protectedTerms": ["Koto"],
              "maximumExpansionRatio": 2.5
            }
            """
        let data = try #require(json.data(using: .utf8))
        let settings = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(settings.outputProfile == .neutral)
        #expect(settings.style == .polite)
        #expect(settings.customInstruction == "簡潔に。")
        #expect(settings.protectedTerms == ["Koto"])
        #expect(settings.maximumExpansionRatio == 2.5)
    }

    @Test("未知の outputProfile 文字列は .neutral へ決定論的にフォールバックする")
    func unknownOutputProfileFallsBackToNeutral() throws {
        let json = """
            {
              "style": "neutral",
              "customInstruction": "",
              "protectedTerms": [],
              "maximumExpansionRatio": 4.0,
              "outputProfile": "futuristic"
            }
            """
        let data = try #require(json.data(using: .utf8))
        let settings = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(settings.outputProfile == .neutral)
        // フォールバックは outputProfile に閉じ、他のフィールドは読み取れる。
        #expect(settings.style == .neutral)
        #expect(settings.protectedTerms == [])
    }

    @Test(
        "outputProfile は encode / decode を往復しても保たれる",
        arguments: OutputProfile.allCases
    )
    func outputProfileRoundtrips(profile: OutputProfile) throws {
        var settings = ConversionSettings.default
        settings.outputProfile = profile
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.outputProfile == profile)
    }

    @Test("UserDefaults リポジトリ経由でも outputProfile が往復する")
    func outputProfileRoundtripsThroughRepository() throws {
        let suite = "koto-tests-\(UUID().uuidString)"
        let repository = try #require(UserDefaultsSettingsRepository(suiteName: suite))
        var settings = ConversionSettings.default
        settings.outputProfile = .business
        repository.save(settings)
        #expect(repository.load() == settings)
        repository.resetToDefaults()
        #expect(repository.load().outputProfile == .neutral)
    }

    // MARK: - contextMemoryEnabled（Issue 46、ADR-0013）

    @Test("contextMemoryEnabled の既定値は false で、文脈収集は opt-in")
    func defaultContextMemoryIsDisabled() {
        #expect(!ConversionSettings.default.contextMemoryEnabled)
        #expect(!ConversionSettings().contextMemoryEnabled)
    }

    @Test("contextMemoryEnabled フィールドの無い旧 JSON は false で decode に成功する")
    func decodesLegacyJSONWithoutContextMemoryEnabled() throws {
        let json = """
            {
              "style": "neutral",
              "customInstruction": "",
              "protectedTerms": ["Koto"],
              "maximumExpansionRatio": 4.0
            }
            """
        let data = try #require(json.data(using: .utf8))
        let settings = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(!settings.contextMemoryEnabled)
        #expect(settings.protectedTerms == ["Koto"])
    }

    @Test(
        "contextMemoryEnabled は encode / decode を往復しても保たれる",
        arguments: [false, true]
    )
    func contextMemoryEnabledRoundtrips(enabled: Bool) throws {
        var settings = ConversionSettings.default
        settings.contextMemoryEnabled = enabled
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.contextMemoryEnabled == enabled)
    }
}
