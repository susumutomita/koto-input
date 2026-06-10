/// composition の状態遷移を純粋関数として実装する reducer。
/// 副作用（変換タスクの開始・キャンセル）は Effect として返し、
/// CompositionCoordinator が実行する。
public enum CompositionTransition {
    public enum Effect: Equatable, Sendable {
        case none
        /// 実行中の変換タスクをキャンセルする。
        case cancelConversion
        /// 既存タスクをキャンセルした上で新しい変換を開始する。
        case startConversion(
            requestID: ConversionRequestID,
            compositionID: CompositionID,
            revision: UInt64,
            sourceText: String
        )
    }

    public struct Outcome: Equatable, Sendable {
        public let state: CompositionState
        public let effect: Effect
        public let view: CompositionViewState

        public init(state: CompositionState, effect: Effect, view: CompositionViewState) {
            self.state = state
            self.effect = effect
            self.view = view
        }
    }

    public static func reduce(
        _ state: CompositionState,
        _ command: CompositionCommand,
        makeRequestID: () -> ConversionRequestID = { ConversionRequestID() }
    ) -> Outcome {
        if case .idle = state.phase {
            return reduceIdle(state, command)
        }

        switch command {
        case .insert(let text), .replaceSelection(let text):
            return applyEdit(state) { current in
                UTF16TextEditing.insert(text, into: current.displayedText, at: current.selection)
            }
        case .deleteBackward:
            return applyEdit(state) { current in
                UTF16TextEditing.deleteBackward(
                    in: current.displayedText,
                    at: current.selection
                )
            }
        case .moveCursor(let offset):
            return moveCursor(state, offset: offset)
        case .requestConversion:
            return requestConversion(state, makeRequestID: makeRequestID)
        case .conversionSucceeded(let result):
            return conversionSucceeded(state, result: result)
        case .conversionFailed(let requestID, let compositionID, let revision, let error):
            return conversionFailed(
                state,
                requestID: requestID,
                compositionID: compositionID,
                revision: revision,
                error: error
            )
        case .restoreSource:
            return restoreSource(state)
        case .commit:
            return commit(state)
        case .cancel:
            return reset(state)
        case .deactivate:
            // MVP の deactivation ポリシー: 表示テキストが空でなければ commit、
            // 空なら cancel。タイプ済みテキストを消失させない。
            return state.displayedText.isEmpty ? reset(state) : commit(state)
        }
    }

    // MARK: - Idle

    private static func reduceIdle(
        _ state: CompositionState,
        _ command: CompositionCommand
    ) -> Outcome {
        switch command {
        case .insert(let text), .replaceSelection(let text):
            guard !text.isEmpty else { return noop(state) }
            var next = state
            next.phase = .composing
            next.displayedText = text
            next.sourceText = text
            next.selection = .cursor(at: text.utf16.count)
            next.revision &+= 1
            next.activeRequestRevision = nil
            next.isSourcePreserved = false
            return Outcome(state: next, effect: .none, view: .from(state: next))
        default:
            // idle では composition が無いので他のコマンドは何もしない。
            // 遅れて届いた conversionSucceeded / conversionFailed もここで捨てられる。
            return noop(state)
        }
    }

    // MARK: - Edits

    private static func applyEdit(
        _ state: CompositionState,
        _ edit: (CompositionState) -> (text: String, selection: TextSelection)
    ) -> Outcome {
        let wasConverting = isConverting(state)
        let (text, selection) = edit(state)
        if text.isEmpty {
            // 全部消したら composition を終了する（空の marked text を残さない）。
            return reset(state)
        }
        var next = state
        next.displayedText = text
        next.selection = selection
        next.phase = .composing
        next.revision &+= 1
        next.activeRequestRevision = nil
        if !next.isSourcePreserved {
            // 変換前の素の入力中は、復元対象 = 現在のテキスト。
            next.sourceText = text
        }
        return Outcome(
            state: next,
            effect: wasConverting ? .cancelConversion : .none,
            view: .from(state: next)
        )
    }

    private static func moveCursor(_ state: CompositionState, offset: Int) -> Outcome {
        // カーソル移動はテキストを変更しないため revision を増やさず、
        // phase も維持する（converting 中の移動は変換をキャンセルしない）。
        var next = state
        next.selection = UTF16TextEditing.moveCursor(
            in: state.displayedText,
            from: state.selection,
            offset: offset
        )
        return Outcome(state: next, effect: .none, view: .from(state: next))
    }

