/// InputController が入力クライアントへ描画するためのレンダーモデル。
public struct CompositionViewState: Equatable, Sendable {
    /// nil のときは marked text を消去する。非 nil のときは Koto が所有する
    /// marked range 全体をこのテキストで置き換える。
    public let markedText: String?
    public let selection: TextSelection
    /// true のとき committedText を 1 回だけクライアントへ挿入する。
    public let shouldCommit: Bool
    public let committedText: String?
    public let status: ConversionStatus

    public init(
        markedText: String?,
        selection: TextSelection,
        shouldCommit: Bool = false,
        committedText: String? = nil,
        status: ConversionStatus
    ) {
        self.markedText = markedText
        self.selection = selection
        self.shouldCommit = shouldCommit
        self.committedText = committedText
        self.status = status
    }

    public static func from(state: CompositionState) -> CompositionViewState {
        let status: ConversionStatus
        switch state.phase {
        case .idle:
            status = .idle
        case .composing:
            status = .composing
        case .converting:
            status = .converting
        case .converted:
            status = .converted
        case .failed(let message):
            status = .failed(message: message)
        }
        let marked: String? = state.phase == .idle ? nil : state.displayedText
        return CompositionViewState(
            markedText: marked,
            selection: state.selection,
            status: status
        )
    }
}
