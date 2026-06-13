import Foundation

/// mozc dictionary_oss の POS 間連接コスト行列（ADR-0016）。Viterbi ラティスで
/// 左ノードの right_id から右ノードの left_id への遷移コストに使う。
///
/// バイナリ `connection.bin` = raw DEFLATE( u32 N | (N*N) u16 cost )。
/// index = rid * N + lid（mozc の row-major、先頭 0 = BOS→BOS）。生成は
/// `Tools/mozc-dictionary/build-dictionary.py`。リトルエンディアン前提（arm64）。
public struct ConnectionMatrix: Sendable {
    public enum LoadError: Error, Equatable {
        case resourceNotFound
        case decompressionFailed
        case malformed
    }

    /// POS ID の数（行列は size × size）。
    public let size: Int
    private let costs: [UInt16]

    public init(size: Int, costs: [UInt16]) {
        precondition(costs.count == size * size, "連接コスト数が size^2 と一致しない")
        self.size = size
        self.costs = costs
    }

    /// 左ノードの right_id から右ノードの left_id への遷移コスト。
    /// 範囲外の id は連接不可とみなして大きなコストを返す（防御的）。
    public func cost(rightID: Int, leftID: Int) -> Int {
        guard rightID >= 0, rightID < size, leftID >= 0, leftID < size else {
            return Int(UInt16.max)
        }
        return Int(costs[rightID * size + leftID])
    }

    /// 同梱 `connection.bin` をロードする。
    public static func bundled() throws -> ConnectionMatrix {
        guard
            let url = Bundle.module.url(forResource: "connection", withExtension: "bin")
        else {
            throw LoadError.resourceNotFound
        }
        guard let raw = try? Data(contentsOf: url) else {
            throw LoadError.resourceNotFound
        }
        return try decode(raw)
    }

    static func decode(_ raw: Data) throws -> ConnectionMatrix {
        guard let inflated = try? BinaryResource.inflate(raw) else {
            throw LoadError.decompressionFailed
        }
        guard inflated.count >= 4 else { throw LoadError.malformed }
        let n = Int(BinaryResource.readUInt32LE(inflated, at: 0))
        guard n > 0, inflated.count == 4 + n * n * 2 else { throw LoadError.malformed }
        var costs = [UInt16](repeating: 0, count: n * n)
        inflated.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            costs.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!, base + 4, n * n * 2)
            }
        }
        return ConnectionMatrix(size: n, costs: costs)
    }
}

/// 同梱バイナリリソースの共通処理（展開とリトルエンディアン読み出し）。
enum BinaryResource {
    /// raw DEFLATE（zlib/gzip ヘッダなし）を展開する。生成側 Python の
    /// `zlib.compressobj(wbits=-15)` と対称で、COMPRESSION_ZLIB が要求する
    /// 生 DEFLATE ストリームを復号する。
    static func inflate(_ raw: Data) throws -> Data {
        try (raw as NSData).decompressed(using: .zlib) as Data
    }

    static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }
}