    // MARK: - Conversion

    private static func requestConversion(
        _ state: CompositionState,
        makeRequestID: () -> ConversionRequestID
    ) -> Outcome {
        let trimmed = state.displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 空テキストの変換要求は無視する（KotoError.emptyInput をユーザーに
            // 見せる価値がないため、状態も変えない）。
            return noop(state)
        }
        var next = state
        let requestID = makeRequestID()
        next.revision &+= 1
        next.phase = .converting(requestID: requestID)
        // Escape 用のスナップショット。2 回目の変換では編集後のテキストが新しい
        // 復元対象になる。
        next.sourceText = state.displayedText
        next.isSourcePreserved = true
        next.activeRequestRevision = next.revision
        return Outcome(
            state: next,
            effect: .startConversion(
                requestID: requestID,
                compositionID: next.compositionID,
                revision: next.revision,
                sourceText: next.sourceText
            ),
            view: .from(state: next)
        )
    }

    private static func conversionSucceeded(
        _ state: CompositionState,
        result: ConversionResult
    ) -> Outcome {
        guard
            case .converting(let requestID) = state.phase,
            requestID == result.requestID,
            state.compositionID == result.compositionID,
            state.activeRequestRevision == result.revision
        else {
            // stale な結果（古い requestID / revision / 別 composition）は
            // 新しい入力を決して上書きしない。
            return noop(state)
        }
        var next = state
        next.displayedText = result.convertedText
        next.selection = .cursor(at: result.convertedText.utf16.count)
        next.phase = .converted(requestID: requestID)
        next.activeRequestRevision = nil
        return Outcome(state: next, effect: .none, view: .from(state: next))
    }

    private static func conversionFailed(
        _ state: CompositionState,
        requestID: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        error: KotoError
    ) -> Outcome {
        if case .cancelled = error {
            // 編集起因のキャンセルはエラーとして表示しない。
            return noop(state)
        }
        guard
            case .converting(let activeRequestID) = state.phase,
            activeRequestID == requestID,
            state.compositionID == compositionID,
            state.activeRequestRevision == revision
        else {
            return noop(state)
        }
        var next = state
        // 元テキスト（converting 中の displayedText はスナップショットと同じ）を
        // 保持したまま、回復可能なエラーを表示する。
        next.phase = .failed(message: error.userMessage)
        next.activeRequestRevision = nil
        return Outcome(state: next, effect: .none, view: .from(state: next))
    }

    // MARK: - Restore / Commit / Reset

    private static func restoreSource(_ state: CompositionState) -> Outcome {
        let wasConverting = isConverting(state)
        switch state.phase {
        case .composing:
            guard state.canRestoreSource else { return noop(state) }
        case .converting, .converted, .failed:
            break
        case .idle:
            return noop(state)
        }
        var next = state
        next.displayedText = state.sourceText
        next.selection = .cursor(at: state.sourceText.utf16.count)
        next.phase = .composing
        next.revision &+= 1
        next.activeRequestRevision = nil
        next.isSourcePreserved = false
        return Outcome(
            state: next,
            effect: wasConverting ? .cancelConversion : .none,
            view: .from(state: next)
        )
    }

    private static func commit(_ state: CompositionState) -> Outcome {
        let wasConverting = isConverting(state)
        let committed = state.displayedText
        let next = CompositionState.idle()
        let view = CompositionViewState(
            markedText: nil,
            selection: .cursor(at: 0),
            shouldCommit: !committed.isEmpty,
            committedText: committed.isEmpty ? nil : committed,
            status: .idle
        )
        return Outcome(
            state: next,
            effect: wasConverting ? .cancelConversion : .none,
            view: view
        )
    }

    private static func reset(_ state: CompositionState) -> Outcome {
        let wasConverting = isConverting(state)
        let next = CompositionState.idle()
        return Outcome(
            state: next,
            effect: wasConverting ? .cancelConversion : .none,
            view: .from(state: next)
        )
    }

    // MARK: - Helpers

    private static func noop(_ state: CompositionState) -> Outcome {
        Outcome(state: state, effect: .none, view: .from(state: state))
    }

    private static func isConverting(_ state: CompositionState) -> Bool {
        if case .converting = state.phase { return true }
        return false
    }
}
