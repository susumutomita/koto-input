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
}
