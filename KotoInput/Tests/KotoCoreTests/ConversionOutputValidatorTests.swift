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

    @Test("元テキストに括弧が無ければ、出力全体を包む鉤括弧を取り除く")
    func unwrapsSpuriousBrackets() {
        let result = ConversionOutputValidator.validate(
            output: "「真っ黒くろすけ出ておいで」",
            source: "makkurokurosuke deteoide",
            settings: .default
        )
        #expect(result == .success("真っ黒くろすけ出ておいで"))
        let double = ConversionOutputValidator.validate(
            output: "『出てこい』",
            source: "detekoi",
            settings: .default
        )
        #expect(double == .success("出てこい"))
    }

    @Test("元テキストに括弧の意図があれば、出力の鉤括弧は保持する")
    func keepsIntendedBrackets() {
        let result = ConversionOutputValidator.validate(
            output: "「出てこい」",
            source: "[detekoi]",
            settings: .default
        )
        #expect(result == .success("「出てこい」"))
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

    @Test("空白のみの保護語は無視され、検証が恒常失敗しない")
    func whitespaceOnlyProtectedTermIgnored() {
        var settings = ConversionSettings.default
        settings.protectedTerms = [" ", "\t", ""]
        let result = ConversionOutputValidator.validate(
            output: "今日は雨です。",
            source: "kyou ha ame",
            settings: settings
        )
        #expect(result == .success("今日は雨です。"))
    }

    @Test("前後空白付きの保護語も trim して喪失を検出する")
    func paddedProtectedTermStillValidated() {
        var settings = ConversionSettings.default
        settings.protectedTerms = [" Claude Code "]
        let result = ConversionOutputValidator.validate(
            output: "クロードコードを直す",
            source: "Claude Code wo naosu",
            settings: settings
        )
        guard case .failure(.generationFailed(let message)) = result else {
            Issue.record("trim 後の保護語の消失が検出されなかった: \(result)")
            return
        }
        #expect(message.contains("Claude Code"))
    }
}
