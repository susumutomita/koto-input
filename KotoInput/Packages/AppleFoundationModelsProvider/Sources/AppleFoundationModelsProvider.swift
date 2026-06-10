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
/// リクエストの直列化は CompositionCoordinator が保証する（変換タスクは常に
/// 1 本で、新しい要求は既存タスクをキャンセルする）。
public struct AppleFoundationModelsProvider: TextConversionProvider {
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

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw KotoError.modelUnavailable("macOS 26 以降が必要です。")
        }
        let instructions = PromptBuilder.instructions(settings: request.settings)
        let prompt = PromptBuilder.prompt(sourceText: request.sourceText)
        do {
            // セッションは要求ごとに使い捨てる。transcript を持ち越すと過去の
            // 変換入力が次の変換に影響し、コンテキスト長も増えるため（ADR-0002）。
            // sampling は greedy 固定。入力変換は同じ入力に同じ出力を返すべきで、
            // 温度付きサンプリングだと変換結果が毎回揺れる。
            let session = LanguageModelSession(instructions: instructions)
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
