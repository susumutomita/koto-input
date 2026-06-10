/// 変換タスクにキャプチャされる不変のリクエストデータ。
/// 入力クライアントへの参照や可変状態を持たない。
public struct ConversionRequest: Sendable {
    public let id: ConversionRequestID
    public let compositionID: CompositionID
    public let revision: UInt64
    public let sourceText: String
    public let settings: ConversionSettings
    /// 同じ原文に対する再変換（候補の再抽選）の回数。0 が初回。
    public let attempt: Int

    public init(
        id: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        sourceText: String,
        settings: ConversionSettings,
        attempt: Int = 0
    ) {
        self.id = id
        self.compositionID = compositionID
        self.revision = revision
        self.sourceText = sourceText
        self.settings = settings
        self.attempt = attempt
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
