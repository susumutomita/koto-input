/// composition の状態遷移を純粋関数として実装する reducer。
/// 副作用（変換タスクの開始・キャンセル）は Effect として返し、
/// CompositionCoordinator が実行する。
public enum CompositionTransition {
    public enum Effect: Equatable, Sendable {
        case none
        /// 実行中の変換タスクをキャンセルする。
        case cancelConversion
        /// 既存タスクをキャンセルした上で新しい変換を開始する。
        /// attempt は同じ原文・同じ（target, useContext）に対する再変換
        /// （候補の再抽選）の回数。useContext はセッション内文脈メモリを
        /// [CONTEXT] として付与する文脈つき変換（ADR-0013）。
        case startConversion(
            requestID: ConversionRequestID,
            compositionID: CompositionID,
            revision: UInt64,
            sourceText: String,
            target: ConversionTarget,
            useContext: Bool,
            attempt: Int
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

    /// `protectedTerms` は normalizeToKana が参照する環境値（サニタイズ済みの
    /// 保護語）。設定の所有者（CompositionCoordinator）が注入することで、
    /// reducer は純粋関数のまま AI 経路（modelInputText）と同じ保護を適用できる。
    public static func reduce(
        _ state: CompositionState,
        _ command: CompositionCommand,
        protectedTerms: [String] = [],
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
        case .requestConversion(let target):
            return requestConversion(state, target: target, makeRequestID: makeRequestID)
        case .requestContextualConversion:
            // 第一版の文脈つき変換は日本語 target のみ（ADR-0013）。
            return requestConversion(
                state,
                target: .japanese,
                useContext: true,
                makeRequestID: makeRequestID
            )
        case .normalizeToKana:
            return normalizeToKana(state, protectedTerms: protectedTerms)
        case .selectCandidate(let offset):
            return selectCandidate(state, offset: offset)
        case .conversionSucceeded(let result):
            return conversionSucceeded(state, result: result)
        case .conversionFailed(
            let requestID,
            let compositionID,
            let revision,
            let attempt,
            let error
        ):
            return conversionFailed(
                state,
                requestID: requestID,
                compositionID: compositionID,
                revision: revision,
                attempt: attempt,
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
        next.revision &+= 1
        // テキストを変更する編集はかな形態巡回をリセットする（normalizeToKana
        // 自身も applyEdit を通り、巡回の継続は呼び出し側で上書きする）。
        next.kanaCycleForm = nil
        if wasConverting && text.hasPrefix(state.sourceText) {
            // タイプ先行: スナップショット（sourceText）が先頭にそのまま残る編集
            // （末尾への追記や追記分の編集）は変換を継続する。結果が届いたら
            // スナップショット部分だけが変換結果に差し替えられる。
            return Outcome(state: next, effect: .none, view: .from(state: next))
        }
        next.phase = .composing
        next.activeRequestRevision = nil
        // スナップショットの文脈を離れる編集では、蓄積した候補は表示と
        // 対応しなくなるためクリアする（タイプ先行の継続中は保持される）。
        next.candidates = []
        next.selectedCandidateIndex = nil
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

    /// Tab のかな形態巡回（Issue 41）。非巡回（kanaCycleForm == nil）はローマ字
    /// →ひらがな化（保護語除外）から始まり、以降は表示テキストへの機械変換で
    /// ひらがな ⇄ カタカナを巡回する。いずれも applyEdit を通る「編集」なので、
    /// revision・変換中のキャンセル（prefix が変わる場合）・候補クリア等の
    /// 既存規則をそのまま踏襲する。
    private static func normalizeToKana(
        _ state: CompositionState,
        protectedTerms: [String]
    ) -> Outcome {
        let text: String
        let form: KanaForm
        switch state.kanaCycleForm {
        case .none:
            // 決定論ひらがな化。保護語は AI 経路（modelInputText）と同じく
            // 原文のまま残す。
            text = RomajiKanaConverter.normalize(
                state.displayedText,
                protecting: protectedTerms
            )
            form = .hiragana
        case .some(.hiragana):
            // ひらがな範囲のコードポイントシフトなので、保護語（ラテン文字）・
            // ASCII・記号・長音符は変化しない（保護語の再照合は不要）。
            text = RomajiKanaConverter.hiraganaToKatakana(state.displayedText)
            form = .katakana
        case .some(.katakana):
            text = RomajiKanaConverter.katakanaToHiragana(state.displayedText)
            form = .hiragana
        }
        let outcome = applyEdit(state) { _ in
            (text, .cursor(at: text.utf16.count))
        }
        // applyEdit は編集として巡回をリセットするため、巡回の継続をここで
        // 上書きする。空テキストで composition が終了した場合は idle のまま。
        guard outcome.state.hasActiveComposition else { return outcome }
        var next = outcome.state
        next.kanaCycleForm = form
        return Outcome(state: next, effect: outcome.effect, view: .from(state: next))
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
        target: ConversionTarget,
        useContext: Bool = false,
        makeRequestID: () -> ConversionRequestID
    ) -> Outcome {
        let trimmed = state.displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 空テキストの変換要求は無視する（KotoError.emptyInput をユーザーに
            // 見せる価値がないため、状態も変えない）。
            return noop(state)
        }
        // converted / failed から編集せずに再要求された場合は、原文
        // スナップショットから変換し直し、表示も原文へ戻す
        // （タイプ先行の prefix 整合を保つため）。
        // 同じ（target, useContext）なら「再変換（候補の再抽選）」として
        // attempt を増やし、別の組なら attempt 0 から変換し直す（文脈の有無で
        // プロンプトが変わるため、別経路として greedy から始める。ADR-0013）。
        // Escape の復元先は常に原文のまま。
        let isReconversionFromSnapshot: Bool = {
            switch state.phase {
            case .converted:
                return state.isSourcePreserved
            case .failed:
                return state.isSourcePreserved && state.displayedText == state.sourceText
            case .idle, .composing, .converting:
                return false
            }
        }()
        var next = state
        let requestID = makeRequestID()
        next.revision &+= 1
        next.phase = .converting(requestID: requestID)
        // AI 変換に入ったらかな形態巡回は終わる（次の Tab はひらがな化から）。
        next.kanaCycleForm = nil
        if isReconversionFromSnapshot {
            // 同一スナップショットへの再要求（再抽選・target 切替・文脈の
            // 有無切替）は候補の蓄積を継続する（候補が共存できる）。
            let isSameAttemptKey =
                target == state.conversionTarget
                && useContext == state.conversionUsedContext
            next.retryCount = isSameAttemptKey ? state.retryCount + 1 : 0
            next.displayedText = state.sourceText
            next.selection = .cursor(at: state.sourceText.utf16.count)
        } else {
            // Escape 用のスナップショット。編集後の変換では編集後のテキストが
            // 新しい復元対象になり、旧スナップショットの候補は破棄される。
            next.sourceText = state.displayedText
            next.retryCount = 0
            next.candidates = []
            next.selectedCandidateIndex = nil
        }
        next.conversionTarget = target
        next.conversionUsedContext = useContext
        next.isSourcePreserved = true
        next.activeRequestRevision = next.revision
        return Outcome(
            state: next,
            effect: .startConversion(
                requestID: requestID,
                compositionID: next.compositionID,
                revision: next.revision,
                sourceText: next.sourceText,
                target: target,
                useContext: useContext,
                attempt: next.retryCount
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
            state.activeRequestRevision == result.revision,
            // タイプ先行の継続条件（スナップショットが先頭に残っている）の防御的確認。
            state.displayedText.hasPrefix(state.sourceText)
        else {
            // stale な結果（古い requestID / revision / 別 composition）は
            // 新しい入力を決して上書きしない。
            return noop(state)
        }
        let tail = String(state.displayedText.dropFirst(state.sourceText.count))
        var next = state
        next.activeRequestRevision = nil
        next.retryCount = result.attempt
        // 表示が変換結果へ差し替わるため、かな形態巡回は終わる（converting 中の
        // 冪等な normalizeToKana で巡回状態が付いたまま成功するケース）。
        next.kanaCycleForm = nil
        if tail.isEmpty {
            next.displayedText = result.convertedText
            next.selection = .cursor(at: result.convertedText.utf16.count)
            next.phase = .converted(requestID: requestID)
            // 検証通過済みの結果だけが候補になる。target は stale 照合を
            // 通過したこの結果の要求時の値、attempt は自動 retry を含む
            // 実行済み attempt を使う。同一 text + target の候補が既にあれば
            // 重複追加せず、その候補を選択し直す。
            let candidate = ConversionCandidate(
                text: result.convertedText,
                target: state.conversionTarget,
                attempt: result.attempt
            )
            if let existing = next.candidates.firstIndex(where: {
                $0.text == candidate.text && $0.target == candidate.target
            }) {
                next.selectedCandidateIndex = existing
            } else {
                next.candidates.append(candidate)
                next.selectedCandidateIndex = next.candidates.count - 1
            }
        } else {
            // タイプ先行中: スナップショット部分だけを変換結果へ差し替え、
            // 追記分（tail）はそのまま保持する。追記分を失わないことを優先し、
            // splice 後は Escape での復元を無効化する。スナップショットが
            // 変わるため、旧スナップショットの候補は破棄する。
            let spliced = result.convertedText + tail
            next.displayedText = spliced
            next.phase = .composing
            next.isSourcePreserved = false
            next.sourceText = spliced
            next.candidates = []
            next.selectedCandidateIndex = nil
            let snapshotLength = state.sourceText.utf16.count
            let delta = result.convertedText.utf16.count - snapshotLength
            let shifted =
                state.selection.location >= snapshotLength
                ? state.selection.location + delta
                : result.convertedText.utf16.count
            next.selection = UTF16TextEditing.clampedSelection(
                .cursor(at: shifted),
                in: spliced
            )
        }
        return Outcome(state: next, effect: .none, view: .from(state: next))
    }

    private static func conversionFailed(
        _ state: CompositionState,
        requestID: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        attempt: Int,
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
        next.retryCount = attempt
        return Outcome(state: next, effect: .none, view: .from(state: next))
    }

    // MARK: - Restore / Commit / Reset

    private static func restoreSource(_ state: CompositionState) -> Outcome {
        let wasConverting = isConverting(state)
        switch state.phase {
        case .composing:
            guard state.canRestoreSource else { return noop(state) }
        case .converting, .failed:
            // タイプ先行で追記がある場合は、追記分を失わないよう変換だけを
            // 中止してテキストは保持する。
            if state.displayedText != state.sourceText,
                state.displayedText.hasPrefix(state.sourceText)
            {
                var next = state
                next.phase = .composing
                next.revision &+= 1
                next.activeRequestRevision = nil
                next.isSourcePreserved = false
                next.sourceText = next.displayedText
                next.candidates = []
                next.selectedCandidateIndex = nil
                next.kanaCycleForm = nil
                return Outcome(
                    state: next,
                    effect: wasConverting ? .cancelConversion : .none,
                    view: .from(state: next)
                )
            }
        case .converted:
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
        // 原文へ戻したら候補の文脈も終わる（候補巡回より Escape 復元を優先）。
        next.candidates = []
        next.selectedCandidateIndex = nil
        // 原文（ローマ字）へ戻ったので、次の Tab はひらがな化から始まる。
        next.kanaCycleForm = nil
        return Outcome(
            state: next,
            effect: wasConverting ? .cancelConversion : .none,
            view: .from(state: next)
        )
    }

    // MARK: - Candidate selection

    /// 蓄積された候補の選択を offset だけ wrap around で移動し、表示を
    /// 選択候補へ差し替える。converted で候補が 2 件以上のときだけ有効。
    /// sourceText / isSourcePreserved / candidates は変更しないため、
    /// Escape は引き続き原文へ戻り、Enter は表示中の候補を確定する。
    private static func selectCandidate(_ state: CompositionState, offset: Int) -> Outcome {
        guard state.canCycleCandidates, let current = state.selectedCandidateIndex else {
            return noop(state)
        }
        let count = state.candidates.count
        let selected = ((current + offset) % count + count) % count
        let text = state.candidates[selected].text
        var next = state
        next.selectedCandidateIndex = selected
        next.displayedText = text
        next.selection = .cursor(at: text.utf16.count)
        next.revision &+= 1
        return Outcome(state: next, effect: .none, view: .from(state: next))
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
