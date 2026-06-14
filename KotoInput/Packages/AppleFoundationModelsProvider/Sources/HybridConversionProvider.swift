import Foundation
import KotoCore

/// 辞書ラティスと AI 単語選択を合成するハイブリッド変換プロバイダ（ADR-0016）。
/// 決定的な辞書ラティス変換（LatticeConverter, KotoCore）が一次変換で「正解の
/// 表記を必ず候補に含める」高速な一発変換を保証し、AI（既定は
/// AppleFoundationModelsProvider）が読みに対する文脈での単語選択・整形を担う。
///
/// 重要（性能・応答性）: 同梱辞書は展開後で約 64MB あり、ロードは数百 ms かかる。
/// init では決してロードせず、actor 内（= メインスレッド外）で遅延ロードする。
/// `makeProvider()` がメインアクターで本 provider を構築してもメインスレッドは
/// ブロックされない（IME が固まらない）。prewarm でロードを前倒しして温める。
///
/// convert の流れ:
///   1. reading = request.modelInputText（前段かな化済み）。
///   2. candidates = LatticeConverter.nBest(reading)（mozc 全辞書 + 連接コストの
///      Viterbi の上位 K 候補。先頭が単一最良。ロード未完なら空）。
///   3. AI に reading（[INPUT]）と candidates（[CANDIDATES]）と contextEntries を
///      渡し、候補から最も自然なものを選ばせて整形し、ConversionOutputValidator を
///      通す（辞書が候補を漏れなく出し、AI が文脈で選ぶ分担）。
///   4. 検証成功なら AI 出力を確定。AI が不可用・未準備・失敗・検証 NG のときは
///      辞書最良（candidates.first、無ければ読み）を確定フォールバックとして返す。
///
/// availability: 辞書ラティス（または読みフォールバック）が常に一発変換を成立
/// させるため常に .available を返す。
public actor HybridConversionProvider: TextConversionProvider {
    private var lattice: LatticeConverter?
    private var didAttemptLoad: Bool
    private let aiProvider: any TextConversionProvider

    /// ラティスを明示注入する（テストは scripted AI provider と実 mozc 辞書を渡す、
    /// ADR-0004 / No Mock）。ロード済みなので遅延ロードは行わない。
    public init(lattice: LatticeConverter, aiProvider: any TextConversionProvider) {
        self.lattice = lattice
        self.didAttemptLoad = true
        self.aiProvider = aiProvider
    }

    /// 既定構築。辞書はここではロードせず、最初の prewarm / convert（actor 内・
    /// メインスレッド外）で遅延ロードする。init は即時・非スロー。
    public init(
        aiProvider: any TextConversionProvider = AppleFoundationModelsProvider()
    ) {
        self.lattice = nil
        self.didAttemptLoad = false
        self.aiProvider = aiProvider
    }

    /// 同梱辞書を 1 度だけ遅延ロードする（actor 隔離のためメインスレッド外で走る）。
    /// ロードに失敗したら nil のまま（AI と読みフォールバックで縮退して動かし続ける）。
    private func ensureLattice() -> LatticeConverter? {
        if didAttemptLoad { return lattice }
        didAttemptLoad = true
        lattice = try? LatticeConverter.bundled()
        return lattice
    }

    public func availability() async -> ProviderAvailability {
        .available
    }

    /// 辞書ラティスのロード（重い）を前倒しし、AI 段も温める。composition 開始時に
    /// 呼ばれ、actor 内で走るのでメインスレッドはブロックしない。
    public func prewarm(settings: ConversionSettings) async {
        _ = ensureLattice()
        await aiProvider.prewarm(settings: settings)
    }

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        // 翻訳など非日本語ターゲット（ADR-0009 / 0010）は辞書ラティスの対象外。
        // 同梱辞書は日本語の表記しか持たないため、英語訳要求に日本語の draft を
        // 返すと「日本語を英訳として確定」してしまう。非日本語は AI へ完全委譲し、
        // AI が使えないときは日本語を返さず不可用を伝播させる。
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

        // 1) 読み（かな化済み）を辞書ラティスで n-best 変換し、上位候補を得る
        //    （actor 内で遅延ロード・変換。ロード未完/失敗なら空）。先頭が単一最良。
        let reading = request.modelInputText
        let candidates = ensureLattice()?.nBest(
            reading: reading, maxCandidates: Self.candidateCount
        ) ?? []
        let best = candidates.first

        // 2) AI が利用可能なら、読みと候補列を渡して候補から単語選択・整形させる。
        if case .available = await aiProvider.availability() {
            if let aiText = await aiConvert(request: request, candidates: candidates) {
                // 辞書認識の no-op ガード（ADR-0016）。辞書が漢字化できた（best が
                // 空でなく全かなでもない）のに AI が全かなへ戻したら、AI の据え置きと
                // みなして辞書最良を優先する。
                if let best, Self.isAllHiragana(aiText), !best.isEmpty,
                    !Self.isAllHiragana(best)
                {
                    return makeResult(request: request, text: best)
                }
                return makeResult(request: request, text: aiText)
            }
        }
        // フォールバック: 辞書最良（無ければ読みそのもの）を確定する。
        return makeResult(request: request, text: best ?? reading)
    }

    /// AI に渡すラティス上位候補の数。多すぎるとトークンが増え、少なすぎると
    /// 正解が候補に入らない。
    private static let candidateCount = 6

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
            // 漢字・カタカナ・英数字を 1 文字でも含めば変換が起きているとみなす。
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
    private func aiConvert(request: ConversionRequest, candidates: [String]) async -> String? {
        // AI には読み（元 request の sourceText 由来）を [INPUT]、辞書ラティスの上位
        // 候補を [CANDIDATES] として渡す。検証・フォールバック判定は元 request の
        // sourceText 基準。
        let aiRequest = ConversionRequest(
            id: request.id,
            compositionID: request.compositionID,
            revision: request.revision,
            sourceText: request.sourceText,
            settings: request.settings,
            target: request.target,
            attempt: request.attempt,
            contextEntries: request.contextEntries,
            dictionaryCandidates: candidates
        )
        let aiOutput: String
        do {
            let result = try await aiProvider.convert(aiRequest)
            aiOutput = result.convertedText
        } catch {
            return nil
        }
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
