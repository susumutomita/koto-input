/// 文体の指定。
public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case neutral
    case polite
    case plain
}

/// 変換要求にスナップショットされる設定値。
public struct ConversionSettings: Equatable, Sendable, Codable {
    public var style: WritingStyle
    public var customInstruction: String
    /// 出力に必ず原文どおり残すべき固有名詞・製品名。
    public var protectedTerms: [String]
    /// 出力長の上限 = 元テキストの UTF-16 長 × この倍率 + 固定許容量。
    public var maximumExpansionRatio: Double

    public init(
        style: WritingStyle = .neutral,
        customInstruction: String = "",
        protectedTerms: [String] = ConversionSettings.defaultProtectedTerms,
        maximumExpansionRatio: Double = 4.0
    ) {
        self.style = style
        self.customInstruction = customInstruction
        self.protectedTerms = protectedTerms
        self.maximumExpansionRatio = maximumExpansionRatio
    }

    public static let defaultProtectedTerms: [String] = [
        "Claude Code",
        "Codex",
        "TenkaCloud",
        "MagicStack",
        "InputMethodKit",
        "FoundationModels",
    ]

    public static let `default` = ConversionSettings()
}
