import Foundation

/// かな漢字変換の一次変換器（ADR-0016）。mozc 全辞書（MozcDictionary）と連接
/// 行列（ConnectionMatrix）から、読み（かな）全体を Viterbi 最短経路で最適に
/// 文節分割・変換する。単語生起コスト + 連接コストの和を最小化する経路を選ぶため、
/// 貪欲最長一致と違い「わたしはがっこうにいく → 私は学校に行く」のように
/// 文脈境界を正しく切れる。決定的（同一読み → 同一既定出力）。
///
/// 役割分担: 辞書ラティスが「正解の表記を候補に必ず含める」決定的な一次変換を
/// 担い、AI（AppleFoundationModelsProvider）が文脈での再ランクと整形を担う
/// （HybridConversionProvider が両者を合成する）。
public struct LatticeConverter: Sendable {
    /// 変換結果の 1 セグメント。読みと候補表記（既定 = 先頭）。
    public struct Segment: Sendable, Equatable {
        public let reading: String
        /// 候補表記。先頭が既定（採用された表記）。常に非空。
        public let candidates: [String]

        public init(reading: String, candidates: [String]) {
            self.reading = reading
            self.candidates = candidates
        }

        public var best: String { candidates.first ?? reading }
    }

    /// 変換結果。単一最良文字列とセグメント列。
    public struct Result: Sendable, Equatable {
        public let best: String
        public let segments: [Segment]

        public init(best: String, segments: [Segment]) {
            self.best = best
            self.segments = segments
        }
    }

    /// 辞書ヒットしない文字に与える未知語ノードの POS（名詞一般相当）とコスト。
    /// 辞書語が常に優先されるよう高めに設定し、辞書外の文字はかなのまま残す。
    private static let unknownPOS = 1851
    private static let unknownCost = 10000
    /// 全カタカナ表記（ひらがな読みに対する音写）への加点。
    private static let katakanaPenalty = 5000

    /// 表記がすべてカタカナ（ァ〜ヶ・長音符・中黒）か。
    private static func isAllKatakana(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for u in s.unicodeScalars where !(0x30A1...0x30FC).contains(u.value) {
            return false
        }
        return true
    }

    private let dictionary: MozcDictionary
    private let connection: ConnectionMatrix

    public init(dictionary: MozcDictionary, connection: ConnectionMatrix) {
        self.dictionary = dictionary
        self.connection = connection
    }

    public static func bundled() throws -> LatticeConverter {
        LatticeConverter(
            dictionary: try MozcDictionary.bundled(),
            connection: try ConnectionMatrix.bundled()
        )
    }

    private struct Node {
        let start: Int
        let end: Int
        let surface: String
        let leftID: Int
        let rightID: Int
        var bestCost: Int
        var prev: Int
    }

    /// 読み（かな）を Viterbi 最短経路で変換する。
    public func convert(reading: String) -> Result {
        let query = [UInt8](reading.utf8)
        guard !query.isEmpty else { return Result(best: "", segments: []) }

        // 文字境界（UTF-8 リード byte 単位）を列挙する。
        var bounds: [Int] = []
        var p = 0
        while p < query.count {
            bounds.append(p)
            p += Self.utf8Width(query[p])
        }
        bounds.append(query.count)
        let end = query.count

        var nodes: [Node] = []
        // 位置（byte）→ そこで終わるノード index 群。
        var endingAt = [[Int]](repeating: [], count: end + 1)
        // BOS（位置 0 で終わる仮想ノード、rid = 0、コスト 0）。
        nodes.append(Node(start: 0, end: 0, surface: "", leftID: 0, rightID: 0, bestCost: 0, prev: -1))
        endingAt[0] = [0]

        for start in bounds where start < end {
            let preds = endingAt[start]
            if preds.isEmpty { continue }  // BOS から到達不能（未知語ノードで通常は到達する）

            var starting: [(end: Int, surface: String, lid: Int, rid: Int, cost: Int)] = []
            // 辞書ノード（接頭辞一致する全長さ・全表記）。
            for match in dictionary.matchingPrefixes(of: query, from: start, charBoundaries: bounds) {
                for entry in match.entries {
                    starting.append(
                        (match.end, entry.surface, entry.leftID, entry.rightID, entry.cost)
                    )
                }
            }
            // 未知語ノード（1 文字、かなのまま）。辞書が空でもラティスを連結に保つ。
            let next = start + Self.utf8Width(query[start])
            let kana = String(decoding: query[start..<next], as: UTF8.self)
            starting.append((next, kana, Self.unknownPOS, Self.unknownPOS, Self.unknownCost))

            for var cand in starting {
                // カタカナ罰則: ひらがな読みに対する全カタカナ表記（固有名詞の
                // 音写など）は通常テキストでは誤りが多い。連接コストが少ない分だけ
                // 長いカタカナ語が正しい短い分割に勝つのを抑える。読みに長音符 ー を
                // 含む借用語（こーひー→コーヒー 等）は罰則対象にしない。
                let spanReading = query[start..<cand.end]
                if Self.isAllKatakana(cand.surface), !spanReading.contains(0xBC /* ー の末尾 byte */) {
                    cand.cost += Self.katakanaPenalty
                }
                var bestCost = Int.max
                var bestPrev = -1
                for predIdx in preds {
                    let pred = nodes[predIdx]
                    let trans = connection.cost(rightID: pred.rightID, leftID: cand.lid)
                    let c = pred.bestCost + trans
                    if c < bestCost {
                        bestCost = c
                        bestPrev = predIdx
                    }
                }
                if bestPrev < 0 { continue }
                let node = Node(
                    start: start,
                    end: cand.end,
                    surface: cand.surface,
                    leftID: cand.lid,
                    rightID: cand.rid,
                    bestCost: bestCost + cand.cost,
                    prev: bestPrev
                )
                nodes.append(node)
                endingAt[cand.end].append(nodes.count - 1)
            }
        }

        // EOS: 終端で終わるノードから、EOS（lid = 0）への連接を足して最小を選ぶ。
        var bestEnd = -1
        var bestEndCost = Int.max
        for idx in endingAt[end] {
            let node = nodes[idx]
            let c = node.bestCost + connection.cost(rightID: node.rightID, leftID: 0)
            if c < bestEndCost {
                bestEndCost = c
                bestEnd = idx
            }
        }
        guard bestEnd >= 0 else { return Result(best: reading, segments: []) }

        // 逆順に辿って経路を復元する。
        var chain: [Int] = []
        var cur = bestEnd
        while cur > 0 {  // BOS（index 0）は除く
            chain.append(cur)
            cur = nodes[cur].prev
        }
        chain.reverse()

        var segments: [Segment] = []
        segments.reserveCapacity(chain.count)
        for idx in chain {
            let node = nodes[idx]
            let segReading = String(decoding: query[node.start..<node.end], as: UTF8.self)
            // 採用表記を先頭に、同じ読みの代替表記を cost 順で続ける。
            let alts = dictionary.entries(of: query, start: node.start, end: node.end)
                .map(\.surface)
            var candidates = [node.surface]
            for alt in alts where alt != node.surface {
                candidates.append(alt)
            }
            segments.append(Segment(reading: segReading, candidates: candidates))
        }

        let best = segments.map(\.best).joined()
        return Result(best: best, segments: segments)
    }

    private static func utf8Width(_ lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead < 0xE0 { return 2 }
        if lead < 0xF0 { return 3 }
        return 4
    }
}
