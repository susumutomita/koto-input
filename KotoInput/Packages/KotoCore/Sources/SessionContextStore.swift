import Foundation

/// セッション内文脈メモリ（ADR-0013 第一版）。同一プロセス内で commit した
/// テキストの直近数件を in-memory で保持する。ディスク永続は持たず、
/// プロセス終了で消える。診断ログ（ADR-0002）とは別概念の「作業記憶」で、
/// 収集・注入は ConversionSettings.contextMemoryEnabled の opt-in が前提。
/// InputController が `.shared` を全 coordinator に渡すことで、全アプリの
/// 入力が合流する IME の価値を保つ（テストは個別インスタンスを注入する）。
@MainActor
public final class SessionContextStore {
    /// プロセス全体で共有する唯一の store。
    public static let shared = SessionContextStore()

    /// 保持する最大件数。超えたら古いものから FIFO で破棄する。
    public static let maxEntries = 5
    /// 全エントリ合計の最大 UTF-16 長。プロンプトの [CONTEXT] 上限と一致し、
    /// 1 エントリの切り詰め上限も兼ねる（単独で予算全体を使い切れる）。
    public static let maxTotalUTF16Length = 500

    private var entries: [String] = []

    public init() {}

    /// commit テキストを正規化して追記する。改行は箇条書きの 1 エントリ
    /// 1 行を壊すため半角スペースへ正規化し、前後の空白は取り除く。
    /// 空になったテキストは無視する。上限超過は古いものから FIFO で破棄する。
    ///
    /// `enabled` は ConversionSettings.contextMemoryEnabled のスナップショット。
    /// OFF の観測時に保持分を全消去する「ON→OFF 即時消去」（ADR-0013）の
    /// 正本は store の入口（append / snapshot）に置き、追記・読み出しの
    /// 呼び出し側で消去ポリシーが分岐・乖離しないようにする。
    public func append(_ text: String, enabled: Bool = true) {
        guard enabled else {
            clear()
            return
        }
        let normalized = text
            .collapsedToSingleLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let entry = truncated(normalized)
        // 単一の書記素クラスタが上限を超えるテキスト（結合記号の連打等）は
        // 書記素境界への切り下げで空になる。空エントリは保持しない。
        guard !entry.isEmpty else { return }
        entries.append(entry)
        // 件数と合計長の両方を満たすまで古いものから落とす。切り詰め済みの
        // 新エントリは単独で必ず上限内なので、このループは止まる。
        var total = entries.reduce(0) { $0 + $1.utf16.count }
        while entries.count > Self.maxEntries || total > Self.maxTotalUTF16Length {
            total -= entries.removeFirst().utf16.count
        }
    }

    /// 保持中のエントリ（古い→新しい順）。`enabled` が false（設定 OFF）の
    /// 観測時は保持分を全消去して空を返す（append と対の消去入口）。
    public func snapshot(enabled: Bool = true) -> [String] {
        guard enabled else {
            clear()
            return []
        }
        return entries
    }

    /// 保持中の全エントリを即時に消去する。OFF への切替・全消去操作で使う。
    public func clear() {
        entries.removeAll()
    }

    /// 上限を超えるエントリを先頭 maxTotalUTF16Length（UTF-16 長）以内へ
    /// 切り詰める。境界判定は UTF16TextEditing.boundaryIndex（書記素境界へ
    /// の切り下げ）を再利用し、サロゲートペアの途中では決して切らない。
    private func truncated(_ text: String) -> String {
        guard text.utf16.count > Self.maxTotalUTF16Length else { return text }
        let boundary = UTF16TextEditing.boundaryIndex(
            in: text,
            utf16Offset: Self.maxTotalUTF16Length
        )
        return String(text[..<boundary])
    }
}
