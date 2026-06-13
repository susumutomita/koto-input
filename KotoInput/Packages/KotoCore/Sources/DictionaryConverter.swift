import Foundation

/// 決定論的なかな漢字変換の一次変換器（ハイブリッド変換の辞書バックボーン、
/// ADR-0016）。読み（かな）を左から最長一致でセグメント分割し、各セグメントに
/// 辞書から最小コストの表記を選んで連結する。I/O とモデルに依存しない純ロジック
/// として KotoCore に置く。
///
/// 役割分担: 辞書が「正解の表記を候補集合に必ず含める」決定的な一次変換を担い、
/// AI（AppleFoundationModelsProvider）が文脈での再ランクと整形を担う
/// （HybridConversionProvider が両者を合成する）。
///
/// 決定性: 同一読みは常に同一の既定出力を返す。最小コスト選択は cost 昇順 →
/// 表記のコード順の安定順序で一意に定める。辞書ヒットしないセグメントはかなの
/// まま残し、後段の AI とフォールバックに委ねる。
public struct DictionaryConverter: Sendable {
    /// 辞書の 1 エントリ（読み・表記・コスト）。cost は mozc dictionary_oss の
    /// 単語生起コストで、小さいほど高頻度・優先。
    public struct Entry: Sendable, Equatable {
        public let reading: String
        public let surface: String
        public let cost: Int

        public init(reading: String, surface: String, cost: Int) {
            self.reading = reading
            self.surface = surface
            self.cost = cost
        }
    }

    /// 変換結果の 1 セグメント。読みと、その読みに対する候補表記
    /// （既定 = 先頭、以降は代替。cost 昇順 → 表記コード順）を持つ。
    /// 辞書ヒットしないかなセグメントは candidates == [reading]。
    public struct Segment: Sendable, Equatable {
        public let reading: String
        /// 候補表記。先頭が既定（最小コスト）。常に非空。
        public let candidates: [String]

        public init(reading: String, candidates: [String]) {
            self.reading = reading
            self.candidates = candidates
        }

        /// 既定（最小コスト）の表記。
        public var best: String { candidates.first ?? reading }
    }

    /// 変換結果。単一最良文字列とセグメントごとの代替候補集合。
    public struct Result: Sendable, Equatable {
        /// 各セグメントの既定表記を連結した単一最良文字列。
        public let best: String
        /// セグメント列（左→右）。
        public let segments: [Segment]

        public init(best: String, segments: [Segment]) {
            self.best = best
            self.segments = segments
        }
    }

    /// 読み → 候補表記（cost 昇順 → 表記コード順で安定整列済み）。
    private let table: [String: [String]]
    /// 最長一致の探索上限（辞書中の最長読みの文字数）。範囲外まで部分文字列を
    /// 切り出さないための上界。
    private let maxReadingLength: Int

    /// エントリ列から辞書を構築する。同一 (reading) 内は cost 昇順 →
    /// 表記コード順で安定整列し、同一表記は最小 cost のものへ畳む。
    public init(entries: [Entry]) {
        var grouped: [String: [(surface: String, cost: Int)]] = [:]
        for entry in entries {
            grouped[entry.reading, default: []].append((entry.surface, entry.cost))
        }
        var table: [String: [String]] = [:]
        var maxLength = 0
        for (reading, var candidates) in grouped {
            // 同一表記は最小 cost を残す（生データの重複・別 POS 由来を畳む）。
            var bestCostBySurface: [String: Int] = [:]
            for candidate in candidates {
                if let existing = bestCostBySurface[candidate.surface] {
                    bestCostBySurface[candidate.surface] = min(existing, candidate.cost)
                } else {
                    bestCostBySurface[candidate.surface] = candidate.cost
                }
            }
            candidates = bestCostBySurface.map { (surface: $0.key, cost: $0.value) }
            // 安定順序: cost 昇順 → 表記の Unicode スカラー順。同点を一意化する。
            candidates.sort {
                if $0.cost != $1.cost { return $0.cost < $1.cost }
                return $0.surface.unicodeScalars.lexicographicallyPrecedes(
                    $1.surface.unicodeScalars
                )
            }
            table[reading] = candidates.map(\.surface)
            maxLength = max(maxLength, reading.count)
        }
        self.table = table
        self.maxReadingLength = maxLength
    }

    /// 読み（かな）を最長一致でセグメント分割し、単一最良 + 代替候補を返す。
    /// 辞書ヒットしないかなは連続する範囲を 1 つのかなセグメントにまとめる。
    public func convert(reading: String) -> Result {
        let characters = Array(reading)
        guard !characters.isEmpty else {
            return Result(best: "", segments: [])
        }

        var segments: [Segment] = []
        var index = 0
        // 連続する未ヒットかなを溜めるバッファ。辞書ヒットの直前で flush する。
        var pendingKana = ""

        func flushPendingKana() {
            guard !pendingKana.isEmpty else { return }
            segments.append(Segment(reading: pendingKana, candidates: [pendingKana]))
            pendingKana = ""
        }

        while index < characters.count {
            if let (length, candidates) = longestMatch(in: characters, at: index) {
                flushPendingKana()
                let matchedReading = String(characters[index..<(index + length)])
                segments.append(
                    Segment(reading: matchedReading, candidates: candidates)
                )
                index += length
            } else {
                pendingKana.append(characters[index])
                index += 1
            }
        }
        flushPendingKana()

        let best = segments.map(\.best).joined()
        return Result(best: best, segments: segments)
    }

    /// position から始まる最長の辞書一致を返す（一致長・候補表記）。
    /// 無ければ nil。探索は maxReadingLength で上限を切る。
    private func longestMatch(
        in characters: [Character],
        at position: Int
    ) -> (length: Int, candidates: [String])? {
        let upperBound = min(maxReadingLength, characters.count - position)
        guard upperBound > 0 else { return nil }
        var length = upperBound
        while length >= 1 {
            let candidateReading = String(characters[position..<(position + length)])
            if let candidates = table[candidateReading] {
                return (length, candidates)
            }
            length -= 1
        }
        return nil
    }
}

// MARK: - 同梱辞書リソースのロード

extension DictionaryConverter {
    /// 同梱辞書（mozc dictionary_oss の高頻度サブセット）が見つからない・壊れて
    /// いる場合のエラー。
    public enum LoadError: Error, Equatable {
        case resourceNotFound
        case decodingFailed
    }

    /// SwiftPM リソースとして同梱した辞書サブセット（Resources/
    /// dictionary-subset.tsv、reading\tsurface\tcost）をロードする。
    /// 生成は Tools/mozc-dictionary-subset/build-subset.sh、帰属は
    /// リポジトリ直下 THIRD-PARTY-LICENSES。
    public static func bundled() throws -> DictionaryConverter {
        guard
            let url = Bundle.module.url(
                forResource: "dictionary-subset",
                withExtension: "tsv"
            )
        else {
            throw LoadError.resourceNotFound
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LoadError.decodingFailed
        }
        return DictionaryConverter(entries: parseTSV(text))
    }

    /// TSV（reading\tsurface\tcost、1 行 1 エントリ）をパースする。形式不正な
    /// 行は黙って捨てず、cost が整数でない・列不足の行はスキップする
    /// （生成側で保証されるが防御的に）。
    static func parseTSV(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = rawLine.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard columns.count == 3, let cost = Int(columns[2]) else { continue }
            let reading = String(columns[0])
            let surface = String(columns[1])
            guard !reading.isEmpty, !surface.isEmpty else { continue }
            entries.append(Entry(reading: reading, surface: surface, cost: cost))
        }
        return entries
    }
}
