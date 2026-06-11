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
        settings: ConversionSettings,
        target: ConversionTarget = .japanese
    ) -> Result<String, KotoError> {
        var trimmed = trimLineEndings(output)
        if target == .japanese {
            // 末尾句点の strip と鉤括弧の unwrap は日本語の出力癖への対処
            // なので .japanese のみに適用する。訳文の句読点・括弧は訳の
            // 一部として保持する。
            trimmed = stripSpuriousTrailingPeriod(
                unwrapSpuriousBrackets(trimmed, source: source),
                source: source
            )
        }

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
        for term in settings.sanitizedProtectedTerms {
            if source.contains(term) && !trimmed.contains(term) {
                return .failure(.generationFailed("保護語「\(term)」が変換結果から失われました。"))
            }
        }

        // 元テキスト中の頭字語（長さ 2 以上の大文字連続）はユーザーが意図して
        // 打った表記なので、保護語と同様に出力へ原文どおり残す。実機で
        // SWIFT → Swift のような表記崩れと同時の意味置換を観測（Issue 22）。
        for acronym in uppercaseRuns(in: source) {
            if !trimmed.contains(acronym) {
                return .failure(
                    .generationFailed("頭字語「\(acronym)」が変換結果から失われました。")
                )
            }
        }

        return .success(trimmed)
    }

    /// 小型モデルは出力全体を鉤括弧で包む癖がある（実機で観測）。元テキストに
    /// 対応する括弧（「 または [）が無い場合に限り、外側の括弧を取り除く。
    /// 内部の括弧や、入力者が意図した括弧には触れない。
    static func unwrapSpuriousBrackets(_ text: String, source: String) -> String {
        let pairs: [(open: Character, close: Character)] = [
            ("「", "」"),
            ("『", "』"),
        ]
        let sourceHasBracket =
            source.contains("「") || source.contains("『")
            || source.contains("[")
        guard !sourceHasBracket else { return text }
        for pair in pairs {
            if text.count >= 2, text.first == pair.open, text.last == pair.close {
                return String(text.dropFirst().dropLast())
            }
        }
        return text
    }

    /// テキスト中の長さ 2 以上の ASCII 大文字連続（頭字語）を列挙する。
    /// RomajiKanaConverter.convertMixedCaseWord が分割対象とする条件と揃え、
    /// かな化で残した頭字語が生成で失われていないかを検証する。
    /// 大文字 1 文字区切りの CamelCase（KotoInput 等）は対象にしない。
    static func uppercaseRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isASCII, character.isLetter, character.isUppercase {
                current.append(character)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// 小型モデルは入力に無い文末の句点を付け足す癖がある（実機で観測）。
    /// 元テキストが文末句読点で終わっていない場合に限り、出力末尾の句点を
    /// 取り除く。文中の句読点はユーザーの意図か文の整形なので触れない。
    static func stripSpuriousTrailingPeriod(_ text: String, source: String) -> String {
        let sentenceEndings: Set<Character> = [
            "。", "．", ".", "、", ",", "!", "！", "?", "？",
        ]
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmedSource.last, sentenceEndings.contains(last) {
            return text
        }
        var result = Substring(text)
        while let last = result.last, last == "。" || last == "．" {
            result.removeLast()
        }
        return String(result)
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
