import Foundation

/// mozc dictionary_oss 全辞書のローダ（ADR-0016）。読み（かな）をキーに、
/// 表記・POS（left_id / right_id）・単語生起コストを引く。Viterbi ラティスの
/// 語彙バックボーン。
///
/// バイナリ `dictionary.bin`（raw DEFLATE 展開後）のレイアウト:
///   header(20B): u32 magic | u32 readingCount | u32 entryCount
///               | u32 readingBlobLen | u32 surfaceBlobLen
///   readingRecords[readingCount]（reading のバイト昇順）:
///               u32 readingOffset | u16 readingLen | u32 firstEntry | u16 entryCount
///   entries[entryCount]（同一 reading 内は cost 昇順 → 表記順）:
///               u32 surfaceOffset | u16 surfaceLen | u16 leftID | u16 rightID | u16 cost
///   readingBlob | surfaceBlob: UTF-8 バイト列
/// 生成は `Tools/mozc-dictionary/build-dictionary.py`。リトルエンディアン前提。
public struct MozcDictionary: Sendable {
    public struct Entry: Sendable, Equatable {
        public let surface: String
        public let leftID: Int
        public let rightID: Int
        public let cost: Int

        public init(surface: String, leftID: Int, rightID: Int, cost: Int) {
            self.surface = surface
            self.leftID = leftID
            self.rightID = rightID
            self.cost = cost
        }
    }

    public enum LoadError: Error, Equatable {
        case resourceNotFound
        case decompressionFailed
        case malformed
    }

    private static let magic: UInt32 = 0x4B4F_544F  // 'KOTO'
    private static let headerSize = 20
    private static let recordSize = 12
    private static let entrySize = 12

    private let bytes: [UInt8]
    public let readingCount: Int
    private let entryCount: Int
    private let recordBase: Int
    private let entryBase: Int
    private let readingBlobBase: Int
    private let surfaceBlobBase: Int

