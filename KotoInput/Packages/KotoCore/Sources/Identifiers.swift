import Foundation

/// 1 つの composition（未確定入力のライフサイクル）を識別する。
/// commit / cancel で composition がリセットされるたびに新しい ID になり、
/// 古い変換結果が新しい composition を上書きすることを防ぐ。
public struct CompositionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// 1 回の変換要求を識別する。stale な変換結果の排除に使う。
public struct ConversionRequestID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
