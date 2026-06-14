import Foundation

/// かな漢字変換の一次変換器（ADR-0016）。mozc 全辞書（MozcDictionary）と連接
/// 行列（ConnectionMatrix）から、読み（かな）全体を Viterbi 最短経路で最適に
/// 文節分割・変換する。単語生起コスト + 連接コストの和を最小化する経路を選ぶため、
/// 貪欲最長一致と違い「わたしはがっこうにいく → 私は学校に行く」のように
/// 文脈境界を正しく切れる。決定的（同一読み → 同一既定出力）。
///
/// 役割分担: 辞書ラティスが「正解の表記を候補に必ず含める」決定的な一次変換を
/// 担い、AI（AppleFoundationModelsProvider）が文脈での単語選択・整形を担う。
/// `nBest` が出す上位候補を AI に渡せば、自由生成でなく「候補から選ぶ」制約
/// タスクになり、弱いオンデバイスモデルでも質が安定する（HybridConversionProvider）。
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
    /// n-best 列挙の安全弁（pop 回数の上限）。
    private static let nBestPopLimit = 50000
    private static let infinity = Int.max / 4

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
        /// 単語生起コスト（カタカナ罰則込み）。
        let wordCost: Int
        /// 前向き最小コスト（BOS → このノードの末尾）。
        var bestCost: Int
        /// 単一最良経路の前ノード index（n-best では使わない）。
        var prev: Int
    }

    /// ラティス（ノード列と位置→ノードの索引）。BOS は常に index 0
    /// （start = end = 0, rid = 0, cost 0）。
    private struct Lattice {
        var nodes: [Node]
        /// 位置（byte）→ そこで終わるノード index 群。
        var endingAt: [[Int]]
        /// 位置（byte）→ そこから始まるノード index 群。
        var startingAt: [[Int]]
        let end: Int
    }

    /// 読みからラティスを構築し、前向き Viterbi（bestCost / prev）まで埋める。
    private func buildLattice(query: [UInt8]) -> Lattice {
        var bounds: [Int] = []
        var p = 0
        while p < query.count {
            bounds.append(p)
            p += Self.utf8Width(query[p])
        }
        bounds.append(query.count)
        let end = query.count

        var nodes: [Node] = []
        var endingAt = [[Int]](repeating: [], count: end + 1)
        var startingAt = [[Int]](repeating: [], count: end + 1)
        // BOS。
        nodes.append(
            Node(
                start: 0, end: 0, surface: "", leftID: 0, rightID: 0,
                wordCost: 0, bestCost: 0, prev: -1
            )
        )
        endingAt[0] = [0]

        for start in bounds where start < end {
            let preds = endingAt[start]
            if preds.isEmpty { continue }

            var starting: [(end: Int, surface: String, lid: Int, rid: Int, cost: Int)] = []
            for match in dictionary.matchingPrefixes(of: query, from: start, charBoundaries: bounds) {
                for entry in match.entries {
                    starting.append(
                        (match.end, entry.surface, entry.leftID, entry.rightID, entry.cost)
                    )
                }
            }
            let next = start + Self.utf8Width(query[start])
            let kana = String(decoding: query[start..<next], as: UTF8.self)
            starting.append((next, kana, Self.unknownPOS, Self.unknownPOS, Self.unknownCost))

            for cand in starting {
                var wordCost = cand.cost
                // カタカナ罰則: ひらがな読みに対する全カタカナ表記（固有名詞の音写
                // など）は通常テキストでは誤りが多い。連接コストが少ない分だけ長い
                // カタカナ語が正しい短い分割に勝つのを抑える。読みに長音符 ー を含む
                // 借用語（こーひー→コーヒー 等）は罰則対象にしない。
                let spanReading = query[start..<cand.end]
                if Self.isAllKatakana(cand.surface), !spanReading.contains(0xBC /* ー の末尾 byte */) {
                    wordCost += Self.katakanaPenalty
                }
                var bestCost = Int.max
                var bestPrev = -1
                for predIdx in preds {
                    let pred = nodes[predIdx]
                    let c = pred.bestCost + connection.cost(rightID: pred.rightID, leftID: cand.lid)
                    if c < bestCost {
                        bestCost = c
                        bestPrev = predIdx
                    }
                }
                if bestPrev < 0 { continue }
                nodes.append(
                    Node(
                        start: start, end: cand.end, surface: cand.surface,
                        leftID: cand.lid, rightID: cand.rid, wordCost: wordCost,
                        bestCost: bestCost + wordCost, prev: bestPrev
                    )
                )
                let idx = nodes.count - 1
                endingAt[cand.end].append(idx)
                startingAt[start].append(idx)
            }
        }
        return Lattice(nodes: nodes, endingAt: endingAt, startingAt: startingAt, end: end)
    }

    /// 読み（かな）を Viterbi 最短経路で変換する。
    public func convert(reading: String) -> Result {
        let query = [UInt8](reading.utf8)
        guard !query.isEmpty else { return Result(best: "", segments: []) }

        let lattice = buildLattice(query: query)
        let nodes = lattice.nodes
        let end = lattice.end

        var bestEnd = -1
        var bestEndCost = Int.max
        for idx in lattice.endingAt[end] {
            let node = nodes[idx]
            let c = node.bestCost + connection.cost(rightID: node.rightID, leftID: 0)
            if c < bestEndCost {
                bestEndCost = c
                bestEnd = idx
            }
        }
        guard bestEnd >= 0 else { return Result(best: reading, segments: []) }

        var chain: [Int] = []
        var cur = bestEnd
        while cur > 0 {
            chain.append(cur)
            cur = nodes[cur].prev
        }
        chain.reverse()

        var segments: [Segment] = []
        segments.reserveCapacity(chain.count)
        for idx in chain {
            let node = nodes[idx]
            let segReading = String(decoding: query[node.start..<node.end], as: UTF8.self)
            let alts = dictionary.entries(of: query, start: node.start, end: node.end)
                .map(\.surface)
            var candidates = [node.surface]
            for alt in alts where alt != node.surface {
                candidates.append(alt)
            }
            segments.append(Segment(reading: segReading, candidates: candidates))
        }
        return Result(best: segments.map(\.best).joined(), segments: segments)
    }

    /// 読みに対する上位 maxCandidates 個の異なる変換文字列を、コスト昇順で返す
    /// （先頭が単一最良）。AI に「候補から選ぶ」制約タスクとして渡す用途。
    /// 後方最小コスト（bwd）を許容ヒューリスティックにした A* で厳密 k-best を取る。
    public func nBest(reading: String, maxCandidates: Int) -> [String] {
        let query = [UInt8](reading.utf8)
        guard !query.isEmpty, maxCandidates > 0 else { return [] }
        let lattice = buildLattice(query: query)
        let nodes = lattice.nodes
        let end = lattice.end
        guard !lattice.endingAt[end].isEmpty else { return [] }

        // 後方最小コスト bwd[node] = ノード末尾 → EOS の最小コスト。
        var bwd = [Int](repeating: Self.infinity, count: nodes.count)
        // 末尾で終わるノードは EOS への連接コスト。
        for idx in lattice.endingAt[end] {
            bwd[idx] = connection.cost(rightID: nodes[idx].rightID, leftID: 0)
        }
        // end の降順にノードを処理する（end が大きいほど EOS に近い）。
        let order = nodes.indices.sorted { nodes[$0].end > nodes[$1].end }
        for idx in order where nodes[idx].end < end {
            let node = nodes[idx]
            var best = bwd[idx]
            for nextIdx in lattice.startingAt[node.end] {
                let next = nodes[nextIdx]
                guard bwd[nextIdx] < Self.infinity else { continue }
                let c = connection.cost(rightID: node.rightID, leftID: next.leftID)
                    + next.wordCost + bwd[nextIdx]
                if c < best { best = c }
            }
            bwd[idx] = best
        }

        // A*: 状態 = (ノード index, 親状態 index)。優先度 = accum + bwd[node]。
        struct State { let node: Int; let parent: Int }
        var states: [State] = [State(node: 0, parent: -1)]  // BOS
        var heap = MinHeap()
        heap.push(priority: bwd[0], accum: 0, state: 0)

        var results: [String] = []
        var seen = Set<String>()
        var pops = 0
        while let top = heap.pop(), pops < Self.nBestPopLimit {
            pops += 1
            let node = nodes[states[top.state].node]
            if node.end == end {
                // 完成経路。表記を親を辿って復元する（BOS は除く）。
                var surfaces: [String] = []
                var s = top.state
                while s > 0 {  // states[0] は BOS
                    surfaces.append(nodes[states[s].node].surface)
                    s = states[s].parent
                }
                let text = surfaces.reversed().joined()
                if !text.isEmpty, seen.insert(text).inserted {
                    results.append(text)
                    if results.count >= maxCandidates { break }
                }
                continue
            }
            for nextIdx in lattice.startingAt[node.end] {
                let next = nodes[nextIdx]
                let newAccum = top.accum
                    + connection.cost(rightID: node.rightID, leftID: next.leftID)
                    + next.wordCost
                guard bwd[nextIdx] < Self.infinity else { continue }
                states.append(State(node: nextIdx, parent: top.state))
                heap.push(priority: newAccum + bwd[nextIdx], accum: newAccum, state: states.count - 1)
            }
        }
        return results
    }

    private static func utf8Width(_ lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead < 0xE0 { return 2 }
        if lead < 0xF0 { return 3 }
        return 4
    }
}

/// n-best A* 用の最小ヒープ（priority 昇順）。同 priority は挿入順を保たないが
/// 厳密 k-best には影響しない（同コスト経路はいずれも列挙される）。
private struct MinHeap {
    private struct Item { let priority: Int; let accum: Int; let state: Int }
    private var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(priority: Int, accum: Int, state: Int) {
        items.append(Item(priority: priority, accum: accum, state: state))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].priority <= items[i].priority { break }
            items.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (priority: Int, accum: Int, state: Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            let n = items.count
            while true {
                let l = 2 * i + 1
                let r = 2 * i + 2
                var smallest = i
                if l < n, items[l].priority < items[smallest].priority { smallest = l }
                if r < n, items[r].priority < items[smallest].priority { smallest = r }
                if smallest == i { break }
                items.swapAt(i, smallest)
                i = smallest
            }
        }
        return (top.priority, top.accum, top.state)
    }
}
