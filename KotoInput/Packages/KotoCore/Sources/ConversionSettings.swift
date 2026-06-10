import Foundation

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

    /// 保護語のサニタイズ規則（前後の空白を trim し、空要素を除く）の正本。
    /// raw な配列を受け取る呼び出し側（RomajiKanaConverter 等）もこれを使い、
    /// 定義を 1 箇所に保つ。
    public static func sanitizeProtectedTerms(_ terms: [String]) -> [String] {
        terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 前後の空白を trim し、空要素を除いた保護語。
    /// かな化・プロンプト構築・出力検証は常にこちらを使う。
    public var sanitizedProtectedTerms: [String] {
        Self.sanitizeProtectedTerms(protectedTerms)
    }

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
