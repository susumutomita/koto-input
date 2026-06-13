@testable import AppleFoundationModelsProvider
import Foundation
import KotoCore
import Testing

/// テストから AI 段の挙動を制御する provider（ADR-0004）。available / unavailable /
/// preparing / 失敗 / 任意出力を再現し、HybridConversionProvider の合成と
/// フォールバックを決定論的に検証する。実 AI（AppleFoundationModelsProvider）は
/// CI で利用不可・非決定的なため、この scripted provider に差し替える。
actor ScriptedAIProvider: TextConversionProvider {
    enum Behavior: Sendable {
        case returns(String)
        case throwsError(KotoError)
    }

    private var availabilityResult: ProviderAvailability
    private let behavior: Behavior
    private(set) var prewarmCount = 0
    private(set) var convertCount = 0
    private(set) var receivedSourceTexts: [String] = []
    private(set) var receivedContextEntries: [[String]] = []

    init(availability: ProviderAvailability = .available, behavior: Behavior = .returns("")) {
        self.availabilityResult = availability
        self.behavior = behavior
    }

    func availability() async -> ProviderAvailability { availabilityResult }

    func prewarm(settings: ConversionSettings) async { prewarmCount += 1 }

    func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        convertCount += 1
        receivedSourceTexts.append(request.sourceText)
        receivedContextEntries.append(request.contextEntries)
        switch behavior {
        case .returns(let text):
            return ConversionResult(
                requestID: request.id,
                compositionID: request.compositionID,
                revision: request.revision,
                convertedText: text,
                attempt: request.attempt
            )
        case .throwsError(let error):
            throw error
        }
    }
}

@Suite("HybridConversionProvider の辞書バックボーン + AI 再ランク合成")
struct HybridConversionProviderTests {
    /// 実 mozc 由来の小規模辞書（スタブ表記なし）。
    private func makeDictionary() -> DictionaryConverter {
        DictionaryConverter(entries: [
            .init(reading: "ほうほう", surface: "方法", cost: 2797),
            .init(reading: "けっきょく", surface: "結局", cost: 2684),
            .init(reading: "にほんご", surface: "日本語", cost: 3793),
        ])
    }

    private func makeRequest(
        _ source: String,
        context: [String] = []
    ) -> ConversionRequest {
        ConversionRequest(
            id: ConversionRequestID(),
            compositionID: CompositionID(),
            revision: 1,
            sourceText: source,
            settings: .default,
            target: .japanese,
            contextEntries: context
        )
    }

