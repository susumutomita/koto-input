import KotoCore
import Testing

@Suite("ConversionOutputValidator の出力検証")
struct ConversionOutputValidatorTests {
    @Test("先頭と末尾の改行だけ除去し、内部の改行は保持する")
    func trimsOnlyLineEndings() {
        let result = ConversionOutputValidator.validate(
            output: "\n今日は雨です。\n明日は晴れです。\r\n",
            source: "kyou ha ame, ashita ha hare",
            settings: .default
        )
        #expect(result == .success("今日は雨です。\n明日は晴れです。"))
    }

    @Test("空の出力は emptyResponse として失敗する")
    func emptyOutputFails() {
        let result = ConversionOutputValidator.validate(
            output: "",
            source: "abc",
            settings: .default
        )
        #expect(result == .failure(.emptyResponse))
    }

    @Test("空白のみの出力は emptyResponse として失敗する")
    func whitespaceOnlyOutputFails() {
        let result = ConversionOutputValidator.validate(
            output: " \n\t \n",
            source: "abc",
            settings: .default
        )
        #expect(result == .failure(.emptyResponse))
    }

    @Test("膨張率の上限以内の出力は受理し、超過は拒否する")
    func expansionRatioBoundary() {
        var settings = ConversionSettings.default
        settings.maximumExpansionRatio = 1.0
        let source = "abcd"
        let limit = source.utf16.count + ConversionOutputValidator.fixedAllowance
        let ok = String(repeating: "あ", count: limit)
        let tooLong = String(repeating: "あ", count: limit + 1)
        #expect(
            ConversionOutputValidator.validate(
                output: ok,
                source: source,
                settings: settings
            ) == .success(ok)
        )
        let rejected = ConversionOutputValidator.validate(
            output: tooLong,
            source: source,
            settings: settings
        )
        guard case .failure(.generationFailed(let message)) = rejected else {
            Issue.record("膨張率超過の出力が拒否されなかった: \(rejected)")
            return
        }
        #expect(message.contains("長すぎます"))
    }

    @Test("元テキストにある保護語が出力から消えたら失敗する")
    func lostProtectedTermFails() {
        let result = ConversionOutputValidator.validate(
            output: "クロードコードを直す",
            source: "Claude Code wo naosu",
            settings: .default
        )
        guard case .failure(.generationFailed(let message)) = result else {
            Issue.record("保護語の消失が検出されなかった: \(result)")
            return
        }
        #expect(message.contains("Claude Code"))
    }

    @Test("元テキストに無い保護語は出力に要求しない")
    func absentProtectedTermNotRequired() {
        let result = ConversionOutputValidator.validate(
            output: "今日は雨です。",
            source: "kyou ha ame",
            settings: .default
        )
        #expect(result == .success("今日は雨です。"))
    }

    @Test("保護語が残っていれば受理する")
    func keptProtectedTermPasses() {
        let result = ConversionOutputValidator.validate(
            output: "Claude Code を直します。",
            source: "Claude Code wo naosu",
            settings: .default
        )
        #expect(result == .success("Claude Code を直します。"))
    }
}
