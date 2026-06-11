import Foundation

/// 文体の指定。
public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case neutral
    case polite
    case plain
}

/// 多言語出力のトーンプロファイル（ADR-0010）。翻訳 instructions の
/// [STYLE] セクションへ写像する。日本語変換の WritingStyle とは独立で、
/// 保護語・検証の挙動は変えない。
public enum OutputProfile: String, Codable, CaseIterable, Sendable, Equatable {
    case neutral
    case polite
    case business
    case casual
    case technical
}

/// 変換要求にスナップショットされる設定値。
public struct ConversionSettings: Equatable, Sendable, Codable {
    public var style: WritingStyle
    public var customInstruction: String
    /// 出力に必ず原文どおり残すべき固有名詞・製品名。
    public var protectedTerms: [String]
    /// 出力長の上限 = 元テキストの UTF-16 長 × この倍率 + 固定許容量。
    public var maximumExpansionRatio: Double
    /// 多言語出力のトーンプロファイル。日本語変換には適用しない（ADR-0010）。
    public var outputProfile: OutputProfile

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
        maximumExpansionRatio: Double = 4.0,
        outputProfile: OutputProfile = .neutral
    ) {
        self.style = style
        self.customInstruction = customInstruction
        self.protectedTerms = protectedTerms
        self.maximumExpansionRatio = maximumExpansionRatio
        self.outputProfile = outputProfile
    }

    private enum CodingKeys: String, CodingKey {
        case style
        case customInstruction
        case protectedTerms
        case maximumExpansionRatio
        case outputProfile
    }

    /// 後方互換の decode（ADR-0010）。既存フィールドは従来どおり必須のまま、
    /// outputProfile はフィールドが無い旧 JSON でも既定値で成功させる。
    /// 未知の文字列値（将来のプロファイル等）は失敗ではなく .neutral へ
    /// 決定論的にフォールバックし、設定全体が default へ巻き戻るのを防ぐ。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decode(WritingStyle.self, forKey: .style)
        customInstruction = try container.decode(String.self, forKey: .customInstruction)
        protectedTerms = try container.decode([String].self, forKey: .protectedTerms)
        maximumExpansionRatio = try container.decode(
            Double.self,
            forKey: .maximumExpansionRatio
        )
        let rawProfile = try container.decodeIfPresent(
            String.self,
            forKey: .outputProfile
        )
        outputProfile = rawProfile.flatMap(OutputProfile.init(rawValue:)) ?? .neutral
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
