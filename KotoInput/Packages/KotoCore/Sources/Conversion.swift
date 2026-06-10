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

    /// モデルへ渡すかな化済み入力。プロンプト構築にのみ使う。
    /// 評価は呼び出し側（provider の actor コンテキスト）で行われ、
    /// メインアクターを塞がない。
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
        settings: ConversionSettings
    ) {
        self.id = id
        self.compositionID = compositionID
        self.revision = revision
        self.sourceText = sourceText
        self.settings = settings
    }
}

/// 変換結果。compositionID / requestID / revision の 3 つが現在状態と
/// 一致するときだけ適用される。
public struct ConversionResult: Equatable, Sendable {
    public let requestID: ConversionRequestID
    public let compositionID: CompositionID
    public let revision: UInt64
    public let convertedText: String

    public init(
        requestID: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        convertedText: String
    ) {
        self.requestID = requestID
        self.compositionID = compositionID
        self.revision = revision
        self.convertedText = convertedText
    }
}