    @Test("AI が有効で検証を通る出力を返したら AI 出力を確定する")
    func returnsAIOutputWhenValid() async throws {
        let ai = ScriptedAIProvider(behavior: .returns("方法を確認する"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let result = try await provider.convert(makeRequest("houhou wo kakunin suru"))
        #expect(result.convertedText == "方法を確認する")
    }

    @Test("AI に辞書最良と読みと文脈が渡る")
    func passesDictBestReadingAndContextToAI() async throws {
        let ai = ScriptedAIProvider(behavior: .returns("方法"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let context = ["前の文脈"]
        _ = try await provider.convert(makeRequest("houhou", context: context))
        let receivedContext = await ai.receivedContextEntries
        #expect(receivedContext == [context])
        // AI には読み（かな化済み）と辞書最良を渡す（プロンプト経路の sourceText に
        // 辞書最良が載る）。
        let receivedSources = await ai.receivedSourceTexts
        #expect(receivedSources.first?.contains("方法") == true)
    }

    @Test("AI が unavailable のときは辞書最良をフォールバック確定する")
    func fallsBackToDictBestWhenUnavailable() async throws {
        let ai = ScriptedAIProvider(
            availability: .unavailable(reason: "テスト"),
            behavior: .returns("使われない")
        )
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let result = try await provider.convert(makeRequest("houhou"))
        #expect(result.convertedText == "方法")
        // AI は呼ばれない。
        #expect(await ai.convertCount == 0)
    }

    @Test("AI が preparing のときも辞書最良をフォールバック確定する")
    func fallsBackToDictBestWhenPreparing() async throws {
        let ai = ScriptedAIProvider(availability: .preparing, behavior: .returns("x"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let result = try await provider.convert(makeRequest("kekkyoku"))
        #expect(result.convertedText == "結局")
        #expect(await ai.convertCount == 0)
    }

    @Test("AI が例外を投げたら辞書最良をフォールバック確定する")
    func fallsBackToDictBestWhenAIThrows() async throws {
        let ai = ScriptedAIProvider(behavior: .throwsError(.generationFailed("失敗")))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let result = try await provider.convert(makeRequest("nihongo"))
        #expect(result.convertedText == "日本語")
    }

    @Test("辞書が漢字化できたのに AI が全かなへ戻したら辞書最良を優先する")
    func prefersDictBestWhenAIRegressesToKana() async throws {
        // AI が変換を据え置いて全かな（ほうほう）を返しても、辞書が漢字化できた
        // （方法）なら辞書認識 no-op ガードが辞書最良を採用する（ADR-0016）。
        let ai = ScriptedAIProvider(behavior: .returns("ほうほう"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let result = try await provider.convert(makeRequest("houhou"))
        #expect(result.convertedText == "方法")
    }

    @Test("辞書ヒットしない読みでも AI 出力が有効なら確定する")
    func usesAIWhenDictionaryMisses() async throws {
        let ai = ScriptedAIProvider(behavior: .returns("確認"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        // "kakunin" は辞書に無い。AI が変換すればそれを確定。
        let result = try await provider.convert(makeRequest("kakunin"))
        #expect(result.convertedText == "確認")
    }

    @Test("辞書も AI も漢字化できない読みは全かなを正規結果として受理する")
    func acceptsAllKanaWhenNothingConverts() async throws {
        // 辞書ヒットなし + AI が全かなを返すケース。辞書も漢字化できない以上、
        // 全かなが正規の best-effort なので過剰棄却せず受理する（ADR-0016）。
        // 辞書認識 no-op ガードは dictBest も全かなのとき発火しない。
        let ai = ScriptedAIProvider(behavior: .returns("ぬぬぬ"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let result = try await provider.convert(makeRequest("nununu"))
        #expect(result.convertedText == "ぬぬぬ")
    }

    @Test("非日本語ターゲット（翻訳）は AI へ委譲し日本語の辞書最良を返さない")
    func delegatesNonJapaneseTargetToAI() async throws {
        let ai = ScriptedAIProvider(behavior: .returns("method"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let request = ConversionRequest(
            id: ConversionRequestID(),
            compositionID: CompositionID(),
            revision: 1,
            sourceText: "houhou",
            settings: .default,
            target: .english
        )
        let result = try await provider.convert(request)
        // 日本語の dictBest（方法）ではなく AI の訳語を返す。
        #expect(result.convertedText == "method")
    }

    @Test("非日本語ターゲットで AI が不可用なら日本語ではなく不可用を伝播させる")
    func nonJapaneseTargetPropagatesUnavailability() async {
        // 辞書は日本語表記しか持たないため、英訳要求に方法（日本語）を返しては
        // ならない。AI 不可用は modelUnavailable として失敗させる（ADR-0016 補遺）。
        let ai = ScriptedAIProvider(
            availability: .unavailable(reason: "x"),
            behavior: .returns("不使用")
        )
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let request = ConversionRequest(
            id: ConversionRequestID(),
            compositionID: CompositionID(),
            revision: 1,
            sourceText: "houhou",
            settings: .default,
            target: .english
        )
        do {
            let result = try await provider.convert(request)
            Issue.record("不可用が伝播せず変換が成立した: \(result.convertedText)")
        } catch let error as KotoError {
            #expect(error == .modelUnavailable("x"))
        } catch {
            Issue.record("想定外のエラー型: \(error)")
        }
    }

    @Test("availability は常に available（辞書バックボーンが一発変換を保証する）")
    func availabilityAlwaysAvailable() async {
        let ai = ScriptedAIProvider(availability: .unavailable(reason: "x"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        #expect(await provider.availability() == .available)
    }

    @Test("prewarm は AI 段を温める")
    func prewarmWarmsAI() async {
        let ai = ScriptedAIProvider()
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        await provider.prewarm(settings: .default)
        #expect(await ai.prewarmCount == 1)
    }

    @Test("同梱辞書ベースの既定構築でも代表読みがフォールバックで決定的に変換される")
    func bundledHybridFallbackIsDeterministic() async throws {
        // AI を unavailable にして辞書のみの一発変換を検証する。
        let ai = ScriptedAIProvider(availability: .unavailable(reason: "x"))
        let provider = try HybridConversionProvider(aiProvider: ai)
        let first = try await provider.convert(makeRequest("houhou")).convertedText
        let second = try await provider.convert(makeRequest("houhou")).convertedText
        #expect(first == "方法")
        #expect(first == second)
    }

    // MARK: - IME 統合（CompositionCoordinator 経由の一発変換, Issue 58）

    @Test("AI 不可用でも coordinator 経由で既定一発が決定的に成立する")
    @MainActor
    func coordinatorSingleShotIsDeterministicWhenAIUnavailable() async throws {
        // 辞書バックボーンのみで一発変換が成立することを、状態機械
        // （CompositionCoordinator）経由で end-to-end に確認する。AI 段は
        // unavailable に固定して辞書フォールバックだけを走らせる。
        let ai = ScriptedAIProvider(availability: .unavailable(reason: "x"))
        let provider = try HybridConversionProvider(aiProvider: ai)
        let store = SessionContextStore()

        func runOnce() async throws -> String {
            let coordinator = CompositionCoordinator(
                provider: provider,
                settingsRepository: MutableSettingsRepository(settings: .default),
                contextStore: store,
                renderer: { _ in }
            )
            coordinator.handle(.insert("houhou"))
            coordinator.handle(.requestConversion(.japanese))
            try await eventually {
                if case .converted = coordinator.state.phase { return true }
                return false
            }
            return coordinator.state.displayedText
        }

        // 同一入力 → 同一の既定出力（決定性）。常時候補リストは出さず単一最良のみ。
        let first = try await runOnce()
        let second = try await runOnce()
        #expect(first == "方法")
        #expect(first == second)
    }

    @Test("辞書もAIも漢字化できない全かな文でも coordinator は converted に到達する")
    @MainActor
    func coordinatorAcceptsLegitAllKanaPhrase() async throws {
        // 「やっておいて」のような正規の全かな文は、辞書ミス + AI 不可用でも
        // 全かなのまま確定できなければならない。validator の字種棄却を撤去し
        // no-op 判定を provider の辞書シグナルへ移した回帰防止（ADR-0016）。
        // 旧実装（validator が全かなを棄却）では failed に落ちていた。
        let ai = ScriptedAIProvider(availability: .unavailable(reason: "x"))
        let provider = HybridConversionProvider(dictionary: makeDictionary(), aiProvider: ai)
        let coordinator = CompositionCoordinator(
            provider: provider,
            settingsRepository: MutableSettingsRepository(settings: .default),
            contextStore: SessionContextStore(),
            renderer: { _ in }
        )
        coordinator.handle(.insert("yatteoite"))
        coordinator.handle(.requestConversion(.japanese))
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "やっておいて")
    }

    // MARK: - 辞書認識 no-op ガードの字種判定（isAllHiragana）

    @Test("isAllHiragana は変換済み字種の有無を判定する")
    func isAllHiraganaClassifiesText() {
        // ひらがな本体・長音符・内部空白・句読点は「未変換のかな」として true。
        #expect(HybridConversionProvider.isAllHiragana("ほうほう"))
        #expect(HybridConversionProvider.isAllHiragana("らーめん"))
        #expect(HybridConversionProvider.isAllHiragana("ほう ほう"))
        #expect(HybridConversionProvider.isAllHiragana("ほう、ほう"))
        // 漢字・カタカナを 1 文字でも含めば変換済み（false）。
        #expect(!HybridConversionProvider.isAllHiragana("方法"))
        #expect(!HybridConversionProvider.isAllHiragana("コーヒー"))
        // 判定対象の文字が無ければ false（空・空白のみ）。
        #expect(!HybridConversionProvider.isAllHiragana(""))
        #expect(!HybridConversionProvider.isAllHiragana("   "))
    }
}

/// テスト用の可変設定リポジトリ（KotoCoreTests の同名ヘルパーは別ターゲットの
/// ため、この統合テスト用に最小実装を持つ）。
final class MutableSettingsRepository: SettingsRepository, @unchecked Sendable {
    private var settings: ConversionSettings
    init(settings: ConversionSettings) { self.settings = settings }
    func load() -> ConversionSettings { settings }
    func save(_ settings: ConversionSettings) { self.settings = settings }
    func resetToDefaults() { settings = .default }
}

/// 条件が真になるまで協調的に待つ（KotoCoreTests の同名ヘルパーは別ターゲット）。
@MainActor
func eventually(
    _ comment: Comment? = nil,
    until condition: @MainActor () async -> Bool
) async throws {
    var iterations = 0
    while !(await condition()) {
        iterations += 1
        try #require(iterations < 200_000, comment ?? "条件が満たされないままタイムアウトしました。")
        await Task.yield()
    }
}
