import Foundation
import KotoCore
import Testing

@Suite("OutputPreset のドメインモデル（ADR-0011）")
struct OutputPresetTests {
    @Test("初期プリセットは standard / chat / email / codeReview / agentPrompt の 5 種を網羅する")
    func coversInitialPresets() {
        #expect(
            OutputPreset.allCases == [
                .standard, .chat, .email, .codeReview, .agentPrompt,
            ]
        )
    }

    @Test(
        "プリセット → OutputProfile の写像は全ケースで安定している",
        arguments: [
            (OutputPreset.standard, OutputProfile.neutral),
            (OutputPreset.chat, OutputProfile.casual),
            (OutputPreset.email, OutputProfile.business),
            (OutputPreset.codeReview, OutputProfile.technical),
            (OutputPreset.agentPrompt, OutputProfile.technical),
        ]
    )
    func profileMappingIsStable(preset: OutputPreset, expected: OutputProfile) {
        #expect(preset.profile == expected)
    }

    @Test("displayName は全ケースで空でなく、互いに重複しない")
    func displayNamesAreNonEmptyAndUnique() {
        for preset in OutputPreset.allCases {
            #expect(!preset.displayName.isEmpty)
        }
        let names = OutputPreset.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test(
        "presetInstruction は standard のみ nil で、他は空でない追加指示を持つ",
        arguments: OutputPreset.allCases
    )
    func presetInstructionPresence(preset: OutputPreset) {
        if preset == .standard {
            #expect(preset.presetInstruction == nil)
        } else {
            #expect(preset.presetInstruction?.isEmpty == false)
        }
    }

    @Test("ケース名（rawValue）に特定の製品名・サービス名をハードコードしない")
    func rawValuesDoNotHardcodeProductNames() {
        // Claude Code / Codex は agentPrompt の代表例であって唯一の対応
        // コンテキストではない（Issue 37・ADR-0011）。Slack / GitHub も同様。
        for preset in OutputPreset.allCases {
            let raw = preset.rawValue.lowercased()
            #expect(!raw.contains("claude"))
            #expect(!raw.contains("codex"))
            #expect(!raw.contains("slack"))
            #expect(!raw.contains("github"))
        }
    }

    @Test("各プリセットの追加指示は出力先固有の要求を表現する")
    func presetInstructionContents() {
        // chat: 短く砕けた表現。email: 件名・挨拶を勝手に足さない。
        // codeReview: Markdown 構造と Issue 参照の保持。
        // agentPrompt: 命令形で簡潔に、コマンド・パスを変えない。
        #expect(OutputPreset.chat.presetInstruction?.contains("短く") == true)
        #expect(OutputPreset.email.presetInstruction?.contains("件名") == true)
        #expect(OutputPreset.email.presetInstruction?.contains("足さない") == true)
        #expect(OutputPreset.codeReview.presetInstruction?.contains("Markdown") == true)
        #expect(OutputPreset.codeReview.presetInstruction?.contains("Issue") == true)
        #expect(OutputPreset.agentPrompt.presetInstruction?.contains("コマンド") == true)
        #expect(OutputPreset.agentPrompt.presetInstruction?.contains("命令形") == true)
    }
}

@Suite("ConversionSettings の OutputPreset と実効プロファイル（ADR-0011）")
struct ConversionSettingsOutputPresetTests {
    @Test("outputPreset の既定は .standard、appAwarePresetsEnabled の既定は false")
    func defaultsKeepPresetsInert() {
        #expect(ConversionSettings.default.outputPreset == .standard)
        #expect(ConversionSettings.default.appAwarePresetsEnabled == false)
        #expect(ConversionSettings().outputPreset == .standard)
        #expect(ConversionSettings().appAwarePresetsEnabled == false)
        // 既存フィールドの既定値も変わらない。
        #expect(ConversionSettings.default.style == .neutral)
        #expect(ConversionSettings.default.outputProfile == .neutral)
        #expect(ConversionSettings.default.maximumExpansionRatio == 4.0)
    }

    @Test("プリセットフィールドの無い旧 JSON（ADR-0010 世代）は既定値で decode に成功する")
    func decodesLegacyJSONWithoutPresetFields() throws {
        let json = """
            {
              "style": "polite",
              "customInstruction": "簡潔に。",
              "protectedTerms": ["Koto"],
              "maximumExpansionRatio": 2.5,
              "outputProfile": "business"
            }
            """
        let data = try #require(json.data(using: .utf8))
        let settings = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(settings.outputPreset == .standard)
        #expect(settings.appAwarePresetsEnabled == false)
        // 既存フィールドは従来どおり読める。
        #expect(settings.style == .polite)
        #expect(settings.outputProfile == .business)
        // プリセット未使用ユーザーの outputProfile はそのまま実効になる。
        #expect(settings.effectiveProfile == .business)
    }

