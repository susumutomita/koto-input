/// フレームワーク固有のエラーを写像した、安定したドメインエラー。
public enum KotoError: Error, Equatable, Sendable {
    case modelUnavailable(String)
    case cancelled
    case emptyInput
    case emptyResponse
    case generationFailed(String)
    case invalidClientState
}

extension KotoError {
    /// ユーザー向けの短い日本語メッセージ。ユーザーテキストは含めない。
    public var userMessage: String {
        switch self {
        case .modelUnavailable(let reason):
            return "モデルを利用できません: \(reason)"
        case .cancelled:
            return "変換をキャンセルしました。"
        case .emptyInput:
            return "変換対象のテキストがありません。"
        case .emptyResponse, .generationFailed:
            return "変換に失敗しました。元のテキストを保持しています。"
        case .invalidClientState:
            return "入力先の状態が不正です。"
        }
    }
}
