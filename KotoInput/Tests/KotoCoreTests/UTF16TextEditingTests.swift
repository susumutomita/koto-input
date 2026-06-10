import KotoCore
import Testing

@Suite("UTF16TextEditing の編集ヘルパー")
struct UTF16TextEditingTests {
    @Test("日本語テキストの末尾に挿入できる")
    func insertAtEnd() {
        let (text, selection) = UTF16TextEditing.insert(
            "か",
            into: "に",
            at: .cursor(at: 1)
        )
        #expect(text == "にか")
        #expect(selection == .cursor(at: 2))
    }

    @Test("選択範囲を挿入で置き換える")
    func replaceSelection() {
        let (text, selection) = UTF16TextEditing.insert(
            "日本語",
            into: "hello",
            at: TextSelection(location: 1, length: 3)
        )
        #expect(text == "h日本語o")
        #expect(selection == .cursor(at: 4))
    }

    @Test("ZWJ シーケンスの絵文字を 1 回の deleteBackward で丸ごと消す")
    func deleteEmojiFamily() {
        let family = "👨‍👩‍👧‍👦"
        let text = "a" + family
        let (result, selection) = UTF16TextEditing.deleteBackward(
            in: text,
            at: .cursor(at: text.utf16.count)
        )
        #expect(result == "a")
        #expect(selection == .cursor(at: 1))
    }

    @Test("結合文字を含む書記素を 1 単位として削除する")
    func deleteCombiningCharacter() {
        let text = "か\u{3099}"
        let (result, selection) = UTF16TextEditing.deleteBackward(
            in: text,
            at: .cursor(at: text.utf16.count)
        )
        #expect(result.isEmpty)
        #expect(selection == .cursor(at: 0))
    }

    @Test("サロゲートペアの途中を指す位置は書記素境界へ切り下げる")
    func clampMidSurrogate() {
        let text = "🦀"
        let clamped = UTF16TextEditing.clampedSelection(
            TextSelection(location: 1, length: 0),
            in: text
        )
        #expect(clamped == .cursor(at: 0))
    }

    @Test("範囲外の選択はテキスト範囲内へクランプされる")
    func clampOutOfRange() {
        let clamped = UTF16TextEditing.clampedSelection(
            TextSelection(location: -5, length: 100),
            in: "abc"
        )
        #expect(clamped == TextSelection(location: 0, length: 3))
    }

    @Test("moveCursor は絵文字を 1 動作で飛び越える")
    func moveOverEmoji() {
        let text = "a👨‍👩‍👧‍👦b"
        let moved = UTF16TextEditing.moveCursor(
            in: text,
            from: .cursor(at: 1),
            offset: 1
        )
        #expect(moved == .cursor(at: 1 + "👨‍👩‍👧‍👦".utf16.count))
    }

    @Test("moveCursor は両端でクランプされる")
    func moveCursorClamps() {
        let movedLeft = UTF16TextEditing.moveCursor(
            in: "ab",
            from: .cursor(at: 0),
            offset: -3
        )
        #expect(movedLeft == .cursor(at: 0))
        let movedRight = UTF16TextEditing.moveCursor(
            in: "ab",
            from: .cursor(at: 2),
            offset: 5
        )
        #expect(movedRight == .cursor(at: 2))
    }

    @Test("先頭での deleteBackward は何もしない")
    func deleteAtStartIsNoop() {
        let (result, selection) = UTF16TextEditing.deleteBackward(
            in: "abc",
            at: .cursor(at: 0)
        )
        #expect(result == "abc")
        #expect(selection == .cursor(at: 0))
    }
}
