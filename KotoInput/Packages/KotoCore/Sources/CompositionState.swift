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
    /// 同じ原文に対する再変換（候補の再抽選）の回数。編集でリセットされる。
    public var retryCount: Int
    /// 直近の変換要求のターゲット言語。converted からの再要求が同じ target
    /// なら再抽選（attempt + 1）、別の target なら attempt 0 で変換し直す。
    public var conversionTarget: ConversionTarget
    /// 現在の原文スナップショットに対して蓄積された変換候補（検証通過済み）。
    /// converted からの再変換要求（同 target 再抽選・別 target 切替）では
    /// 蓄積を継続し、スナップショットを壊す編集・cancel・commit・
    /// restoreSource・deactivate でクリアされる。
    public var candidates: [ConversionCandidate]
    /// candidates のうち現在 marked text として表示している候補の位置。
    /// 候補が無いときは nil。
    public var selectedCandidateIndex: Int?

    public init(
        compositionID: CompositionID,
        phase: CompositionPhase,
        sourceText: String,
        displayedText: String,
        selection: TextSelection,
        revision: UInt64,
        activeRequestRevision: UInt64?,
        isSourcePreserved: Bool,
        retryCount: Int = 0,
        conversionTarget: ConversionTarget = .japanese,
        candidates: [ConversionCandidate] = [],
        selectedCandidateIndex: Int? = nil
    ) {
        self.compositionID = compositionID
        self.phase = phase
        self.sourceText = sourceText
        self.displayedText = displayedText
        self.selection = selection
        self.revision = revision
        self.activeRequestRevision = activeRequestRevision
        self.isSourcePreserved = isSourcePreserved
        self.retryCount = retryCount
        self.conversionTarget = conversionTarget
        self.candidates = candidates
        self.selectedCandidateIndex = selectedCandidateIndex
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

    /// 上下矢印で候補を巡回できるかどうか。converted で候補が 2 件以上の
    /// ときだけ true。false のとき InputController はキーを消費せずアプリへ
    /// 通す（ターミナルの履歴操作を奪わない）。
    public var canCycleCandidates: Bool {
        if case .converted = phase {
            return candidates.count >= 2
        }
        return false
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
