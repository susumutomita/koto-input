/// 「1 行へ正規化する」規則の正本。改行（Character.isNewline が真の全文字。
/// U+2028 / U+2029 を含む）を半角スペースへ潰す。SessionContextStore
/// （保存時）と PromptBuilder.bulletList（プロンプト構築時の信頼境界）の
/// 両方がこれを使い、防御の多重化は保ったまま正規化規則の乖離
/// （片側だけ改行の定義が変わる等）を防ぐ。
extension String {
    var collapsedToSingleLine: String {
        split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }
}
