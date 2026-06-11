import KotoCore
import Testing

@Suite("CompositionTransition の状態遷移")
struct CompositionTransitionTests {
    private let fixedRequestID = ConversionRequestID()

    private func compose(_ text: String) -> CompositionState {
        CompositionTransition.reduce(.idle(), .insert(text)).state
    }

    private func converting(
        _ text: String,
        target: ConversionTarget = .japanese
    ) -> CompositionState {
        CompositionTransition.reduce(
            compose(text),
            .requestConversion(target),
            makeRequestID: { fixedRequestID }
        ).state
    }

    private func converted(
        source: String,
        convertedText: String,
        target: ConversionTarget = .japanese
    ) -> CompositionState {
        let before = converting(source, target: target)
        let result = ConversionResult(
            requestID: fixedRequestID,
            compositionID: before.compositionID,
            revision: before.revision,
            convertedText: convertedText
        )
        return CompositionTransition.reduce(before, .conversionSucceeded(result)).state
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
        if case .startConversion(_, _, _, let sourceText, _, let attempt) = outcome.effect {
            #expect(attempt == 0)
            #expect(sourceText == "kyoux")
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
                    attempt: 0
                )
        )
    }

    @Test("converted（英語）から同じ target の再要求は attempt が増える（再抽選）")
    func sameTargetRetryIncrementsAttempt() {
        let state = converted(
            source: "kyouhaiihida",
            convertedText: "Today is a good day",
            target: .english
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
                    attempt: 1
                )
        )
    }

    @Test("converted（英語）から別 target の要求は attempt 0 で原文から変換し直す")
    func differentTargetRestartsAtAttemptZero() {
        let state = converted(
            source: "kyouhaiihida",
            convertedText: "Today is a good day",
            target: .english
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
        if case .startConversion(_, _, _, let sourceText, let target, let attempt) =
            outcome.effect
        {
            #expect(sourceText == "kyou")
            #expect(target == .english)
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
            target: .english
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
            target: .english
        )
        let retried = CompositionTransition.reduce(state, .requestConversion(.english)).state
        #expect(retried.retryCount == 1)
        let edited = CompositionTransition.reduce(retried, .insert("ne")).state
        let outcome = CompositionTransition.reduce(edited, .requestConversion(.english))
        #expect(outcome.state.retryCount == 0)
        if case .startConversion(_, _, _, let sourceText, let target, let attempt) =
            outcome.effect
        {
            #expect(sourceText == "kyouhaiihidane")
            #expect(target == .english)
            #expect(attempt == 0)
        } else {
            Issue.record("startConversion が発行されなかった: \(outcome.effect)")
        }
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
}
