/// marked text 編集のための UTF-16 オフセットベースのヘルパー。
/// 位置は macOS のテキスト API（NSRange）と整合する UTF-16 単位で表現し、
/// 削除・カーソル移動は書記素クラスタ（Character）単位で行う。
/// 不正な範囲はクラッシュさせず境界へクランプする。
public enum UTF16TextEditing {
    /// UTF-16 オフセットを書記素境界に切り下げて String.Index へ変換する。
    /// サロゲートペアや結合文字の途中を指された場合は直前の境界に丸める。
    static func boundaryIndex(in text: String, utf16Offset target: Int) -> String.Index {
        let clamped = min(max(target, 0), text.utf16.count)
        var boundary = text.startIndex
        var current = text.startIndex
        while current < text.endIndex {
            let next = text.index(after: current)
            let nextOffset = text.utf16.distance(from: text.utf16.startIndex, to: next)
            if nextOffset <= clamped {
                boundary = next
                current = next
            } else {
                break
            }
        }
        return boundary
    }

    static func utf16Offset(of index: String.Index, in text: String) -> Int {
        text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    /// 選択範囲を書記素境界かつテキスト範囲内にクランプする。
    public static func clampedSelection(
        _ selection: TextSelection,
        in text: String
    ) -> TextSelection {
        let start = boundaryIndex(in: text, utf16Offset: selection.location)
        let end = boundaryIndex(
            in: text,
            utf16Offset: selection.location + max(selection.length, 0)
        )
        let clampedEnd = max(start, end)
        let startOffset = utf16Offset(of: start, in: text)
        let endOffset = utf16Offset(of: clampedEnd, in: text)
        return TextSelection(location: startOffset, length: endOffset - startOffset)
    }

    /// 選択範囲を挿入文字列で置き換え、カーソルを挿入末尾に置く。
    public static func insert(
        _ insertion: String,
        into text: String,
        at selection: TextSelection
    ) -> (text: String, selection: TextSelection) {
        let clamped = clampedSelection(selection, in: text)
        let start = boundaryIndex(in: text, utf16Offset: clamped.location)
        let end = boundaryIndex(in: text, utf16Offset: clamped.location + clamped.length)
        var result = text
        result.replaceSubrange(start..<end, with: insertion)
        let cursor = clamped.location + insertion.utf16.count
        return (result, .cursor(at: cursor))
    }

    /// 選択範囲があれば選択を削除、なければカーソル直前の書記素を 1 つ削除する。
    public static func deleteBackward(
        in text: String,
        at selection: TextSelection
    ) -> (text: String, selection: TextSelection) {
        let clamped = clampedSelection(selection, in: text)
        if clamped.length > 0 {
            return insert("", into: text, at: clamped)
        }
        let cursorIndex = boundaryIndex(in: text, utf16Offset: clamped.location)
        guard cursorIndex > text.startIndex else {
            return (text, .cursor(at: 0))
        }
        let previous = text.index(before: cursorIndex)
        var result = text
        result.removeSubrange(previous..<cursorIndex)
        return (result, .cursor(at: utf16Offset(of: previous, in: text)))
    }

    /// カーソルを書記素単位で offset 分移動する。範囲端でクランプし、
    /// 選択がある場合は移動方向側の端から動かす。
    public static func moveCursor(
        in text: String,
        from selection: TextSelection,
        offset: Int
    ) -> TextSelection {
        let clamped = clampedSelection(selection, in: text)
        let startOffset = offset >= 0 ? clamped.location + clamped.length : clamped.location
        var index = boundaryIndex(in: text, utf16Offset: startOffset)
        var remaining = abs(offset)
        while remaining > 0 {
            if offset > 0 {
                if index == text.endIndex { break }
                index = text.index(after: index)
            } else {
                if index == text.startIndex { break }
                index = text.index(before: index)
            }
            remaining -= 1
        }
        return .cursor(at: utf16Offset(of: index, in: text))
    }
}
