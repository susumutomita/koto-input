import Foundation
import KotoCore

/// 辞書バックボーンと AI 再ランクを合成するハイブリッド変換プロバイダ
/// （ADR-0016）。決定的な辞書変換（DictionaryConverter, KotoCore）が一次変換で
/// 「正解の表記を必ず候補に含める」一発変換を保証し、AI（既定は
/// AppleFoundationModelsProvider）が文脈での再ランクと整形を担う。
///
/// convert の流れ（仕様書「HybridConversionProvider」）:
///   1. reading = request.modelInputText（前段かな化済み）。
///   2. dictBest, dictCandidates = DictionaryConverter.convert(reading)。
///   3. AI に dictBest と reading と contextEntries を渡して文脈再ランク・整形し、
///      ConversionOutputValidator を通す。
///   4. 検証成功なら AI 出力を確定。AI が不可用・未準備・失敗・検証 NG のときは
///      dictBest を確定フォールバックとして返す。
///
/// availability: 辞書バックボーンが常に一発変換を成立させるため、AI の可否に
/// よらず常に .available を返す（AI の不可用は convert 内でフォールバックに縮退
/// させる）。これにより coordinator の availability ショートサーキットに引っかけず、
/// 「AI 不可用でも辞書だけで一発変換が成立する」受け入れ基準を満たす。
public actor HybridConversionProvider: TextConversionProvider {
    private let dictionary: DictionaryConverter
    private let aiProvider: any TextConversionProvider

    /// 辞書と AI 段を明示的に注入する（テストは scripted AI provider を渡す、
    /// ADR-0004）。
    public init(dictionary: DictionaryConverter, aiProvider: any TextConversionProvider) {
        self.dictionary = dictionary
        self.aiProvider = aiProvider
    }

    /// 同梱辞書（mozc dictionary_oss サブセット）と任意の AI 段で構築する。
    /// 既定の AI 段は AppleFoundationModelsProvider。
    public init(
        aiProvider: any TextConversionProvider = AppleFoundationModelsProvider()
    ) throws {
        self.dictionary = try DictionaryConverter.bundled()
        self.aiProvider = aiProvider
    }

    /// 辞書バックボーンが常に一発変換を成立させるため常に available。
    public func availability() async -> ProviderAvailability {
        .available
    }

    /// 辞書ロードと AI 段のウォームアップを行う。辞書は init で既にロード済み
    /// （即時）なので、ここでは AI 段を温める。
    public func prewarm(settings: ConversionSettings) async {
        await aiProvider.prewarm(settings: settings)
    }

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        // 翻訳など非日本語ターゲット（ADR-0009 / 0010）は辞書バックボーンの対象外。
        // 同梱辞書は日本語の表記しか持たないため、英語訳要求に日本語の dictBest を
        // 返すと「日本語を英訳として確定」してしまう。非日本語は AI へ完全委譲し、
        // AI が使えないときは日本語を返さず不可用を伝播させる。availability() は
        // 辞書フォールバックのため常に .available なので、ここで AI 可否を見る。
        guard request.target == .japanese else {
            switch await aiProvider.availability() {
            case .available:
                return try await aiProvider.convert(request)
            case .unavailable(let reason):
                throw KotoError.modelUnavailable(reason)
            case .preparing:
                throw KotoError.modelUnavailable("準備中です。")
            }
        }

        // 1) 読み（かな化済み）を辞書変換し、単一最良と代替候補を得る。
        let reading = request.modelInputText
        let dictionaryResult = dictionary.convert(reading: reading)
        let dictBest = dictionaryResult.best

        // 2) AI が利用可能なら、dictBest と reading と文脈を渡して再ランク・整形する。
        //    不可用・未準備・失敗・検証 NG のときは dictBest を確定フォールバック。
        if case .available = await aiProvider.availability() {
            if let aiText = await aiConvert(request: request, dictBest: dictBest) {
                // 辞書認識の no-op ガード（ADR-0016）。辞書が漢字化できた
                // （dictBest が空でなく全かなでもない）のに AI が全かなへ戻したら、
                // AI の据え置き（no-op）とみなして辞書最良を優先する。逆に辞書も AI も
                // 漢字化できない読み（dictBest が全かな）は、全かなを正規の結果として
                // 受理する。no-op の真偽は辞書シグナルが無いと判定できないため、
                // 字種だけを見る validator ではなくここ（辞書を持つ provider）で行う。
                // dictBest が空のときは漢字シグナルが無いのでガードは発火させない。
                if Self.isAllHiragana(aiText), !dictBest.isEmpty, !Self.isAllHiragana(dictBest) {
                    return makeResult(request: request, text: dictBest)
                }
                return makeResult(request: request, text: aiText)
            }
        }
        return makeResult(request: request, text: dictBest)
    }

    /// 本文がすべてひらがな（と長音符）かを判定する。辞書認識 no-op ガードに使う。
    /// 空白・句読点は字種判定の対象外として無視し、「ほう ほう」「ほうほう。」の
    /// ような表記差に騙されない。判定対象の文字が 1 つも無ければ false。
    static func isAllHiragana(_ text: String) -> Bool {
        var sawHiragana = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || ignorablePunctuation.contains(scalar) {
                continue
            }
            // ひらがな ぁ（U+3041）〜 ゖ（U+3096）と長音符 ー（U+30FC）のみ許容。
            // 漢字・カタカナ・英数字を 1 つでも含めば変換が起きているとみなす。
            if (0x3041...0x3096).contains(scalar.value) || scalar.value == 0x30FC {
                sawHiragana = true
                continue
            }
            return false
        }
        return sawHiragana
    }

    /// 字種判定で無視する空白以外の文字（日本語/ASCII の句読点・中黒）。
    private static let ignorablePunctuation: Set<Unicode.Scalar> =
        Set("。．.、,!！?？・".unicodeScalars)

    /// AI 段を呼び、出力を ConversionOutputValidator に通す。検証成功なら整形済み
    /// テキストを、不可用・例外・検証 NG なら nil（フォールバック指示）を返す。
    private func aiConvert(request: ConversionRequest, dictBest: String) async -> String? {
        // AI には辞書最良を起点テキストとして渡す。AppleFoundationModelsProvider は
        // sourceText から modelInputText（プロンプト入力）を導出するため、dictBest を
        // sourceText に載せると「辞書が漢字化した一次変換を文脈で整える」入力になる。
        // 検証・フォールバック判定は元 request の sourceText を基準に行う。
        let aiRequest = ConversionRequest(
            id: request.id,
            compositionID: request.compositionID,
            revision: request.revision,
            sourceText: dictBest,
            settings: request.settings,
            target: request.target,
            attempt: request.attempt,
            contextEntries: request.contextEntries
        )
        let aiOutput: String
        do {
            let result = try await aiProvider.convert(aiRequest)
            aiOutput = result.convertedText
        } catch {
            return nil
        }
        // 検証は元 request の sourceText / settings / target を基準にする
        // （プロンプトはセキュリティ境界ではないため出力は必ず validator を通す）。
        switch ConversionOutputValidator.validate(
            output: aiOutput,
            source: request.sourceText,
            settings: request.settings,
            target: request.target
        ) {
        case .success(let text):
            return text
        case .failure:
            return nil
        }
    }

    private func makeResult(request: ConversionRequest, text: String) -> ConversionResult {
        ConversionResult(
            requestID: request.id,
            compositionID: request.compositionID,
            revision: request.revision,
            convertedText: text,
            attempt: request.attempt
        )
    }
}
