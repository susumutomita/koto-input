import KotoCore
import Testing

@Suite("CompositionTransition の状態遷移")
struct CompositionTransitionTests {
    private let fixedRequestID = ConversionRequestID()

    private func compose(_ text: String) -> CompositionState {
        CompositionTransition.reduce(.idle(), .insert(text)).state
    }

    /// 変換要求コマンド（既定は通常の日本語変換。英語は
    /// `via: .requestConversion(.english)`、文脈つきは
    /// `via: .requestContextualConversion`）を発行した converting 状態。
    private func converting(
        _ text: String,
        via command: CompositionCommand = .requestConversion(.japanese)
    ) -> CompositionState {
        CompositionTransition.reduce(
            compose(text),
            command,
            makeRequestID: { fixedRequestID }
        ).state
    }

    /// converting と同じコマンドを経由して変換を成功させた converted 状態。
    private func converted(
        source: String,
        convertedText: String,
        via command: CompositionCommand = .requestConversion(.japanese)
    ) -> CompositionState {
        let before = converting(source, via: command)
        let result = ConversionResult(
            requestID: fixedRequestID,
            compositionID: before.compositionID,
            revision: before.revision,
            convertedText: convertedText
        )
        return CompositionTransition.reduce(before, .conversionSucceeded(result)).state
    }

    /// converted 状態から編集せずに再要求（同 target 再抽選 / 別 target 切替）
    /// して成功させ、次の converted 状態を返す。
    private func reroll(
        _ state: CompositionState,
        target: ConversionTarget,
        convertedText: String
    ) -> CompositionState {
        let requestID = ConversionRequestID()
        let retrying = CompositionTransition.reduce(
            state,
            .requestConversion(target),
            makeRequestID: { requestID }
        ).state
        let result = ConversionResult(
            requestID: requestID,
            compositionID: retrying.compositionID,
            revision: retrying.activeRequestRevision ?? 0,
            convertedText: convertedText
        )
        return CompositionTransition.reduce(retrying, .conversionSucceeded(result)).state
    }

    // MARK: - 開始と編集

