/// プラットフォームのキーイベントから翻訳されたドメインコマンド。
/// InputController はキーイベントをこのコマンドに変換してから状態を変更する。
public enum CompositionCommand: Sendable {
    case insert(String)
    case deleteBackward
    case moveCursor(offset: Int)
    case replaceSelection(String)
    case requestConversion
    /// composition 全体をその場で決定論的にひらがな化する（AI 不要・即時）。
    case normalizeToKana
    case conversionSucceeded(ConversionResult)
    case conversionFailed(
        requestID: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        error: KotoError
    )
    case restoreSource
    case commit
    case cancel
    case deactivate
}
