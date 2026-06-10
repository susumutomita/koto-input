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
    /// prewarm で温めたセッションの置き場。instructions が一致する次の変換で
    /// 1 回だけ使う。actor の stored property に @available 型を直接置けない
    /// ため AnyObject で持ち、利用側でキャストする。
    private var preparedBox: AnyObject?

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
    private func takePrepared(matching instructions: String) -> LanguageModelSession? {
        guard
            let box = preparedBox as? Prepared,
            box.instructions == instructions
        else {
            return nil
        }
        preparedBox = nil
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
        let instructions = PromptBuilder.instructions(settings: settings)
        if let box = preparedBox as? Prepared, box.instructions == instructions {
            return
        }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        preparedBox = Prepared(instructions: instructions, session: session)
        #else
        _ = settings
        #endif
    }

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw KotoError.modelUnavailable("macOS 26 以降が必要です。")
        }
        let instructions = PromptBuilder.instructions(settings: request.settings)
        let prompt = PromptBuilder.prompt(sourceText: request.sourceText)
        do {
            // prewarm 済みセッションがあれば 1 回だけ使う。無ければその場で作る。
            // どちらも使い捨てで、transcript を次の変換へ持ち越さない（ADR-0002）。
            let session =
                takePrepared(matching: instructions)
                ?? LanguageModelSession(instructions: instructions)
            // sampling は greedy 固定。入力変換は同じ入力に同じ出力を返すべきで、
            // 温度付きサンプリングだと変換結果が毎回揺れる。
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(sampling: .greedy)
            )
            return ConversionResult(
                requestID: request.id,
                compositionID: request.compositionID,
                revision: request.revision,
                convertedText: response.content
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
