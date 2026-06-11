/// プラットフォームのキーイベントから翻訳されたドメインコマンド。
/// InputController はキーイベントをこのコマンドに変換してから状態を変更する。
public enum CompositionCommand: Sendable {
    case insert(String)
    case deleteBackward
    case moveCursor(offset: Int)
    case replaceSelection(String)
    /// composition をターゲット言語へ AI 変換する。Shift + Space は
    /// .japanese、Ctrl + Shift + 言語キーは翻訳ターゲットを指定する。
    case requestConversion(ConversionTarget)
    /// Ctrl + Shift + Space の文脈つき日本語 AI 変換（Issue 46、ADR-0013）。
    /// セッション内文脈メモリを [CONTEXT] として付与する点以外は
    /// requestConversion(.japanese) と同じ規則に従う。第一版は日本語
    /// target のみなので関連値を持たない。
    case requestContextualConversion
    /// composition 全体をその場で決定論的にひらがな化する（AI 不要・即時）。
    case normalizeToKana
    /// 蓄積された変換候補の選択を offset だけ移動する（+1 = 次、-1 = 前）。
    /// converted で候補が 2 件以上のときだけ有効（それ以外は noop）。
    case selectCandidate(offset: Int)
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
