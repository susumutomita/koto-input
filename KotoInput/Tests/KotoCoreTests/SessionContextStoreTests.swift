import Foundation
import KotoCore
import Testing

@MainActor
@Suite("SessionContextStore のセッション内文脈保持")
struct SessionContextStoreTests {
    @Test("追記したテキストが古い→新しい順で snapshot に並ぶ")
    func appendKeepsInsertionOrder() {
        let store = SessionContextStore()
        store.append("いち")
        store.append("に")
        store.append("さん")
        #expect(store.snapshot() == ["いち", "に", "さん"])
    }

    @Test("6 件目の追記で最古のエントリが FIFO で落ちる")
    func sixthEntryEvictsOldest() {
        let store = SessionContextStore()
        for text in ["1", "2", "3", "4", "5", "6"] {
            store.append(text)
        }
        #expect(SessionContextStore.maxEntries == 5)
        #expect(store.snapshot() == ["2", "3", "4", "5", "6"])
    }

    @Test("合計 500 文字（UTF-16 長）を超えると古いものから落ちる")
    func totalLengthOverflowEvictsOldest() {
        let store = SessionContextStore()
        let first = String(repeating: "a", count: 200)
        let second = String(repeating: "b", count: 200)
        let third = String(repeating: "c", count: 200)
        store.append(first)
        store.append(second)
        store.append(third)
        // 600 > 500 なので最古の first が落ち、残り 400 で収まる。
        #expect(SessionContextStore.maxTotalUTF16Length == 500)
        #expect(store.snapshot() == [second, third])
    }

    @Test("501 文字の単一エントリは先頭 500 文字へ切り詰められる")
    func oversizedSingleEntryIsTruncated() {
        let store = SessionContextStore()
        store.append(String(repeating: "a", count: 501))
        #expect(store.snapshot() == [String(repeating: "a", count: 500)])
    }

    @Test("切り詰めはサロゲートペア（絵文字）の途中で切らない")
    func truncationDoesNotSplitSurrogatePairs() throws {
        let store = SessionContextStore()
        // 499 + 絵文字（UTF-16 で 2 単位）= 501 単位。500 単位目は
        // サロゲート前半なので、1 つ手前（499）で切る。
        store.append(String(repeating: "a", count: 499) + "😀")
        let entry = try #require(store.snapshot().first)
        #expect(entry == String(repeating: "a", count: 499))
        #expect(entry.utf16.count == 499)
    }

    @Test("ちょうど 500 文字（UTF-16 長）のエントリは切り詰めない")
    func exactLimitEntryIsKept() throws {
        let store = SessionContextStore()
        // 498 + 絵文字（2 単位）= ちょうど 500 単位。
        let text = String(repeating: "a", count: 498) + "😀"
        store.append(text)
        let entry = try #require(store.snapshot().first)
        #expect(entry == text)
        #expect(entry.utf16.count == 500)
    }

    @Test("空白・改行のみのテキストは無視される")
    func whitespaceOnlyTextIsIgnored() {
        let store = SessionContextStore()
        store.append("")
        store.append("   ")
        store.append(" \n\t ")
        #expect(store.snapshot().isEmpty)
    }

    @Test("改行は半角スペースへ正規化され、前後の空白は trim される")
    func newlinesAreNormalizedToSpaces() {
        let store = SessionContextStore()
        store.append("  いち\nぎょう\r\nめ\n")
        #expect(store.snapshot() == ["いち ぎょう め"])
    }

    @Test("clear で保持中の全エントリが消える")
    func clearRemovesAllEntries() {
        let store = SessionContextStore()
        store.append("いち")
        store.append("に")
        store.clear()
        #expect(store.snapshot().isEmpty)
        // clear 後も追記は再開できる。
        store.append("さん")
        #expect(store.snapshot() == ["さん"])
    }

    @Test("単一の書記素クラスタが上限を超えるテキストは空に切り詰められ、保持されない")
    func oversizedSingleGraphemeClusterIsIgnored() {
        let store = SessionContextStore()
        // 基底 1 文字 + 結合記号 500 個 = 1 書記素で UTF-16 501 単位。
        // 書記素境界への切り下げは startIndex まで戻るため空になる。
        store.append("a" + String(repeating: "\u{0301}", count: 500))
        #expect(store.snapshot().isEmpty)
    }

    @Test("enabled false での append は追記せず保持分を全消去する（OFF 即時消去の入口）")
    func appendWhileDisabledClearsEntries() {
        let store = SessionContextStore()
        store.append("いち")
        store.append("に", enabled: false)
        #expect(store.snapshot().isEmpty)
    }

    @Test("enabled false での snapshot は空を返し、保持分も全消去する")
    func snapshotWhileDisabledClearsEntries() {
        let store = SessionContextStore()
        store.append("いち")
        #expect(store.snapshot(enabled: false).isEmpty)
        // 消去は snapshot の戻り値だけでなく保持状態にも及ぶ。
        #expect(store.snapshot().isEmpty)
    }
}
