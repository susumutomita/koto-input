import Foundation
import KotoCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models（Apple Intelligence のオンデバイスモデル）を使う
/// 変換プロバイダ。入力テキストをデバイス外へ送信しない（ADR-0002）。
/// FoundationModels SDK が無いビルド環境では「モデル利用不可」に縮退して
/// コンパイルが通る（ADR-0003）。
///
/// actor にすることで変換リクエストを直列化し、prewarm で事前作成した
/// セッションを 1 回だけ使い捨てる（ADR-0005）。transcript は持ち越さない
/// ため、変換の決定性（greedy sampling）は保たれる。
public actor AppleFoundationModelsProvider: TextConversionProvider {
    #if canImport(FoundationModels)
    /// prewarm で温めたセッションの置き場（target 別）。instructions は
    /// target ごとに異なるため ConversionTarget をキーにキャッシュし、
    /// instructions が一致する次の変換で 1 回だけ使う。actor の stored
    /// property に @available 型を直接置けないため AnyObject で持ち、
    /// 利用側でキャストする。
    private var preparedBoxes: [ConversionTarget: AnyObject] = [:]

    @available(macOS 26.0, *)
    private final class Prepared {
        let instructions: String
        let session: LanguageModelSession

        init(instructions: String, session: LanguageModelSession) {
            self.instructions = instructions
            self.session = session
        }
    }

    @available(macOS 26.0, *)
    private func takePrepared(
        for target: ConversionTarget,
        matching instructions: String
    ) -> LanguageModelSession? {
        guard
            let box = preparedBoxes[target] as? Prepared,
            box.instructions == instructions
        else {
            return nil
        }
        preparedBoxes[target] = nil
        return box.session
    }
    #endif

    public init() {}

    public func availability() async -> ProviderAvailability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return .unavailable(reason: "macOS 26 以降が必要です。")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.modelNotReady):
            return .preparing
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "この Mac は Apple Intelligence に対応していません。")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "システム設定で Apple Intelligence を有効にしてください。")
        case .unavailable(let reason):
            return .unavailable(reason: String(describing: reason))
        }
        #else
        return .unavailable(reason: "このビルドでは FoundationModels framework を利用できません。")
        #endif
    }

    /// composition 開始時に呼ばれ、モデルのロードと instructions の前処理を
    /// 先に済ませて Shift+Space 時のレイテンシを下げる（ADR-0005）。
    public func prewarm(settings: ConversionSettings) async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        guard case .available = SystemLanguageModel.default.availability else { return }
        // prewarm は日本語のみ。翻訳 6 言語分のセッション常駐を避け、
        // 翻訳セッションは初回要求時にその場で作る（仕様の非機能要件）。
        let instructions = PromptBuilder.instructions(settings: settings, target: .japanese)
        if let box = preparedBoxes[.japanese] as? Prepared, box.instructions == instructions {
            return
        }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        preparedBoxes[.japanese] = Prepared(instructions: instructions, session: session)
        #else
        _ = settings
        #endif
    }

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw KotoError.modelUnavailable("macOS 26 以降が必要です。")
        }
        let instructions = PromptBuilder.instructions(
            settings: request.settings,
            target: request.target
        )
        // モデルへはかな化済み入力（modelInputText）を渡す。表示・Escape 復元・
        // 出力検証は元の sourceText が基準のまま（ADR-0006）。セッション内
        // 文脈（ADR-0013）は instructions ではなくユーザープロンプト側の
        // [CONTEXT] に載せ、prewarm を無効化しない。[CONTEXT] の取り扱い指示を
        // 持つのは日本語 instructions のみ（第一版）なので、指示を持たない
        // 翻訳 instructions に文脈を注入しないことをここでも強制する。
        // 辞書草案（[DRAFT]）の取り扱い指示も日本語 instructions のみが持つので、
        // 翻訳 target には草案を載せない。
        let prompt = PromptBuilder.prompt(
            modelInput: request.modelInputText,
            contextEntries: request.target == .japanese ? request.contextEntries : [],
            dictionaryDraft: request.target == .japanese ? request.dictionaryDraft : nil
        )
        do {
            // target に対応する prewarm 済みセッションがあれば 1 回だけ使う。
            // 無ければその場で作る。どちらも使い捨てで、transcript を次の
            // 変換へ持ち越さない（ADR-0002）。
            let session =
                takePrepared(for: request.target, matching: instructions)
                ?? LanguageModelSession(instructions: instructions)
            // 初回（attempt 0）は greedy で決定的に変換する。再変換（attempt 1
            // 以降）は温度付きサンプリングで別候補を抽選する（Issue 19）。
            let options =
                request.attempt == 0
                ? GenerationOptions(sampling: .greedy)
                : GenerationOptions(temperature: 0.8)
            let response = try await session.respond(to: prompt, options: options)
            return ConversionResult(
                requestID: request.id,
                compositionID: request.compositionID,
                revision: request.revision,
                convertedText: response.content,
                attempt: request.attempt
            )
        } catch is CancellationError {
            throw KotoError.cancelled
        } catch {
            // guardrail 拒否・コンテキスト超過などのフレームワークエラーを
            // 安定したドメインエラーへ写像する。ユーザーテキストは含めない。
            throw KotoError.generationFailed(String(describing: type(of: error)))
        }
        #else
        _ = request
        throw KotoError.modelUnavailable("このビルドでは FoundationModels framework を利用できません。")
        #endif
    }
}
