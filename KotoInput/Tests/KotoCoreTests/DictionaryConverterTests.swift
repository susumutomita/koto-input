import Foundation
import KotoCore
import Testing

@Suite("DictionaryConverter の決定論かな漢字変換")
struct DictionaryConverterTests {
    /// 実 mozc dictionary_oss 由来の小規模エントリで構成した辞書。スタブ表記は
    /// 使わず、実データに存在する (reading, surface, cost) を直接与える
    /// （cost は mozc 実値の近似で、相対順序のみが意味を持つ）。
    private func makeConverter() -> DictionaryConverter {
        DictionaryConverter(entries: [
            // ほうほう → 方法（mozc cost 2797）
            .init(reading: "ほうほう", surface: "方法", cost: 2797),
            // けっきょく → 結局（mozc cost 2684）
            .init(reading: "けっきょく", surface: "結局", cost: 2684),
            // にほんご → 日本語（mozc cost 3793）
            .init(reading: "にほんご", surface: "日本語", cost: 3793),
            // かんじ → 感じ（最小 cost 3283）/ 漢字（cost 4191）。代替候補の順序検証用。
            .init(reading: "かんじ", surface: "感じ", cost: 3283),
            .init(reading: "かんじ", surface: "漢字", cost: 4191),
            // 部分一致と最長一致の競合検証用: にほん → 日本（短い読み）
            .init(reading: "にほん", surface: "日本", cost: 3000),
            // 単漢字: の → 之（使わない・最長一致の確認用に長い読みを優先させる）
            .init(reading: "ご", surface: "語", cost: 6000),
        ])
    }

    @Test("代表的な読みが辞書経由で決定的に漢字化される")
    func convertsRepresentativeReadings() {
        let converter = makeConverter()
        #expect(converter.convert(reading: "ほうほう").best == "方法")
        #expect(converter.convert(reading: "けっきょく").best == "結局")
        #expect(converter.convert(reading: "にほんご").best == "日本語")
    }

    @Test("同一読みは常に同一の既定出力（最小コスト・安定）を返す")
    func deterministicBestSelection() {
        let converter = makeConverter()
        let first = converter.convert(reading: "かんじ").best
        let second = converter.convert(reading: "かんじ").best
        #expect(first == second)
        // 感じ（3283）が 漢字（4191）より最小コストなので既定に選ばれる。
        #expect(first == "感じ")
    }

    @Test("セグメントごとの代替表記をコスト昇順で返す")
    func returnsAlternativesByCost() {
        let converter = makeConverter()
        let result = converter.convert(reading: "かんじ")
        #expect(result.segments.count == 1)
        let segment = try! #require(result.segments.first)
        #expect(segment.reading == "かんじ")
        // 既定（最小コスト）+ 代替がコスト昇順で並ぶ。
        #expect(segment.candidates == ["感じ", "漢字"])
    }

    @Test("左から最長一致でセグメント分割する")
    func longestMatchSegmentation() {
        let converter = makeConverter()
        // にほんご は「にほん(日本)」+「ご(語)」ではなく、最長一致の
        // 「にほんご(日本語)」を 1 セグメントとして選ぶ。
        let result = converter.convert(reading: "にほんご")
        #expect(result.best == "日本語")
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.reading == "にほんご")
    }

    @Test("複数セグメントを連結し各セグメントの代替を保持する")
    func concatenatesMultipleSegments() {
        let converter = makeConverter()
        // ほうほうけっきょく → 方法結局（最長一致で 2 セグメント）。
        let result = converter.convert(reading: "ほうほうけっきょく")
        #expect(result.best == "方法結局")
        #expect(result.segments.map(\.reading) == ["ほうほう", "けっきょく"])
        #expect(result.segments.map(\.candidates) == [["方法"], ["結局"]])
    }

    @Test("辞書ヒットしないセグメントはかなのまま残す")
    func leavesUnmatchedKanaAsIs() {
        let converter = makeConverter()
        // 「を」は辞書に無いので、ほうほう(方法) + を(かな) + けっきょく(結局)。
        let result = converter.convert(reading: "ほうほうをけっきょく")
        #expect(result.best == "方法を結局")
        // かなセグメントは候補が自身のみ（変換なし）。
        let kanaSegment = result.segments.first { $0.reading == "を" }
        #expect(kanaSegment?.candidates == ["を"])
    }

    @Test("連続する未ヒットかなは 1 つのかなセグメントにまとめる")
    func mergesConsecutiveUnmatchedKana() {
        let converter = makeConverter()
        // 先頭の「あを」は辞書に無いので 1 つのかなセグメント。
        let result = converter.convert(reading: "あをほうほう")
        #expect(result.best == "あを方法")
        #expect(result.segments.map(\.reading) == ["あを", "ほうほう"])
    }

    @Test("空の読みは空の結果を返す")
    func emptyReadingYieldsEmptyResult() {
        let converter = makeConverter()
        let result = converter.convert(reading: "")
        #expect(result.best == "")
        #expect(result.segments.isEmpty)
    }

    // MARK: - 同梱辞書リソース（実 mozc サブセット・No Mock）

    @Test("同梱辞書をロードして代表読みを変換できる")
    func loadsBundledDictionary() throws {
        let converter = try DictionaryConverter.bundled()
        // 同梱した実 mozc サブセットに含まれる代表語。
        #expect(converter.convert(reading: "ほうほう").best == "方法")
        #expect(converter.convert(reading: "けっきょく").best == "結局")
        #expect(converter.convert(reading: "にほんご").best == "日本語")
    }

    @Test("同梱辞書の変換は決定的（同一読み→同一出力）")
    func bundledConversionIsDeterministic() throws {
        let converter = try DictionaryConverter.bundled()
        let a = converter.convert(reading: "ほうほうをけっきょく").best
        let b = converter.convert(reading: "ほうほうをけっきょく").best
        #expect(a == b)
    }

    @Test("同梱辞書に未収録の読みはかなのまま残す")
    func bundledLeavesUnknownKana() throws {
        let converter = try DictionaryConverter.bundled()
        // ランダムな未収録かな列はそのまま返る（フォールバックは呼び出し側）。
        let result = converter.convert(reading: "ぬぬぬぬ")
        #expect(result.best == "ぬぬぬぬ")
    }
}
