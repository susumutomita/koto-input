/// marked text 内の選択範囲。macOS のテキスト API（NSRange）と整合するよう
/// UTF-16 オフセットで表現する。
public struct TextSelection: Equatable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public static func cursor(at location: Int) -> TextSelection {
        TextSelection(location: location, length: 0)
    }
}
