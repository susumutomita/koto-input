import Foundation
import KotoCore

/// 辞書ラティスと AI 単語選択を合成するハイブリッド変換プロバイダ（ADR-0016）。
/// 決定的な辞書ラティス変換（LatticeConverter, KotoCore）が一次変換で「正解の
/// 表記を必ず候補に含める」高速な一発変換を保証し、AI（既定は
/// AppleFoundationModelsProvider）が読みに対する文脈での単語選択・整形を担う。
///
/// convert の流れ:
///   1. reading = request.modelInputText（前段かな化済み）。
///   2. draft = LatticeConverter.convert(reading).best（mozc 全辞書 + 連接コストの
///      Viterbi 最短経路。即時・完全網羅）。
///   3. AI に reading（[INPUT]）と draft（[DRAFT]）と contextEntries を渡し、草案を
///      手がかりに正しい単語を選ばせて整形し、ConversionOutputValidator を通す。
///   4. 検証成功なら AI 出力を確定。AI が不可用・未準備・失敗・検証 NG のときは
///      draft を確定フォールバックとして返す（AI 無しでも高速な一発変換が成立）。
///
/// availability: 辞書ラティスが常に一発変換を成立させるため、AI の可否によらず
/// 常に .available を返す（AI の不可用は convert 内でフォールバックに縮退させる）。
/// これにより coordinator の availability ショートサーキットに引っかけず、「AI
/// 不可用でも辞書だけで一発変換が成立する」受け入れ基準を満たす。
public actor HybridConversionProvider: TextConversionProvider {
    private let lattice: LatticeConverter
    private let aiProvider: any TextConversionProvider

    /// ラティスと AI 段を明示的に注入する（テストは scripted AI provider を渡す、
    /// ADR-0004）。
    public init(lattice: LatticeConverter, aiProvider: any TextConversionProvider) {
        self.lattice = lattice
        self.aiProvider = aiProvider
    }

    /// 同梱辞書（mozc dictionary_oss 全辞書 + 連接行列）と任意の AI 段で構築する。
    /// 既定の AI 段は AppleFoundationModelsProvider。
    public init(
        aiProvider: any TextConversionProvider = AppleFoundationModelsProvider()
    ) throws {
        self.lattice = try LatticeConverter.bundled()
        self.aiProvider = aiProvider
    }

    /// 辞書ラティスが常に一発変換を成立させるため常に available。
    public func availability() async -> ProviderAvailability {
        .available
    }

    /// AI 段のウォームアップを行う。辞書ラティスは init で既にロード済み。
    public func prewarm(settings: ConversionSettings) async {
        await aiProvider.prewarm(settings: settings)
    }

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        // 翻訳など非日本語ターゲット（ADR-0009 / 0010）は辞書ラティスの対象外。
        // 同梱辞書は日本語の表記しか持たないため、英語訳要求に日本語の draft を
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

        // 1) 読み（かな化済み）を辞書ラティスで変換し、草案を得る（即時・決定的）。
        let reading = request.modelInputText
        let draft = lattice.convert(reading: reading).best

        // 2) AI が利用可能なら、読みと草案を渡して単語選択・整形させる。
        //    不可用・未準備・失敗・検証 NG のときは draft を確定フォールバック。
        if case .available = await aiProvider.availability() {
            if let aiText = await aiConvert(request: request, draft: draft) {
                // 辞書認識の no-op ガード（ADR-0016）。辞書が漢字化できた
                // （draft が空でなく全かなでもない）のに AI が全かなへ戻したら、
                // AI の据え置き（no-op）とみなして draft を優先する。逆に辞書も AI も
                // 漢字化できない読み（draft が全かな）は、全かなを正規の結果として
                // 受理する。no-op の真偽は辞書シグナルが無いと判定できないため、
                // 字種だけを見る validator ではなくここ（辞書を持つ provider）で行う。
                // draft が空のときは漢字シグナルが無いのでガードは発火させない。
                if Self.isAllHiragana(aiText), !draft.isEmpty, !Self.isAllHiragana(draft) {
                    return makeResult(request: request, text: draft)
                }
                return makeResult(request: request, text: aiText)
            }
        }
        return makeResult(request: request, text: draft)
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
    private func aiConvert(request: ConversionRequest, draft: String) async -> String? {
        // AI には読み（元 request の sourceText 由来）を [INPUT]、辞書ラティスの草案を
        // [DRAFT] として渡す。AI は草案を手がかりに読みの単語選択を行う。検証・
        // フォールバック判定は元 request の sourceText を基準にする。
        let aiRequest = ConversionRequest(
            id: request.id,
            compositionID: request.compositionID,
            revision: request.revision,
            sourceText: request.sourceText,
            settings: request.settings,
            target: request.target,
            attempt: request.attempt,
            contextEntries: request.contextEntries,
            dictionaryDraft: draft
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
