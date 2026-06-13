/// 変換タスクにキャプチャされる不変のリクエストデータ。
/// 入力クライアントへの参照や可変状態を持たない。
public struct ConversionRequest: Sendable {
    public let id: ConversionRequestID
    public let compositionID: CompositionID
    public let revision: UInt64
    /// ユーザーが打った元テキスト。出力検証（保護語・膨張率）の基準であり、
    /// 表示・Escape 復元と同じテキストを指す。
    public let sourceText: String
    public let settings: ConversionSettings
    /// 変換先の言語。プロンプトの instructions と出力検証の言語分岐に使う。
    public let target: ConversionTarget
    /// 同じ原文・同じ（target, 文脈の有無）に対する再変換（候補の再抽選）の
    /// 回数。0 が初回。文脈の有無が切り替わると 0 へ戻る（プロンプトが
    /// 変わるため、別経路として greedy から始める。ADR-0013）。
    public let attempt: Int
    /// プロンプトの [CONTEXT] セクションに載せるセッション内文脈（古い→
    /// 新しい順、ADR-0013）。coordinator がタスク開始時に store から
    /// スナップショットし、リクエストは不変のまま。空なら [CONTEXT] を
    /// 出さず、プロンプトは従来と同一になる。
    public let contextEntries: [String]
    /// 辞書ラティス（LatticeConverter）が出した一次変換の草案（ADR-0016）。
    /// AI に [DRAFT] セクションで渡し、読み（[INPUT]）に対する単語選択の
    /// 強いヒントにする。nil（既定）なら [DRAFT] を出さず、プロンプトは従来と
    /// バイト単位で同一になる。HybridConversionProvider が AI 段の要求に載せる。
    public let dictionaryDraft: String?

    /// モデルへ渡すかな化済み入力。プロンプト構築にのみ使う。
    /// 分かち書きなしローマ字の弱点は言語によらないため、前段かな化は
    /// 全 target 共通で適用する。評価は呼び出し側（provider の actor
    /// コンテキスト）で行われ、メインアクターを塞がない。
    public var modelInputText: String {
        RomajiKanaConverter.normalize(
            sourceText,
            protecting: settings.sanitizedProtectedTerms
        )
    }

    public init(
        id: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        sourceText: String,
        settings: ConversionSettings,
        target: ConversionTarget = .japanese,
        attempt: Int = 0,
        contextEntries: [String] = [],
        dictionaryDraft: String? = nil
    ) {
        self.id = id
        self.compositionID = compositionID
        self.revision = revision
        self.sourceText = sourceText
        self.settings = settings
        self.target = target
        self.attempt = attempt
        self.contextEntries = contextEntries
        self.dictionaryDraft = dictionaryDraft
    }
}

/// 変換結果。compositionID / requestID / revision の 3 つが現在状態と
/// 一致するときだけ適用される。
public struct ConversionResult: Equatable, Sendable {
    public let requestID: ConversionRequestID
    public let compositionID: CompositionID
    public let revision: UInt64
    public let convertedText: String
    /// この結果を得るために実行した attempt。自動 retry が成功した場合に、
    /// reducer が次回の再抽選開始位置を戻さないために使う。
    public let attempt: Int

    public init(
        requestID: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        convertedText: String,
        attempt: Int = 0
    ) {
        self.requestID = requestID
        self.compositionID = compositionID
        self.revision = revision
        self.convertedText = convertedText
        self.attempt = attempt
    }
}