    @Test("未知の outputPreset 文字列は .standard へ決定論的にフォールバックする")
    func unknownPresetFallsBackToStandard() throws {
        let json = """
            {
              "style": "neutral",
              "customInstruction": "",
              "protectedTerms": [],
              "maximumExpansionRatio": 4.0,
              "outputProfile": "neutral",
              "outputPreset": "newsletter",
              "appAwarePresetsEnabled": true
            }
            """
        let data = try #require(json.data(using: .utf8))
        let settings = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(settings.outputPreset == .standard)
        // フォールバックは outputPreset に閉じ、他のフィールドは読み取れる。
        #expect(settings.appAwarePresetsEnabled == true)
        #expect(settings.style == .neutral)
        #expect(settings.protectedTerms == [])
    }

    @Test(
        "outputPreset と appAwarePresetsEnabled は encode / decode を往復しても保たれる",
        arguments: OutputPreset.allCases, [false, true]
    )
    func presetFieldsRoundtrip(preset: OutputPreset, enabled: Bool) throws {
        var settings = ConversionSettings.default
        settings.outputPreset = preset
        settings.appAwarePresetsEnabled = enabled
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ConversionSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.outputPreset == preset)
        #expect(decoded.appAwarePresetsEnabled == enabled)
    }

    @Test("UserDefaults リポジトリ経由でもプリセット設定が往復する")
    func presetFieldsRoundtripThroughRepository() throws {
        let suite = "koto-tests-\(UUID().uuidString)"
        let repository = try #require(UserDefaultsSettingsRepository(suiteName: suite))
        var settings = ConversionSettings.default
        settings.outputPreset = .codeReview
        settings.appAwarePresetsEnabled = true
        repository.save(settings)
        #expect(repository.load() == settings)
        repository.resetToDefaults()
        let reset = repository.load()
        #expect(reset.outputPreset == .standard)
        #expect(reset.appAwarePresetsEnabled == false)
    }

    @Test(
        "appAwarePresetsEnabled が false なら実効プリセットは常に .standard",
        arguments: OutputPreset.allCases
    )
    func disabledFlagForcesStandardEffectivePreset(preset: OutputPreset) {
        var settings = ConversionSettings.default
        settings.outputPreset = preset
        settings.appAwarePresetsEnabled = false
        #expect(settings.effectivePreset == .standard)
    }

    @Test(
        "appAwarePresetsEnabled が true なら選択したプリセットがそのまま実効になる",
        arguments: OutputPreset.allCases
    )
    func enabledFlagAppliesSelectedPreset(preset: OutputPreset) {
        var settings = ConversionSettings.default
        settings.outputPreset = preset
        settings.appAwarePresetsEnabled = true
        #expect(settings.effectivePreset == preset)
    }

    @Test("effectiveProfile はプリセット未適用の間は outputProfile を使う")
    func effectiveProfileFallsBackToOutputProfile() {
        var settings = ConversionSettings.default
        settings.outputProfile = .polite
        settings.outputPreset = .chat
        settings.appAwarePresetsEnabled = false
        // 無効化中はプリセットを無視し、従来の outputProfile を尊重する。
        #expect(settings.effectiveProfile == .polite)

        settings.appAwarePresetsEnabled = true
        settings.outputPreset = .standard
        // standard プリセットは束を持たないので outputProfile を尊重する。
        #expect(settings.effectiveProfile == .polite)
    }

    @Test("effectiveProfile はプリセット適用時にプリセットの束を優先する")
    func effectiveProfilePrefersPresetBundle() {
        var settings = ConversionSettings.default
        settings.outputProfile = .business
        settings.outputPreset = .chat
        settings.appAwarePresetsEnabled = true
        #expect(settings.effectiveProfile == .casual)
    }

    @Test("プリセットは保護語のサニタイズと出力検証の挙動を変えない")
    func presetDoesNotChangeValidationBehavior() {
        var baseline = ConversionSettings.default
        baseline.protectedTerms = ["Koto", " "]
        var withPreset = baseline
        withPreset.outputPreset = .agentPrompt
        withPreset.appAwarePresetsEnabled = true
        #expect(withPreset.sanitizedProtectedTerms == baseline.sanitizedProtectedTerms)

        let source = "Koto wo naosu"
        let lostOutput = "それ を なおす"
        let baselineLost = ConversionOutputValidator.validate(
            output: lostOutput,
            source: source,
            settings: baseline,
            target: .english
        )
        let presetLost = ConversionOutputValidator.validate(
            output: lostOutput,
            source: source,
            settings: withPreset,
            target: .english
        )
        // 保護語の消失はプリセットの有無に関係なく同じ失敗になる。
        #expect(presetLost == baselineLost)
        guard case .failure(.generationFailed) = presetLost else {
            Issue.record("保護語の消失がプリセット設定で検出されなかった: \(presetLost)")
            return
        }

        let goodOutput = "Fix Koto"
        let baselineGood = ConversionOutputValidator.validate(
            output: goodOutput,
            source: source,
            settings: baseline,
            target: .english
        )
        let presetGood = ConversionOutputValidator.validate(
            output: goodOutput,
            source: source,
            settings: withPreset,
            target: .english
        )
        #expect(presetGood == baselineGood)
        #expect(presetGood == .success(goodOutput))
    }
}
