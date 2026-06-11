/// 同一の原文スナップショットに対する変換候補。
///
/// 不変条件: この型の値は ConversionOutputValidator を通過して converted と
/// して表示された結果だけから作られる（検証通過済み）。未検証の出力を候補に
/// しないこと。
///
/// 入力モードの区別は target から導出する（.japanese = 日本語変換、それ以外 =
/// 翻訳）。生成時の出力プロファイル等の設定は候補の同一性に関与しないため
/// 保持しない。メタデータは reducer が既に知っている状態
/// （conversionTarget / retryCount）から導出する（ADR-0012）。
public struct ConversionCandidate: Equatable, Sendable {
    /// 検証通過済みの変換結果テキスト。
    public let text: String
    /// この候補を生成した変換のターゲット言語。
    public let target: ConversionTarget
    /// 同じ原文・同じ target に対する再変換（再抽選）の何回目で得られたか。
    /// 0 が初回（greedy）、1 以降が温度付き再抽選（ADR-0008）。
    public let attempt: Int

    public init(text: String, target: ConversionTarget, attempt: Int) {
        self.text = text
        self.target = target
        self.attempt = attempt
    }
}