    @Test("idle で文字を挿入すると composing になり marked text を描画する")
    func idleInsertStartsComposing() {
        let outcome = CompositionTransition.reduce(.idle(), .insert("k"))
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "k")
        #expect(outcome.state.sourceText == "k")
        #expect(outcome.view.markedText == "k")
        #expect(outcome.effect == .none)
    }

    @Test("composing の挿入はテキストと revision を更新し sourceText が追従する")
    func composingInsert() {
        let before = compose("k")
        let outcome = CompositionTransition.reduce(before, .insert("o"))
        #expect(outcome.state.displayedText == "ko")
        #expect(outcome.state.revision == before.revision + 1)
        #expect(outcome.state.sourceText == "ko")
    }

    @Test("最後の文字を削除すると composition が終了して idle に戻る")
    func deleteToEmptyEndsComposition() {
        let outcome = CompositionTransition.reduce(compose("k"), .deleteBackward)
        #expect(outcome.state.phase == .idle)
        #expect(outcome.view.markedText == nil)
        #expect(!outcome.view.shouldCommit)
    }

    @Test("idle では commit や削除は何も起こさない")
    func idleIgnoresNonInsertCommands() {
        let commit = CompositionTransition.reduce(.idle(), .commit)
        #expect(commit.state.phase == .idle)
        #expect(!commit.view.shouldCommit)
        let delete = CompositionTransition.reduce(.idle(), .deleteBackward)
        #expect(delete.state.phase == .idle)
        #expect(delete.effect == .none)
    }

    // MARK: - 変換要求

    @Test("変換要求は converting へ遷移しスナップショットを取る")
    func requestConversionStartsConverting() {
        let before = compose("kyou ha ame")
        let outcome = CompositionTransition.reduce(
            before,
            .requestConversion(.japanese),
            makeRequestID: { fixedRequestID }
        )
        #expect(outcome.state.phase == .converting(requestID: fixedRequestID))
        #expect(outcome.state.sourceText == "kyou ha ame")
        #expect(outcome.state.isSourcePreserved)
        #expect(outcome.state.activeRequestRevision == outcome.state.revision)
        #expect(
            outcome.effect
                == .startConversion(
                    requestID: fixedRequestID,
                    compositionID: before.compositionID,
                    revision: outcome.state.revision,
                    sourceText: "kyou ha ame",
                    target: .japanese,
                    useContext: false,
                    attempt: 0
                )
        )
    }

    @Test("converted から編集せずに再要求すると原文から再変換され attempt が増える")
    func retryReconvertsFromSource() {
        let state = converted(source: "kyou", convertedText: "京")
        let retryID = ConversionRequestID()
        let outcome = CompositionTransition.reduce(
            state,
            .requestConversion(.japanese),
            makeRequestID: { retryID }
        )
        #expect(outcome.state.phase == .converting(requestID: retryID))
        // 原文スナップショットから変換し直し、表示も原文へ戻す。
        #expect(outcome.state.sourceText == "kyou")
        #expect(outcome.state.displayedText == "kyou")
        #expect(outcome.state.retryCount == 1)
        #expect(
            outcome.effect
                == .startConversion(
                    requestID: retryID,
                    compositionID: state.compositionID,
                    revision: outcome.state.revision,
                    sourceText: "kyou",
                    target: .japanese,
                    useContext: false,
                    attempt: 1
                )
        )
    }

    @Test("再変換中も Escape で原文へ戻れる")
    func escapeDuringRetryRestoresSource() {
        let state = converted(source: "kyou", convertedText: "京")
        let retrying = CompositionTransition.reduce(state, .requestConversion(.japanese)).state
        let outcome = CompositionTransition.reduce(retrying, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyou")
        #expect(outcome.effect == .cancelConversion)
    }

    @Test("編集を挟んだ変換要求では attempt がリセットされる")
    func editingResetsRetryCount() {
        let state = converted(source: "kyou", convertedText: "京")
        let retried = CompositionTransition.reduce(state, .requestConversion(.japanese)).state
        #expect(retried.retryCount == 1)
        // 編集して composing へ戻ると、次の要求は新しいテキストの初回変換になる。
        let edited = CompositionTransition.reduce(retried, .insert("x")).state
        let outcome = CompositionTransition.reduce(edited, .requestConversion(.japanese))
        #expect(outcome.state.retryCount == 0)
        if case .startConversion(_, _, _, let sourceText, _, let useContext, let attempt) =
            outcome.effect
        {
            #expect(attempt == 0)
            #expect(sourceText == "kyoux")
            #expect(!useContext)
        } else {
            Issue.record("startConversion が発行されなかった: \(outcome.effect)")
        }
    }

    // MARK: - 多言語変換ターゲット

    @Test("composing から英語ターゲットの変換要求で converting になり effect に target が載る")
    func requestEnglishConversionStartsConverting() {
        let before = compose("kyouhaiihida")
        let outcome = CompositionTransition.reduce(
            before,
            .requestConversion(.english),
            makeRequestID: { fixedRequestID }
        )
        #expect(outcome.state.phase == .converting(requestID: fixedRequestID))
        #expect(outcome.state.sourceText == "kyouhaiihida")
        #expect(outcome.state.conversionTarget == .english)
        #expect(
            outcome.effect
                == .startConversion(
                    requestID: fixedRequestID,
                    compositionID: before.compositionID,
                    revision: outcome.state.revision,
                    sourceText: "kyouhaiihida",
                    target: .english,
                    useContext: false,
                    attempt: 0
                )
        )
    }

    @Test("converted（英語）から同じ target の再要求は attempt が増える（再抽選）")
    func sameTargetRetryIncrementsAttempt() {
        let state = converted(
            source: "kyouhaiihida",
            convertedText: "Today is a good day",
            via: .requestConversion(.english)
        )
        let retryID = ConversionRequestID()
        let outcome = CompositionTransition.reduce(
            state,
            .requestConversion(.english),
            makeRequestID: { retryID }
        )
        #expect(outcome.state.retryCount == 1)
        // 原文スナップショットから変換し直し、表示も原文へ戻す。
        #expect(outcome.state.displayedText == "kyouhaiihida")
        #expect(
            outcome.effect
                == .startConversion(
                    requestID: retryID,
                    compositionID: state.compositionID,
                    revision: outcome.state.revision,
                    sourceText: "kyouhaiihida",
                    target: .english,
                    useContext: false,
                    attempt: 1
                )
        )
    }

    @Test("converted（英語）から別 target の要求は attempt 0 で原文から変換し直す")
    func differentTargetRestartsAtAttemptZero() {
        let state = converted(
            source: "kyouhaiihida",
            convertedText: "Today is a good day",
            via: .requestConversion(.english)
        )
        let requestID = ConversionRequestID()
        // Shift + Space で日本語変換へ戻すケース。
        let outcome = CompositionTransition.reduce(
            state,
            .requestConversion(.japanese),
            makeRequestID: { requestID }
        )
        #expect(outcome.state.retryCount == 0)
        #expect(outcome.state.conversionTarget == .japanese)
        // 原文スナップショットは維持され、表示も原文へ戻る。
        #expect(outcome.state.sourceText == "kyouhaiihida")
        #expect(outcome.state.displayedText == "kyouhaiihida")
        #expect(
            outcome.effect
                == .startConversion(
                    requestID: requestID,
                    compositionID: state.compositionID,
                    revision: outcome.state.revision,
                    sourceText: "kyouhaiihida",
                    target: .japanese,
                    useContext: false,
                    attempt: 0
                )
        )
    }

    @Test("converted（日本語）から英語キーで attempt 0 の英語変換に切り替わる")
    func japaneseToEnglishSwitchRestartsAttempt() {
        let state = converted(source: "kyou", convertedText: "今日")
        let retryID = ConversionRequestID()
        let retried = CompositionTransition.reduce(
            state,
            .requestConversion(.japanese),
            makeRequestID: { retryID }
        ).state
        #expect(retried.retryCount == 1)
        let succeeded = CompositionTransition.reduce(
            retried,
            .conversionSucceeded(
                ConversionResult(
                    requestID: retryID,
                    compositionID: retried.compositionID,
                    revision: retried.activeRequestRevision ?? 0,
                    convertedText: "京"
                )
            )
        ).state
        // 再抽選後の converted から別 target を要求すると attempt 0 へ戻る。
        let outcome = CompositionTransition.reduce(succeeded, .requestConversion(.english))
        #expect(outcome.state.retryCount == 0)
        #expect(outcome.state.conversionTarget == .english)
        if case .startConversion(_, _, _, let sourceText, let target, let useContext, let attempt)
            = outcome.effect
        {
            #expect(sourceText == "kyou")
            #expect(target == .english)
            #expect(!useContext)
            #expect(attempt == 0)
        } else {
            Issue.record("startConversion が発行されなかった: \(outcome.effect)")
        }
    }

    @Test("converted（英語）からの Escape で元のローマ字テキストへ復元される")
    func escapeAfterEnglishConversionRestoresSource() {
        let state = converted(
            source: "kyouhaiihida",
            convertedText: "Today is a good day",
            via: .requestConversion(.english)
        )
        let outcome = CompositionTransition.reduce(state, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyouhaiihida")
        #expect(!outcome.state.isSourcePreserved)
    }

    @Test("converted（英語）後の編集で attempt がリセットされ復元対象が編集後になる")
    func editingAfterEnglishConversionResetsAttempt() {
        let state = converted(
            source: "kyouhaiihida",
            convertedText: "Today is a good day",
            via: .requestConversion(.english)
        )
        let retried = CompositionTransition.reduce(state, .requestConversion(.english)).state
        #expect(retried.retryCount == 1)
        let edited = CompositionTransition.reduce(retried, .insert("ne")).state
        let outcome = CompositionTransition.reduce(edited, .requestConversion(.english))
        #expect(outcome.state.retryCount == 0)
        if case .startConversion(_, _, _, let sourceText, let target, let useContext, let attempt)
            = outcome.effect
        {
            #expect(sourceText == "kyouhaiihidane")
            #expect(target == .english)
            #expect(!useContext)
            #expect(attempt == 0)
        } else {
            Issue.record("startConversion が発行されなかった: \(outcome.effect)")
        }
    }

    // MARK: - 文脈つき変換（Ctrl + Shift + Space、Issue 46）

    @Test("requestContextualConversion は target japanese・useContext true・attempt 0 で開始する")
    func contextualConversionStartsWithContext() {
        let before = compose("arewoyatteoite")
        let outcome = CompositionTransition.reduce(
            before,
            .requestContextualConversion,
            makeRequestID: { fixedRequestID }
        )
        #expect(outcome.state.phase == .converting(requestID: fixedRequestID))
        #expect(outcome.state.conversionTarget == .japanese)
        #expect(outcome.state.conversionUsedContext)
        #expect(outcome.state.sourceText == "arewoyatteoite")
        #expect(
            outcome.effect
                == .startConversion(
                    requestID: fixedRequestID,
                    compositionID: before.compositionID,
                    revision: outcome.state.revision,
                    sourceText: "arewoyatteoite",
                    target: .japanese,
                    useContext: true,
                    attempt: 0
                )
        )
    }

    @Test("converted（文脈つき）から同じコマンドの再要求は attempt が増える（再抽選）")
    func contextualRetryIncrementsAttempt() {
        let state = converted(
            source: "arewo",
            convertedText: "あれを",
            via: .requestContextualConversion
        )
        let retryID = ConversionRequestID()
        let outcome = CompositionTransition.reduce(
            state,
            .requestContextualConversion,
            makeRequestID: { retryID }
        )
        #expect(outcome.state.retryCount == 1)
        // 原文スナップショットから変換し直し、表示も原文へ戻す。
        #expect(outcome.state.displayedText == "arewo")
        #expect(
            outcome.effect
                == .startConversion(
                    requestID: retryID,
                    compositionID: state.compositionID,
                    revision: outcome.state.revision,
                    sourceText: "arewo",
                    target: .japanese,
                    useContext: true,
                    attempt: 1
                )
        )
    }

    @Test("converted（文脈つき）から Shift + Space の通常変換は attempt 0 で候補蓄積を継続する")
    func contextualToPlainConversionRestartsAttempt() {
        let state = converted(
            source: "arewo",
            convertedText: "あれを",
            via: .requestContextualConversion
        )
        #expect(state.candidates.count == 1)
        let requestID = ConversionRequestID()
        // attempt の同一性判定キーは（target, useContext）。同じ日本語 target
        // でも useContext が変われば attempt 0 の greedy から始まる。
        let outcome = CompositionTransition.reduce(
            state,
            .requestConversion(.japanese),
            makeRequestID: { requestID }
        )
        #expect(outcome.state.retryCount == 0)
        #expect(!outcome.state.conversionUsedContext)
        // 同一スナップショットへの再要求なので候補の蓄積は継続する。
        #expect(outcome.state.candidates.count == 1)
        if case .startConversion(_, _, _, _, let target, let useContext, let attempt) =
            outcome.effect
        {
            #expect(target == .japanese)
            #expect(!useContext)
            #expect(attempt == 0)
        } else {
            Issue.record("startConversion が発行されなかった: \(outcome.effect)")
        }
    }

    @Test("converted（通常）から文脈つき再要求も attempt 0 で候補蓄積を継続する")
    func plainToContextualConversionRestartsAttempt() {
        let state = converted(source: "arewo", convertedText: "あれを")
        #expect(state.candidates.count == 1)
        let requestID = ConversionRequestID()
        let outcome = CompositionTransition.reduce(
            state,
            .requestContextualConversion,
            makeRequestID: { requestID }
        )
        #expect(outcome.state.retryCount == 0)
        #expect(outcome.state.conversionUsedContext)
        #expect(outcome.state.candidates.count == 1)
        if case .startConversion(_, _, _, _, let target, let useContext, let attempt) =
            outcome.effect
        {
            #expect(target == .japanese)
            #expect(useContext)
            #expect(attempt == 0)
        } else {
            Issue.record("startConversion が発行されなかった: \(outcome.effect)")
        }
    }

    @Test("文脈が結果を変えないとき、文脈つき変換の同一テキストは候補に重複追加されない")
    func contextualResultWithSameTextDoesNotDuplicateCandidate() {
        // 文脈が空（または参照すべき曖昧さが無い）場合、文脈つき変換は通常
        // 変換と同じ結果になり得る。候補の同一性キーは text + target のまま
        // （ADR-0012）なので、同一テキストは重複追加されず選択し直しになる。
        let state = converted(source: "arewo", convertedText: "あれを")
        let requestID = ConversionRequestID()
        let outcome = CompositionTransition.reduce(
            state,
            .requestContextualConversion,
            makeRequestID: { requestID }
        )
        let result = ConversionResult(
            requestID: requestID,
            compositionID: outcome.state.compositionID,
            revision: outcome.state.revision,
            convertedText: "あれを"
        )
        let next = CompositionTransition.reduce(
            outcome.state,
            .conversionSucceeded(result)
        ).state
        #expect(next.candidates.count == 1)
        #expect(next.selectedCandidateIndex == 0)
        #expect(next.displayedText == "あれを")
    }

    @Test("idle の requestContextualConversion は何も起こさない")
    func contextualConversionInIdleIsNoop() {
        let outcome = CompositionTransition.reduce(.idle(), .requestContextualConversion)
        #expect(outcome.state.phase == .idle)
        #expect(outcome.effect == .none)
        #expect(outcome.view.markedText == nil)
    }

    @Test("空白のみのテキストでは文脈つき変換要求を無視する")
    func contextualConversionIgnoresWhitespaceOnly() {
        let before = compose("   ")
        let outcome = CompositionTransition.reduce(before, .requestContextualConversion)
        #expect(outcome.state == before)
        #expect(outcome.effect == .none)
    }

    @Test("normalizeToKana は composition をその場でひらがな化する")
    func normalizeToKanaConverts() {
        let before = compose("kyou ha ame")
        let outcome = CompositionTransition.reduce(before, .normalizeToKana)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "きょう は あめ")
        #expect(outcome.state.revision == before.revision + 1)
        #expect(outcome.state.selection == .cursor(at: "きょう は あめ".utf16.count))
    }

    @Test("normalizeToKana は保護語をかな化から除外する")
    func normalizeToKanaProtectsTerms() {
        let before = compose("bun wo tukau")
        let outcome = CompositionTransition.reduce(
            before,
            .normalizeToKana,
            protectedTerms: ["bun"]
        )
        #expect(outcome.state.displayedText == "bun を つかう")
    }

    @Test("converting 中の normalizeToKana は prefix が変わるため変換をキャンセルする")
    func normalizeToKanaDuringConversionCancels() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(before, .normalizeToKana)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "きょう")
        #expect(outcome.effect == .cancelConversion)
    }

    @Test("空白のみのテキストでは変換要求を無視する")
    func requestConversionIgnoresWhitespaceOnly() {
        let before = compose("   ")
        let outcome = CompositionTransition.reduce(before, .requestConversion(.japanese))
        #expect(outcome.state == before)
        #expect(outcome.effect == .none)
    }

    @Test("converting 中の末尾追記は変換を継続する（タイプ先行）")
    func appendDuringConversionContinues() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(before, .insert("x"))
        #expect(outcome.state.phase == before.phase)
        #expect(outcome.state.displayedText == "kyoux")
        #expect(outcome.effect == .none)
        #expect(outcome.state.sourceText == "kyou")
        #expect(outcome.state.activeRequestRevision == before.activeRequestRevision)
    }

    @Test("converting 中にスナップショット内を編集するとキャンセルされる")
    func editingSnapshotDuringConversionCancels() {
        let before = converting("kyou")
        // カーソルを先頭へ移動してから挿入し、スナップショットの先頭一致を壊す。
        let moved = CompositionTransition.reduce(before, .moveCursor(offset: -4)).state
        let outcome = CompositionTransition.reduce(moved, .insert("x"))
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "xkyou")
        #expect(outcome.effect == .cancelConversion)
        #expect(outcome.state.activeRequestRevision == nil)
    }

    @Test("converting 中の deleteBackward でスナップショットが崩れたらキャンセルされる")
    func backspaceIntoSnapshotCancels() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(before, .deleteBackward)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyo")
        #expect(outcome.effect == .cancelConversion)
    }

    @Test("タイプ先行中の変換結果はスナップショット部分だけを差し替える")
    func spliceKeepsTypedTail() {
        let before = converting("kyou")
        let appended = CompositionTransition.reduce(before, .insert(" ashita")).state
        let result = ConversionResult(
            requestID: fixedRequestID,
            compositionID: appended.compositionID,
            revision: appended.activeRequestRevision ?? 0,
            convertedText: "今日"
        )
        let outcome = CompositionTransition.reduce(appended, .conversionSucceeded(result))
        #expect(outcome.state.displayedText == "今日 ashita")
        #expect(outcome.state.phase == .composing)
        // 追記分を失わないため、splice 後は Escape 復元を無効化する。
        #expect(!outcome.state.isSourcePreserved)
        // カーソルは差分（"今日".utf16 - "kyou".utf16 = -2）だけシフトされる。
        #expect(outcome.state.selection == .cursor(at: "今日 ashita".utf16.count))
    }

    @Test("タイプ先行中の Escape は追記分を保持して変換だけを中止する")
    func escapeDuringTypeAheadKeepsTail() {
        let before = converting("kyou")
        let appended = CompositionTransition.reduce(before, .insert("x")).state
        let outcome = CompositionTransition.reduce(appended, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyoux")
        #expect(outcome.effect == .cancelConversion)
        #expect(!outcome.state.isSourcePreserved)
    }

    @Test("タイプ先行中に失敗しても追記分は保持され、Escape でテキストが残る")
    func failureDuringTypeAheadKeepsTail() {
        let before = converting("kyou")
        let appended = CompositionTransition.reduce(before, .insert("x")).state
        let failed = CompositionTransition.reduce(
            appended,
            .conversionFailed(
                requestID: fixedRequestID,
                compositionID: appended.compositionID,
                revision: appended.activeRequestRevision ?? 0,
                error: .emptyResponse
            )
        ).state
        #expect(failed.displayedText == "kyoux")
        let outcome = CompositionTransition.reduce(failed, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyoux")
    }

    @Test("converting 中のカーソル移動は変換を継続する")
    func moveCursorDuringConversionKeepsPhase() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(before, .moveCursor(offset: -1))
        #expect(outcome.state.phase == before.phase)
        #expect(outcome.state.revision == before.revision)
        #expect(outcome.effect == .none)
    }

    // MARK: - 変換結果の適用と stale 拒否

    @Test("一致する変換結果は converted として表示テキストを置き換える")
    func matchingResultApplies() {
        let before = converting("kyou")
        let result = ConversionResult(
            requestID: fixedRequestID,
            compositionID: before.compositionID,
            revision: before.revision,
            convertedText: "今日"
        )
        let outcome = CompositionTransition.reduce(before, .conversionSucceeded(result))
        #expect(outcome.state.phase == .converted(requestID: fixedRequestID))
        #expect(outcome.state.displayedText == "今日")
        #expect(outcome.state.sourceText == "kyou")
        #expect(outcome.view.markedText == "今日")
    }

    @Test("requestID が一致しない変換結果は無視する")
    func staleRequestIDRejected() {
        let before = converting("kyou")
        let result = ConversionResult(
            requestID: ConversionRequestID(),
            compositionID: before.compositionID,
            revision: before.revision,
            convertedText: "今日"
        )
        let outcome = CompositionTransition.reduce(before, .conversionSucceeded(result))
        #expect(outcome.state == before)
    }

    @Test("revision が一致しない変換結果は無視する")
    func staleRevisionRejected() {
        let before = converting("kyou")
        let result = ConversionResult(
            requestID: fixedRequestID,
            compositionID: before.compositionID,
            revision: before.revision + 1,
            convertedText: "今日"
        )
        let outcome = CompositionTransition.reduce(before, .conversionSucceeded(result))
        #expect(outcome.state == before)
    }

    @Test("compositionID が一致しない変換結果は無視する")
    func mismatchedCompositionIDRejected() {
        let before = converting("kyou")
        let result = ConversionResult(
            requestID: fixedRequestID,
            compositionID: CompositionID(),
            revision: before.revision,
            convertedText: "今日"
        )
        let outcome = CompositionTransition.reduce(before, .conversionSucceeded(result))
        #expect(outcome.state == before)
    }

    @Test("変換失敗は failed になり元テキストを保持する")
    func conversionFailureKeepsSource() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(
            before,
            .conversionFailed(
                requestID: fixedRequestID,
                compositionID: before.compositionID,
                revision: before.revision,
                error: .modelUnavailable("Apple Intelligence が無効です。")
            )
        )
        #expect(
            outcome.state.phase
                == .failed(
                    message: KotoError.modelUnavailable("Apple Intelligence が無効です。").userMessage
                )
        )
        #expect(outcome.state.displayedText == "kyou")
        #expect(outcome.view.markedText == "kyou")
    }

    @Test("キャンセル起因の失敗はエラーとして表示しない")
    func cancelledFailureIsSilent() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(
            before,
            .conversionFailed(
                requestID: fixedRequestID,
                compositionID: before.compositionID,
                revision: before.revision,
                error: .cancelled
            )
        )
        #expect(outcome.state == before)
    }

    // MARK: - 復元

    @Test("converted 後の restoreSource は元テキストを復元する")
    func restoreAfterConverted() {
        let state = converted(source: "kyou", convertedText: "今日")
        let outcome = CompositionTransition.reduce(state, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyou")
        #expect(!outcome.state.isSourcePreserved)
    }

    @Test("failed 後の restoreSource はエラーを消して元テキストを復元する")
    func restoreAfterFailure() {
        let before = converting("kyou")
        let failed = CompositionTransition.reduce(
            before,
            .conversionFailed(
                requestID: fixedRequestID,
                compositionID: before.compositionID,
                revision: before.revision,
                error: .emptyResponse
            )
        ).state
        let outcome = CompositionTransition.reduce(failed, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyou")
    }

    @Test("converting 中の restoreSource はタスクを取り消して元テキストへ戻る")
    func restoreDuringConversionCancels() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(before, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyou")
        #expect(outcome.effect == .cancelConversion)
    }

    @Test("converted 後に編集してから restoreSource で元テキストに戻れる")
    func restoreAfterEditingConvertedText() {
        let state = converted(source: "kyou", convertedText: "今日")
        let edited = CompositionTransition.reduce(state, .insert("は")).state
        #expect(edited.phase == .composing)
        #expect(edited.displayedText == "今日は")
        #expect(edited.sourceText == "kyou")
        #expect(edited.canRestoreSource)
        let outcome = CompositionTransition.reduce(edited, .restoreSource)
        #expect(outcome.state.displayedText == "kyou")
    }

    @Test("converted 後に編集して 2 回目の変換を要求できる")
    func secondConversionAfterEditing() {
        let state = converted(source: "kyou", convertedText: "今日")
        let edited = CompositionTransition.reduce(state, .insert("は")).state
        let secondID = ConversionRequestID()
        let outcome = CompositionTransition.reduce(
            edited,
            .requestConversion(.japanese),
            makeRequestID: { secondID }
        )
        #expect(outcome.state.phase == .converting(requestID: secondID))
        // 2 回目の変換では編集後のテキストが新しい復元対象になる。
        #expect(outcome.state.sourceText == "今日は")
    }

    // MARK: - commit / cancel / deactivate

    @Test("commit は表示テキストを確定して idle に戻る")
    func commitFinalizes() {
        let state = converted(source: "kyou", convertedText: "今日")
        let outcome = CompositionTransition.reduce(state, .commit)
        #expect(outcome.state.phase == .idle)
        #expect(outcome.view.shouldCommit)
        #expect(outcome.view.committedText == "今日")
        #expect(outcome.view.markedText == nil)
    }

    @Test("converting 中の commit はタスクを取り消して現在のテキストを確定する")
    func commitDuringConversion() {
        let outcome = CompositionTransition.reduce(converting("kyou"), .commit)
        #expect(outcome.effect == .cancelConversion)
        #expect(outcome.view.committedText == "kyou")
        #expect(outcome.state.phase == .idle)
    }

    @Test("cancel は marked text を破棄して idle に戻る")
    func cancelDiscards() {
        let outcome = CompositionTransition.reduce(compose("kyou"), .cancel)
        #expect(outcome.state.phase == .idle)
        #expect(outcome.view.markedText == nil)
        #expect(!outcome.view.shouldCommit)
    }

    @Test("deactivate は表示テキストが空でなければ commit する")
    func deactivateCommitsNonEmpty() {
        let outcome = CompositionTransition.reduce(converting("kyou"), .deactivate)
        #expect(outcome.state.phase == .idle)
        #expect(outcome.view.committedText == "kyou")
        #expect(outcome.effect == .cancelConversion)
    }

    @Test("deactivate は表示テキストが空なら cancel する")
    func deactivateCancelsEmpty() {
        let state = CompositionState(
            compositionID: CompositionID(),
            phase: .composing,
            sourceText: "",
            displayedText: "",
            selection: .cursor(at: 0),
            revision: 1,
            activeRequestRevision: nil,
            isSourcePreserved: false
        )
        let outcome = CompositionTransition.reduce(state, .deactivate)
        #expect(outcome.state.phase == .idle)
        #expect(!outcome.view.shouldCommit)
    }

    @Test("commit 後は新しい compositionID で次の composition が始まる")
    func commitCreatesNewCompositionID() {
        let before = compose("kyou")
        let after = CompositionTransition.reduce(before, .commit).state
        #expect(after.compositionID != before.compositionID)
    }

    // MARK: - 変換候補の蓄積と巡回選択

    @Test("変換成功で検証通過済みの結果が候補として 1 件蓄積される")
    func conversionSuccessAccumulatesCandidate() {
        let state = converted(source: "kyou", convertedText: "今日")
        #expect(
            state.candidates == [
                ConversionCandidate(text: "今日", target: .japanese, attempt: 0)
            ]
        )
        #expect(state.selectedCandidateIndex == 0)
        // 候補 1 件では巡回の意味が無い（上下キーはアプリへ通す）。
        #expect(!state.canCycleCandidates)
    }

    @Test("再抽選の成功で 2 件目の候補が追加され選択が新候補へ移る")
    func rerollAppendsSecondCandidate() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        #expect(
            second.candidates == [
                ConversionCandidate(text: "今日", target: .japanese, attempt: 0),
                ConversionCandidate(text: "京", target: .japanese, attempt: 1),
            ]
        )
        #expect(second.selectedCandidateIndex == 1)
        #expect(second.displayedText == "京")
        #expect(second.canCycleCandidates)
    }

    @Test("再抽選が同一の結果を返したら重複追加せず既存候補を選択する")
    func duplicateResultIsNotAppended() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "今日")
        #expect(
            second.candidates == [
                ConversionCandidate(text: "今日", target: .japanese, attempt: 0)
            ]
        )
        #expect(second.selectedCandidateIndex == 0)
        #expect(second.displayedText == "今日")
        if case .converted = second.phase {
            // 重複でも converted へ遷移する。
        } else {
            Issue.record("converted へ遷移しなかった: \(second.phase)")
        }
    }

    @Test("別 target の変換で日本語と英語の候補が共存する")
    func differentTargetCandidatesCoexist() {
        let japanese = converted(source: "kyou", convertedText: "今日")
        let english = reroll(japanese, target: .english, convertedText: "Today")
        #expect(
            english.candidates == [
                ConversionCandidate(text: "今日", target: .japanese, attempt: 0),
                ConversionCandidate(text: "Today", target: .english, attempt: 0),
            ]
        )
        #expect(english.selectedCandidateIndex == 1)
        #expect(english.canCycleCandidates)
    }

    @Test("selectCandidate で表示候補が切り替わり端では wrap around する")
    func selectCandidateCyclesWithWrapAround() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        // +1 は末尾から先頭へ wrap する。
        let wrapped = CompositionTransition.reduce(second, .selectCandidate(offset: 1))
        #expect(wrapped.state.selectedCandidateIndex == 0)
        #expect(wrapped.state.displayedText == "今日")
        #expect(wrapped.state.selection == .cursor(at: "今日".utf16.count))
        #expect(wrapped.state.revision == second.revision + 1)
        #expect(wrapped.view.markedText == "今日")
        #expect(wrapped.effect == .none)
        // 候補の巡回は原文スナップショットと候補列を変更しない。
        #expect(wrapped.state.sourceText == "kyou")
        #expect(wrapped.state.isSourcePreserved)
        #expect(wrapped.state.candidates == second.candidates)
        #expect(wrapped.state.phase == second.phase)
        // -1 は先頭から末尾へ wrap する。
        let back = CompositionTransition.reduce(wrapped.state, .selectCandidate(offset: -1))
        #expect(back.state.selectedCandidateIndex == 1)
        #expect(back.state.displayedText == "京")
    }

    @Test("idle や composing の selectCandidate は何も起こさない")
    func selectCandidateOutsideConvertedIsNoop() {
        let idle = CompositionTransition.reduce(.idle(), .selectCandidate(offset: 1))
        #expect(idle.state.phase == .idle)
        #expect(idle.effect == .none)
        let composing = compose("kyou")
        let outcome = CompositionTransition.reduce(composing, .selectCandidate(offset: 1))
        #expect(outcome.state == composing)
        #expect(outcome.effect == .none)
    }

    @Test("候補が 1 件だけの converted では selectCandidate は何も起こさない")
    func selectCandidateWithSingleCandidateIsNoop() {
        let state = converted(source: "kyou", convertedText: "今日")
        let outcome = CompositionTransition.reduce(state, .selectCandidate(offset: 1))
        #expect(outcome.state == state)
        #expect(outcome.effect == .none)
    }

    @Test("スナップショットを壊す編集で候補がクリアされる")
    func editClearsCandidates() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        let edited = CompositionTransition.reduce(second, .insert("x")).state
        #expect(edited.candidates.isEmpty)
        #expect(edited.selectedCandidateIndex == nil)
    }

    @Test("cancel で候補がクリアされる")
    func cancelClearsCandidates() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        let outcome = CompositionTransition.reduce(second, .cancel)
        #expect(outcome.state.candidates.isEmpty)
        #expect(outcome.state.selectedCandidateIndex == nil)
    }

    @Test("commit で候補がクリアされ次の composition は空の候補から始まる")
    func commitClearsCandidates() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        let committed = CompositionTransition.reduce(second, .commit).state
        #expect(committed.candidates.isEmpty)
        #expect(committed.selectedCandidateIndex == nil)
        let next = CompositionTransition.reduce(committed, .insert("a")).state
        #expect(next.candidates.isEmpty)
    }

    @Test("deactivate で候補がクリアされる")
    func deactivateClearsCandidates() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        let outcome = CompositionTransition.reduce(second, .deactivate)
        #expect(outcome.state.candidates.isEmpty)
        #expect(outcome.state.selectedCandidateIndex == nil)
    }

    @Test("restoreSource で候補がクリアされ原文へ戻る")
    func restoreSourceClearsCandidates() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        let outcome = CompositionTransition.reduce(second, .restoreSource)
        #expect(outcome.state.displayedText == "kyou")
        #expect(outcome.state.candidates.isEmpty)
        #expect(outcome.state.selectedCandidateIndex == nil)
    }

    @Test("selectCandidate 後も Escape で原文へ復元される")
    func escapeAfterSelectCandidateRestoresSource() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        let switched = CompositionTransition.reduce(
            second,
            .selectCandidate(offset: 1)
        ).state
        #expect(switched.displayedText == "今日")
        let outcome = CompositionTransition.reduce(switched, .restoreSource)
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyou")
        #expect(outcome.state.candidates.isEmpty)
    }

    @Test("selectCandidate 後の commit は選択中の候補を確定する")
    func commitAfterSelectCandidateCommitsSelected() {
        let first = converted(source: "kyou", convertedText: "今日")
        let second = reroll(first, target: .japanese, convertedText: "京")
        let switched = CompositionTransition.reduce(
            second,
            .selectCandidate(offset: 1)
        ).state
        let outcome = CompositionTransition.reduce(switched, .commit)
        #expect(outcome.view.shouldCommit)
        #expect(outcome.view.committedText == "今日")
        #expect(outcome.state.phase == .idle)
        #expect(outcome.state.candidates.isEmpty)
    }

    // MARK: - かな形態巡回（Tab 連打）

    @Test("normalizeToKana の連打でひらがな ⇄ カタカナを巡回する")
    func kanaFormCyclesOnRepeatedNormalize() {
        let composed = compose("onnna")
        #expect(composed.kanaCycleForm == nil)
        let first = CompositionTransition.reduce(composed, .normalizeToKana)
        #expect(first.state.displayedText == "おんな")
        #expect(first.state.kanaCycleForm == .hiragana)
        #expect(first.state.revision == composed.revision + 1)
        let second = CompositionTransition.reduce(first.state, .normalizeToKana)
        #expect(second.state.displayedText == "オンナ")
        #expect(second.state.kanaCycleForm == .katakana)
        #expect(second.state.phase == .composing)
        #expect(second.state.selection == .cursor(at: "オンナ".utf16.count))
        #expect(second.state.revision == first.state.revision + 1)
        #expect(second.view.markedText == "オンナ")
        let third = CompositionTransition.reduce(second.state, .normalizeToKana)
        #expect(third.state.displayedText == "おんな")
        #expect(third.state.kanaCycleForm == .hiragana)
        let fourth = CompositionTransition.reduce(third.state, .normalizeToKana)
        #expect(fourth.state.displayedText == "オンナ")
        #expect(fourth.state.kanaCycleForm == .katakana)
    }

    @Test("カタカナ化で保護語・ASCII・記号は変化しない")
    func katakanaCyclePreservesProtectedTerms() {
        // 仕様の受け入れ基準「Claude Code wo testo → Claude Code ヲ テスト相当」。
        // "testo" は "st" がローマ字として解釈不能で原文維持になるため、
        // かな化可能な "tesuto" で同等の振る舞いを検証する。
        let composed = compose("Claude Code wo tesuto")
        let hiragana = CompositionTransition.reduce(
            composed,
            .normalizeToKana,
            protectedTerms: ["Claude Code"]
        ).state
        #expect(hiragana.displayedText == "Claude Code を てすと")
        let katakana = CompositionTransition.reduce(
            hiragana,
            .normalizeToKana,
            protectedTerms: ["Claude Code"]
        ).state
        #expect(katakana.displayedText == "Claude Code ヲ テスト")
        #expect(katakana.kanaCycleForm == .katakana)
        let back = CompositionTransition.reduce(
            katakana,
            .normalizeToKana,
            protectedTerms: ["Claude Code"]
        ).state
        #expect(back.displayedText == "Claude Code を てすと")
    }

    @Test("テキストを変更する編集で巡回がリセットされ、次はひらがな化から始まる")
    func editingResetsKanaCycle() {
        let composed = compose("onnna")
        let hiragana = CompositionTransition.reduce(composed, .normalizeToKana).state
        let katakana = CompositionTransition.reduce(hiragana, .normalizeToKana).state
        #expect(katakana.displayedText == "オンナ")
        let edited = CompositionTransition.reduce(katakana, .insert("desu")).state
        #expect(edited.kanaCycleForm == nil)
        // リセット後の 1 回目はローマ字→ひらがな化（既存のカタカナは不変）。
        let normalized = CompositionTransition.reduce(edited, .normalizeToKana).state
        #expect(normalized.displayedText == "オンナです")
        #expect(normalized.kanaCycleForm == .hiragana)
        // 2 回目でひらがな部分がカタカナへ巡回する。
        let cycled = CompositionTransition.reduce(normalized, .normalizeToKana).state
        #expect(cycled.displayedText == "オンナデス")
    }

    @Test("deleteBackward でも巡回がリセットされる")
    func deleteBackwardResetsKanaCycle() {
        let composed = compose("onnna")
        let hiragana = CompositionTransition.reduce(composed, .normalizeToKana).state
        let katakana = CompositionTransition.reduce(hiragana, .normalizeToKana).state
        let deleted = CompositionTransition.reduce(katakana, .deleteBackward).state
        #expect(deleted.displayedText == "オン")
        #expect(deleted.kanaCycleForm == nil)
    }

    @Test("カーソル移動はテキストを変えないため巡回を維持する")
    func moveCursorKeepsKanaCycle() {
        let composed = compose("onnna")
        let hiragana = CompositionTransition.reduce(composed, .normalizeToKana).state
        let moved = CompositionTransition.reduce(hiragana, .moveCursor(offset: -1)).state
        #expect(moved.kanaCycleForm == .hiragana)
        let katakana = CompositionTransition.reduce(moved, .normalizeToKana).state
        #expect(katakana.displayedText == "オンナ")
        #expect(katakana.kanaCycleForm == .katakana)
    }

    @Test("変換要求で巡回がリセットされる")
    func requestConversionResetsKanaCycle() {
        let composed = compose("onnna")
        let hiragana = CompositionTransition.reduce(composed, .normalizeToKana).state
        let katakana = CompositionTransition.reduce(hiragana, .normalizeToKana).state
        let outcome = CompositionTransition.reduce(katakana, .requestConversion(.japanese))
        #expect(outcome.state.kanaCycleForm == nil)
    }

    @Test("変換成功で巡回がリセットされる")
    func conversionSuccessResetsKanaCycle() {
        // 既にかなのテキストへの normalizeToKana は冪等なので、converting を
        // 継続したまま（タイプ先行の prefix 維持）巡回状態だけが付く。
        let before = converting("きょう")
        let normalized = CompositionTransition.reduce(before, .normalizeToKana).state
        #expect(normalized.kanaCycleForm == .hiragana)
        let result = ConversionResult(
            requestID: fixedRequestID,
            compositionID: normalized.compositionID,
            revision: normalized.activeRequestRevision ?? 0,
            convertedText: "今日"
        )
        let outcome = CompositionTransition.reduce(normalized, .conversionSucceeded(result))
        #expect(outcome.state.displayedText == "今日")
        #expect(outcome.state.kanaCycleForm == nil)
    }

    @Test("Escape（restoreSource）で巡回がリセットされ、次はひらがな化から始まる")
    func restoreSourceResetsKanaCycle() {
        let state = converted(source: "kyou", convertedText: "今日")
        // converted からの Tab は編集としてかな化し、巡回状態が付く。
        let normalized = CompositionTransition.reduce(state, .normalizeToKana).state
        #expect(normalized.kanaCycleForm == .hiragana)
        #expect(normalized.canRestoreSource)
        let restored = CompositionTransition.reduce(normalized, .restoreSource).state
        #expect(restored.displayedText == "kyou")
        #expect(restored.kanaCycleForm == nil)
        // リセット後の Tab はローマ字→ひらがな化から再開する。
        let again = CompositionTransition.reduce(restored, .normalizeToKana).state
        #expect(again.displayedText == "きょう")
        #expect(again.kanaCycleForm == .hiragana)
    }

    @Test("空の composition への normalizeToKana は composition を終了し巡回状態を持たない")
    func normalizeToKanaOnEmptyTextEndsComposition() {
        let state = CompositionState(
            compositionID: CompositionID(),
            phase: .composing,
            sourceText: "",
            displayedText: "",
            selection: .cursor(at: 0),
            revision: 1,
            activeRequestRevision: nil,
            isSourcePreserved: false
        )
        let outcome = CompositionTransition.reduce(state, .normalizeToKana)
        #expect(outcome.state.phase == .idle)
        #expect(outcome.state.kanaCycleForm == nil)
    }

    @Test("commit / cancel / deactivate で巡回がリセットされる")
    func terminalCommandsResetKanaCycle() {
        let composed = compose("onnna")
        let hiragana = CompositionTransition.reduce(composed, .normalizeToKana).state
        let katakana = CompositionTransition.reduce(hiragana, .normalizeToKana).state
        let committed = CompositionTransition.reduce(katakana, .commit)
        #expect(committed.view.committedText == "オンナ")
        #expect(committed.state.kanaCycleForm == nil)
        let cancelled = CompositionTransition.reduce(katakana, .cancel)
        #expect(cancelled.state.kanaCycleForm == nil)
        let deactivated = CompositionTransition.reduce(katakana, .deactivate)
        #expect(deactivated.state.kanaCycleForm == nil)
    }

    @Test("タイプ先行の splice ではスナップショットが変わるため候補がクリアされる")
    func spliceClearsCandidates() {
        let first = converted(source: "kyou", convertedText: "今日")
        let retryID = ConversionRequestID()
        let retrying = CompositionTransition.reduce(
            first,
            .requestConversion(.japanese),
            makeRequestID: { retryID }
        ).state
        // タイプ先行の継続中（スナップショットが先頭に残る追記）は候補を保持する。
        let appended = CompositionTransition.reduce(retrying, .insert("x")).state
        #expect(appended.candidates.count == 1)
        let result = ConversionResult(
            requestID: retryID,
            compositionID: appended.compositionID,
            revision: appended.activeRequestRevision ?? 0,
            convertedText: "京"
        )
        let outcome = CompositionTransition.reduce(appended, .conversionSucceeded(result))
        #expect(outcome.state.displayedText == "京x")
        #expect(outcome.state.candidates.isEmpty)
        #expect(outcome.state.selectedCandidateIndex == nil)
    }
}
