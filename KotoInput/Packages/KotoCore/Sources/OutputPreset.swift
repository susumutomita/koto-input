import Foundation

/// アプリ別多言語出力プリセット（ADR-0011、Issue 37）。プリセットは
/// OutputProfile とプリセット固有の追加プロンプト要求の「名前付き束」であり、
/// 保護語・出力検証・候補確定の挙動は変えない。
///
/// - ケース名は出力先の用途で命名し、特定の製品名（Claude Code / Codex /
///   Slack / GitHub 等）をハードコードしない。製品名は displayName での
///   例示にとどめる。
/// - アプリ検出は実装しない。適用は ConversionSettings.appAwarePresetsEnabled
///   による明示的な opt-in のみで、アプリ内容の保存・送信・ログもしない
///   （ADR-0010 のプライバシー制約を踏襲）。
public enum OutputPreset: String, Codable, CaseIterable, Sendable {
    /// 既定。追加指示を持たず、ユーザーの outputProfile 設定をそのまま使う。
    case standard
    /// Slack 等のチャット向け。
    case chat
    /// メール本文向け。
    case email
    /// GitHub Issue・PR などのコードレビュー文脈向け。
    case codeReview
    /// AI エージェント CLI（Claude Code / Codex 等）へのプロンプト向け。
    /// 特定製品に限定しない汎用ケース。
    case agentPrompt

    /// プリセットが束ねるトーンプロファイル。写像はテストで固定する。
    public var profile: OutputProfile {
        switch self {
        case .standard:
            return .neutral
        case .chat:
            return .casual
        case .email:
            return .business
        case .codeReview:
            return .technical
        case .agentPrompt:
            return .technical
        }
    }

    /// 設定 UI 用の表示名（日本語）。製品名は「等」を付けた例示であり、
    /// 対応コンテキストを限定しない。
    public var displayName: String {
        switch self {
        case .standard:
            return "標準"
        case .chat:
            return "チャット（Slack 等）"
        case .email:
            return "メール"
        case .codeReview:
            return "コードレビュー（GitHub Issue・PR 等）"
        case .agentPrompt:
            return "AI エージェントプロンプト（Claude Code 等）"
        }
    }

    /// プリセット固有の追加プロンプト要求。翻訳 instructions の [STYLE]
    /// セクションへ 1 行追記する（PromptBuilder）。「入力に無い情報を
    /// 足さない」原則（ADR-0010）と矛盾する指示は持たない。
    public var presetInstruction: String? {
        switch self {
        case .standard:
            return nil
        case .chat:
            return "チャット投稿として短く砕けた表現にする。入力に無い挨拶や絵文字を足さない。"
        case .email:
            return "メール本文として整える。入力に無い件名・宛名・挨拶・署名を勝手に足さない。"
        case .codeReview:
            return "Markdown の構造と Issue・PR 参照を原文どおり保持する。"
        case .agentPrompt:
            return "AI エージェントへの指示として命令形で簡潔にする。コマンド・ファイルパス・コードを一切変えない。"
        }
    }
}
