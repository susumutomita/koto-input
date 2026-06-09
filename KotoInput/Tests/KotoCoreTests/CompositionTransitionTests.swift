import KotoCore
import Testing

@Suite("CompositionTransition の状態遷移")
struct CompositionTransitionTests {
    private let fixedRequestID = ConversionRequestID()

    private func compose(_ text: String) -> CompositionState {
        CompositionTransition.reduce(.idle(), .insert(text)).state
    }

    private func converting(_ text: String) -> CompositionState {
        CompositionTransition.reduce(
            compose(text),
            .requestConversion,
            makeRequestID: { fixedRequestID }
        ).state
    }

    private func converted(
        source: String,
        convertedText: String
    ) -> CompositionState {
        let before = converting(source)
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
            .requestConversion,
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
                    sourceText: "kyou ha ame"
                )
        )
    }

    @Test("空白のみのテキストでは変換要求を無視する")
    func requestConversionIgnoresWhitespaceOnly() {
        let before = compose("   ")
        let outcome = CompositionTransition.reduce(before, .requestConversion)
        #expect(outcome.state == before)
        #expect(outcome.effect == .none)
    }

    @Test("converting 中の編集はタスクを取り消して composing に戻る")
    func editDuringConversionCancels() {
        let before = converting("kyou")
        let outcome = CompositionTransition.reduce(before, .insert("x"))
        #expect(outcome.state.phase == .composing)
        #expect(outcome.state.displayedText == "kyoux")
        #expect(outcome.effect == .cancelConversion)
        #expect(outcome.state.sourceText == "kyou")
        #expect(outcome.state.activeRequestRevision == nil)
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
            .requestConversion,
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
