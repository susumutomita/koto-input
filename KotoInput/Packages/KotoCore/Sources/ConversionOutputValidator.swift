import Foundation

/// モデル出力の決定論的な検証。プロンプトはセキュリティ境界ではないため、
/// 出力は必ずここを通す。検証に失敗したら元テキストを保持する（破壊的な
/// 自動修復はしない）。
public enum ConversionOutputValidator {
    /// 膨張率に加えて常に許容する固定マージン（UTF-16 長）。
    /// 短い入力で比率検証が過敏になるのを防ぐ。
    public static let fixedAllowance = 64

    public static func validate(
        output: String,
        source: String,
        settings: ConversionSettings
    ) -> Result<String, KotoError> {
        let trimmed = trimLineEndings(output)

        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.emptyResponse)
        }

        let limit =
            Int(settings.maximumExpansionRatio * Double(source.utf16.count))
            + fixedAllowance
        if trimmed.utf16.count > limit {
            return .failure(
                .generationFailed("変換結果が長すぎます（\(trimmed.utf16.count) > \(limit)）。")
            )
        }

        // 元テキストに含まれる保護語は、出力にも原文どおり残っていなければならない。
        // 生成後の機械的な置換は文法を壊すため行わない。
        for term in settings.protectedTerms where !term.isEmpty {
            if source.contains(term) && !trimmed.contains(term) {
                return .failure(.generationFailed("保護語「\(term)」が変換結果から失われました。"))
            }
        }

        return .success(trimmed)
    }

    /// 生成が紛れ込ませた先頭・末尾の改行だけを取り除く。
    /// 内部の空白・改行は意図的なものとして保持する。
    /// CRLF は Swift では 1 つの書記素クラスタになるため、個別の文字比較では
    /// なく Character.isNewline で判定する。
    static func trimLineEndings(_ text: String) -> String {
        var result = Substring(text)
        while let first = result.first, first.isNewline {
            result.removeFirst()
        }
        while let last = result.last, last.isNewline {
            result.removeLast()
        }
        return String(result)
    }
}
