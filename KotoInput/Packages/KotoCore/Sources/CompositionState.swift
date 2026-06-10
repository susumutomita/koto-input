/// composition の全状態。遷移は CompositionTransition.reduce で行い、
/// この型自体は純粋な値として保持する。
public struct CompositionState: Equatable, Sendable {
    public var compositionID: CompositionID
    public var phase: CompositionPhase
    /// Escape で復元する元テキスト。変換要求時にスナップショットされる。
    public var sourceText: String
    /// 現在 marked text として表示しているテキスト。
    public var displayedText: String
    public var selection: TextSelection
    /// ユーザー編集・restore・新規変換要求のたびに増えるリビジョン。
    public var revision: UInt64
    /// 実行中の変換要求が発行されたときのリビジョン。実行中でなければ nil。
    public var activeRequestRevision: UInt64?
    /// true のとき sourceText は変換要求時のスナップショットとして凍結されており、
    /// composing 中の編集で displayedText に追従しない。
    public var isSourcePreserved: Bool

    public init(
        compositionID: CompositionID,
        phase: CompositionPhase,
        sourceText: String,
        displayedText: String,
        selection: TextSelection,
        revision: UInt64,
        activeRequestRevision: UInt64?,
        isSourcePreserved: Bool
    ) {
        self.compositionID = compositionID
        self.phase = phase
        self.sourceText = sourceText
        self.displayedText = displayedText
        self.selection = selection
        self.revision = revision
        self.activeRequestRevision = activeRequestRevision
        self.isSourcePreserved = isSourcePreserved
    }

    /// 新しい composition ID を持つ初期状態。
    public static func idle() -> CompositionState {
        CompositionState(
            compositionID: CompositionID(),
            phase: .idle,
            sourceText: "",
            displayedText: "",
            selection: .cursor(at: 0),
            revision: 0,
            activeRequestRevision: nil,
            isSourcePreserved: false
        )
    }

    public var hasActiveComposition: Bool {
        phase != .idle
    }

    /// Escape を restoreSource として解釈すべきかどうか。
    /// 変換中・変換後・失敗時は復元、素の入力中は composition の破棄（cancel）。
    public var canRestoreSource: Bool {
        switch phase {
        case .converting, .converted, .failed:
            return true
        case .composing:
            return isSourcePreserved && sourceText != displayedText
        case .idle:
            return false
        }
    }
}
