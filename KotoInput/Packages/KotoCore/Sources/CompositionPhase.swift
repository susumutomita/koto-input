/// composition の明示的な状態。イベントハンドラに状態を分散させない。
public enum CompositionPhase: Equatable, Sendable {
    case idle
    case composing
    case converting(requestID: ConversionRequestID)
    case converted(requestID: ConversionRequestID)
    case failed(message: String)
}

/// InputController が描画に使う、表示用の変換ステータス。
public enum ConversionStatus: Equatable, Sendable {
    case idle
    case composing
    case converting
    case converted
    case failed(message: String)
}