    init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.headerSize else { throw LoadError.malformed }
        func u32(_ off: Int) -> Int {
            Int(UInt32(bytes[off]) | (UInt32(bytes[off + 1]) << 8)
                | (UInt32(bytes[off + 2]) << 16) | (UInt32(bytes[off + 3]) << 24))
        }
        guard UInt32(u32(0)) == Self.magic else { throw LoadError.malformed }
        let readingCount = u32(4)
        let entryCount = u32(8)
        let readingBlobLen = u32(12)
        let surfaceBlobLen = u32(16)
        let recordBase = Self.headerSize
        let entryBase = recordBase + readingCount * Self.recordSize
        let readingBlobBase = entryBase + entryCount * Self.entrySize
        let surfaceBlobBase = readingBlobBase + readingBlobLen
        guard surfaceBlobBase + surfaceBlobLen == bytes.count else {
            throw LoadError.malformed
        }
        self.bytes = bytes
        self.readingCount = readingCount
        self.entryCount = entryCount
        self.recordBase = recordBase
        self.entryBase = entryBase
        self.readingBlobBase = readingBlobBase
        self.surfaceBlobBase = surfaceBlobBase
    }

    // MARK: - 低レベル読み出し

    private func u16(_ off: Int) -> Int {
        Int(UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8))
    }

    private func u32(_ off: Int) -> Int {
        Int(UInt32(bytes[off]) | (UInt32(bytes[off + 1]) << 8)
            | (UInt32(bytes[off + 2]) << 16) | (UInt32(bytes[off + 3]) << 24))
    }

    /// readingRecords[i] = (readingOffset, readingLen, firstEntry, entryCount)。
    private func record(_ i: Int) -> (rOff: Int, rLen: Int, first: Int, count: Int) {
        let p = recordBase + i * Self.recordSize
        return (u32(p), u16(p + 4), u32(p + 6), u16(p + 10))
    }

    /// readingRecords[i] の reading バイト列と query[range] をバイト辞書順で比較する。
    /// 戻り値 < 0: reading < query, 0: 等しい, > 0: reading > query。
    private func compareReading(
        _ i: Int, to query: [UInt8], _ qStart: Int, _ qEnd: Int
    ) -> Int {
        let rec = record(i)
        let rStart = readingBlobBase + rec.rOff
        let rEnd = rStart + rec.rLen
        var a = rStart
        var b = qStart
        while a < rEnd, b < qEnd {
            let x = bytes[a]
            let y = query[b]
            if x != y { return x < y ? -1 : 1 }
            a += 1
            b += 1
        }
        let rRemain = rEnd - a
        let qRemain = qEnd - b
        if rRemain == 0, qRemain == 0 { return 0 }
        return rRemain == 0 ? -1 : 1
    }

    /// query[qStart..<qEnd] 以上の reading を持つ最小の record index を返す
    /// （[lo, hi) の範囲で二分探索）。
    private func lowerBound(
        _ query: [UInt8], _ qStart: Int, _ qEnd: Int, _ lo: Int, _ hi: Int
    ) -> Int {
        var lo = lo
        var hi = hi
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareReading(mid, to: query, qStart, qEnd) < 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    private func entries(at recordIndex: Int) -> [Entry] {
        let rec = record(recordIndex)
        var result: [Entry] = []
        result.reserveCapacity(rec.count)
        for k in 0..<rec.count {
            let e = entryBase + (rec.first + k) * Self.entrySize
            let sOff = u32(e)
            let sLen = u16(e + 4)
            let lid = u16(e + 6)
            let rid = u16(e + 8)
            let cost = u16(e + 10)
            let sStart = surfaceBlobBase + sOff
            let surface = String(decoding: bytes[sStart..<(sStart + sLen)], as: UTF8.self)
            result.append(Entry(surface: surface, leftID: lid, rightID: rid, cost: cost))
        }
        return result
    }

    // MARK: - 探索 API

    /// query の byte 位置 start から始まり、辞書の reading が query の接頭辞に
    /// 一致するものを全て返す（最長一致だけでなく全ての長さ）。end は一致した
    /// reading の終端 byte 位置。reading のバイト長は文字境界に整列する。
    ///
    /// 接頭辞 P で始まる reading が 1 つも無くなったら、それより長い接頭辞でも
    /// 一致は無いので列挙を打ち切る（prune）。各長さの lowerBound は探索範囲を
    /// 単調に狭めて再利用する。
    public func matchingPrefixes(
        of query: [UInt8],
        from start: Int,
        charBoundaries: [Int]
    ) -> [(end: Int, entries: [Entry])] {
        var matches: [(end: Int, entries: [Entry])] = []
        var lo = 0
        var hi = readingCount
        // start の次の文字境界から順に終端を伸ばす。
        guard let startIdx = charBoundaries.firstIndex(of: start) else { return matches }
        var idx = startIdx + 1
        while idx < charBoundaries.count {
            let end = charBoundaries[idx]
            lo = lowerBound(query, start, end, lo, hi)
            if lo >= readingCount { break }
            // record[lo] の reading が接頭辞 query[start..<end] で始まらなければ、
            // これ以上長い接頭辞でも一致は出ないので打ち切る。
            let cmp = compareReading(lo, to: query, start, end)
            // cmp == 0: 完全一致。cmp > 0: reading は接頭辞より大きいが、接頭辞で
            // 始まるなら（reading が query[start..<end] を接頭辞に持つ）まだ続行。
            if cmp == 0 {
                matches.append((end: end, entries: entries(at: lo)))
            } else if !readingHasPrefix(lo, query, start, end) {
                break
            }
            // 次の長さでは reading >= 現在の接頭辞なので lo は再利用できる。
            idx += 1
        }
        return matches
    }

    /// record[i] の reading が query[start..<end] を接頭辞に持つか。
    private func readingHasPrefix(
        _ i: Int, _ query: [UInt8], _ start: Int, _ end: Int
    ) -> Bool {
        let rec = record(i)
        let rLen = rec.rLen
        let need = end - start
        if rLen < need { return false }
        let rStart = readingBlobBase + rec.rOff
        var a = rStart
        var b = start
        while b < end {
            if bytes[a] != query[b] { return false }
            a += 1
            b += 1
        }
        return true
    }

    /// query[start..<end] と完全一致する reading の entries を返す（無ければ空）。
    /// 候補切り替え用の代替表記の取得に使う。
    public func entries(of query: [UInt8], start: Int, end: Int) -> [Entry] {
        let lo = lowerBound(query, start, end, 0, readingCount)
        guard lo < readingCount, compareReading(lo, to: query, start, end) == 0 else {
            return []
        }
        return entries(at: lo)
    }

    // MARK: - ロード

    public static func bundled() throws -> MozcDictionary {
        guard
            let url = Bundle.module.url(forResource: "dictionary", withExtension: "bin")
        else {
            throw LoadError.resourceNotFound
        }
        guard let raw = try? Data(contentsOf: url) else {
            throw LoadError.resourceNotFound
        }
        guard let inflated = try? BinaryResource.inflate(raw) else {
            throw LoadError.decompressionFailed
        }
        return try MozcDictionary(bytes: [UInt8](inflated))
    }
}
