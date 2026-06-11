import KotoCore
import Testing

@Suite("ConversionOutputValidator の出力検証")
struct ConversionOutputValidatorTests {
    @Test("先頭と末尾の改行だけ除去し、内部の改行は保持する")
    func trimsOnlyLineEndings() {
        let result = ConversionOutputValidator.validate(
            output: "\n今日は雨です。\n明日は晴れです。\r\n",
            source: "kyou ha ame, ashita ha hare.",
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
            source: "kyou ha ame.",
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

    @Test("元テキストが句読点で終わらなければ、出力末尾の句点を取り除く")
    func stripsSpuriousTrailingPeriod() {
        let result = ConversionOutputValidator.validate(
            output: "SWIFTはいい言語です。",
            source: "SWIFThaiigengodesu",
            settings: .default
        )
        #expect(result == .success("SWIFTはいい言語です"))
        // 文中の句点は保持し、末尾だけ取り除く。
        let multi = ConversionOutputValidator.validate(
            output: "今日は雨です。明日は晴れです。",
            source: "kyou ha ame ashita ha hare",
            settings: .default
        )
        #expect(multi == .success("今日は雨です。明日は晴れです"))
        // 全角ピリオドも同様に取り除く。
        let fullWidth = ConversionOutputValidator.validate(
            output: "今日は雨です．",
            source: "kyou ha ame",
            settings: .default
        )
        #expect(fullWidth == .success("今日は雨です"))
    }

    @Test("元テキストが句読点で終わっていれば、出力末尾の句点を保持する")
    func keepsIntendedTrailingPeriod() {
        let result = ConversionOutputValidator.validate(
            output: "今日は雨です。",
            source: "kyou ha ame.",
            settings: .default
        )
        #expect(result == .success("今日は雨です。"))
        // 末尾の空白・改行は無視して元テキストの句読点を判定する。
        let padded = ConversionOutputValidator.validate(
            output: "今日は雨です。",
            source: "kyou ha ame. \n",
            settings: .default
        )
        #expect(padded == .success("今日は雨です。"))
    }

    @Test("鉤括弧の除去後に残った末尾の句点も取り除く")
    func stripsPeriodAfterUnwrappingBrackets() {
        let result = ConversionOutputValidator.validate(
            output: "「今日は雨です。」",
            source: "kyou ha ame",
            settings: .default
        )
        #expect(result == .success("今日は雨です"))
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
            source: "Claude Code wo naosu.",
            settings: .default
        )
        #expect(result == .success("Claude Code を直します。"))
    }

    @Test("元テキストの頭字語が出力から消えたら失敗する")
    func lostAcronymFails() {
        // 実機: SWIFThaiigengodesu →「Swiftは、英語です」の表記崩れ + 意味置換。
        let result = ConversionOutputValidator.validate(
            output: "Swiftは、英語です",
            source: "SWIFThaiigengodesu",
            settings: .default
        )
        guard case .failure(.generationFailed(let message)) = result else {
            Issue.record("頭字語の消失が検出されなかった: \(result)")
            return
        }
        #expect(message.contains("SWIFT"))
    }

    @Test("頭字語が残っていれば受理し、大文字 1 文字は頭字語として要求しない")
    func keptAcronymPasses() {
        let result = ConversionOutputValidator.validate(
            output: "SWIFTはいい言語です",
            source: "SWIFThaiigengodesu",
            settings: .default
        )
        #expect(result == .success("SWIFTはいい言語です"))
        // CamelCase の頭などの大文字 1 文字は要求しない。
        let camel = ConversionOutputValidator.validate(
            output: "コードを直す",
            source: "Code wo naosu",
            settings: .default
        )
        #expect(camel == .success("コードを直す"))
    }

    @Test("空白のみの保護語は無視され、検証が恒常失敗しない")
    func whitespaceOnlyProtectedTermIgnored() {
        var settings = ConversionSettings.default
        settings.protectedTerms = [" ", "\t", ""]
        let result = ConversionOutputValidator.validate(
            output: "今日は雨です。",
            source: "kyou ha ame.",
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

    // MARK: - 多言語変換ターゲット

    @Test("英語ターゲットでは出力末尾の句点を strip しない")
    func englishTargetKeepsTrailingPeriod() {
        // 日本語固有の末尾句点 strip は .japanese のみ。訳文の文末句読点は
        // 訳の一部として保持する。
        let result = ConversionOutputValidator.validate(
            output: "Today is a good day。",
            source: "kyouhaiihida",
            settings: .default,
            target: .english
        )
        #expect(result == .success("Today is a good day。"))
    }

    @Test("英語ターゲットでは出力全体を包む鉤括弧を unwrap しない")
    func englishTargetKeepsWrappingBrackets() {
        let result = ConversionOutputValidator.validate(
            output: "「Today」",
            source: "kyou",
            settings: .default,
            target: .english
        )
        #expect(result == .success("「Today」"))
    }

    @Test("英語ターゲットでも保護語の消失は拒否する")
    func englishTargetStillValidatesProtectedTerms() {
        let result = ConversionOutputValidator.validate(
            output: "Fix it with claude code",
            source: "Claude Code wo naosu",
            settings: .default,
            target: .english
        )
        guard case .failure(.generationFailed(let message)) = result else {
            Issue.record("英語ターゲットで保護語の消失が検出されなかった: \(result)")
            return
        }
        #expect(message.contains("Claude Code"))
    }

    @Test("英語ターゲットでも頭字語の消失は拒否する")
    func englishTargetStillValidatesAcronyms() {
        let result = ConversionOutputValidator.validate(
            output: "Swift is a good language",
            source: "SWIFThaiigengodesu",
            settings: .default,
            target: .english
        )
        guard case .failure(.generationFailed(let message)) = result else {
            Issue.record("英語ターゲットで頭字語の消失が検出されなかった: \(result)")
            return
        }
        #expect(message.contains("SWIFT"))
    }

    @Test("英語ターゲットでも空出力の拒否と前後改行の trim は共通で適用される")
    func englishTargetSharesCommonValidation() {
        let empty = ConversionOutputValidator.validate(
            output: " \n",
            source: "kyou",
            settings: .default,
            target: .english
        )
        #expect(empty == .failure(.emptyResponse))
        let trimmed = ConversionOutputValidator.validate(
            output: "\nToday\n",
            source: "kyou",
            settings: .default,
            target: .english
        )
        #expect(trimmed == .success("Today"))
    }

    @Test("英語ターゲットでも膨張率の上限超過は拒否される")
    func englishTargetSharesExpansionLimit() {
        var settings = ConversionSettings.default
        settings.maximumExpansionRatio = 1.0
        let source = "abcd"
        let limit = source.utf16.count + ConversionOutputValidator.fixedAllowance
        let tooLong = String(repeating: "a", count: limit + 1)
        let rejected = ConversionOutputValidator.validate(
            output: tooLong,
            source: source,
            settings: settings,
            target: .english
        )
        guard case .failure(.generationFailed(let message)) = rejected else {
            Issue.record("英語ターゲットで膨張率超過が拒否されなかった: \(rejected)")
            return
        }
        #expect(message.contains("長すぎます"))
    }

    // MARK: - 多言語出力の検証契約（ADR-0010）

    @Test("アラビア語（RTL）出力はラテン保護語を保持したまま Unicode 安全に検証を通る")
    func arabicOutputWithLatinProtectedTermPasses() {
        let result = ConversionOutputValidator.validate(
            output: "أتحقق من Claude Code",
            source: "Claude Code wo kakunin shimasu",
            settings: .default,
            target: .arabic
        )
        #expect(result == .success("أتحقق من Claude Code"))
    }

    @Test("アラビア語ターゲットでも日本語固有の句点 strip・鉤括弧 unwrap は適用しない")
    func arabicTargetSkipsJapaneseSpecificFixups() {
        let result = ConversionOutputValidator.validate(
            output: "「اليوم يوم جميل。」",
            source: "kyou ha ii hi da",
            settings: .default,
            target: .arabic
        )
        #expect(result == .success("「اليوم يوم جميل。」"))
    }

    @Test("日本語原文より大幅に短い英語出力は、空でない限り拒否されない")
    func shortEnglishOutputIsNotRejected() {
        let result = ConversionOutputValidator.validate(
            output: "Got it",
            source: "shouchi shimashita yoroshiku onegai itashimasu",
            settings: .default,
            target: .english
        )
        #expect(result == .success("Got it"))
    }

    @Test("保護語が消えた多言語出力は target によらず拒否される")
    func multilingualOutputLosingProtectedTermFails() {
        for target in [ConversionTarget.english, .arabic, .korean] {
            let result = ConversionOutputValidator.validate(
                output: "كلود كود を確認",
                source: "Claude Code wo kakunin shimasu",
                settings: .default,
                target: target
            )
            guard case .failure(.generationFailed) = result else {
                Issue.record("\(target) で保護語の消失が検出されなかった: \(result)")
                return
            }
        }
    }

    @Test("検証失敗のエラーメッセージに source / output の本文を混入させない")
    func failureMessagesDoNotLeakUserText() {
        // 保護語消失: メッセージに含まれるのは保護語名のみで、原文・出力の
        // 本文は含まれない（プライバシー制約。ADR-0010）。
        let source = "Claude Code de himitsu no shiryou wo naosu"
        let output = "極秘の資料をクロードコードで直す"
        let lostTerm = ConversionOutputValidator.validate(
            output: output,
            source: source,
            settings: .default,
            target: .english
        )
        guard case .failure(let error) = lostTerm,
            case .generationFailed(let message) = error
        else {
            Issue.record("保護語の消失が検出されなかった: \(lostTerm)")
            return
        }
        #expect(!message.contains(source))
        #expect(!message.contains(output))
        #expect(!error.userMessage.contains(source))
        #expect(!error.userMessage.contains(output))

        // 膨張率超過: メッセージに含まれるのは長さの数値のみ。
        var settings = ConversionSettings.default
        settings.maximumExpansionRatio = 1.0
        let longOutput = String(
            repeating: "秘",
            count: 16 + ConversionOutputValidator.fixedAllowance
        )
        let tooLong = ConversionOutputValidator.validate(
            output: longOutput,
            source: "mijikai",
            settings: settings,
            target: .english
        )
        guard case .failure(.generationFailed(let lengthMessage)) = tooLong else {
            Issue.record("膨張率超過が拒否されなかった: \(tooLong)")
            return
        }
        #expect(!lengthMessage.contains(longOutput))
        #expect(!lengthMessage.contains("mijikai"))
    }
}
