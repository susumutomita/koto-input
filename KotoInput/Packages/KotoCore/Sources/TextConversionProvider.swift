/// 変換モデルの利用可否。
public enum ProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
    /// モデルのダウンロード等で準備中。後で再試行できる。
    case preparing
}

/// 変換プロバイダの抽象。入力メソッドを特定のモデル実装に結合させない。
/// 実装は入力テキストを外部サービスへ送信してはならない。
public protocol TextConversionProvider: Sendable {
    func availability() async -> ProviderAvailability
    func convert(_ request: ConversionRequest) async throws -> ConversionResult
    /// 変換要求に先立ってモデルや instructions の前処理を温める。
    /// composition 開始時に呼ばれる。実装は任意（デフォルトは何もしない）。
    func prewarm(settings: ConversionSettings) async
}

extension TextConversionProvider {
    public func prewarm(settings: ConversionSettings) async {}
}
