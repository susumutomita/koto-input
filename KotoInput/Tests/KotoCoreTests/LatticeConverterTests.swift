import Foundation
import KotoCore
import Testing

@Suite("LatticeConverter の Viterbi かな漢字変換（実 mozc 全辞書）")
struct LatticeConverterTests {
    // 実 mozc 全辞書 + 連接行列。1 度ロードして共有する（No Mock）。
    static let lattice: LatticeConverter = {
        do { return try LatticeConverter.bundled() } catch {
            fatalError("辞書のロードに失敗: \(error)")
        }
    }()

    @Test("代表的な読みを正しく漢字化する")
    func convertsRepresentativeReadings() {
        let cases: [(String, String)] = [
            ("ほうほう", "方法"),
            ("にほんご", "日本語"),
            ("きょうはいいてんきです", "今日はいい天気です"),
            ("にほんごをにゅうりょくする", "日本語を入力する"),
        ]
        for (reading, expected) in cases {
            #expect(
                LatticeConverterTests.lattice.convert(reading: reading).best == expected,
                "\(reading) の変換が期待と異なる"
            )
        }
    }

    @Test("同一読みは常に同一の既定出力を返す（決定性）")
    func conversionIsDeterministic() {
        let readings = ["わたしはがっこうにいく", "けっきょくほうほうはだせないのか", "ぬるぽ"]
        for reading in readings {
            let first = LatticeConverterTests.lattice.convert(reading: reading).best
            let second = LatticeConverterTests.lattice.convert(reading: reading).best
            #expect(first == second, "\(reading) の変換が決定的でない")
        }
    }

    @Test("辞書外の読みも空でない結果を返す（ラティスは常に連結）")
    func unknownReadingStillConverts() {
        let r = LatticeConverterTests.lattice.convert(reading: "ぬるぬるぽ")
        #expect(!r.best.isEmpty)
    }

    @Test("空の読みは空の結果を返す")
    func emptyReadingReturnsEmpty() {
        let r = LatticeConverterTests.lattice.convert(reading: "")
        #expect(r.best.isEmpty)
        #expect(r.segments.isEmpty)
    }

    @Test("変換は 1 回あたり既存 IME の予算（10ms）を十分下回る")
    func conversionIsFast() {
        // 性能は絶対の完了条件。ウォーム後、長め（27 文字）の文を多数回変換して
        // 1 回あたりの所要時間が IME の打鍵予算を大きく下回ることを確認する。
        let bench = "わたしはきょうがっこうにいってにほんごをべんきょうした"
        let iterations = 1000
        // ウォームアップ。
        for _ in 0..<50 { _ = LatticeConverterTests.lattice.convert(reading: bench) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            _ = LatticeConverterTests.lattice.convert(reading: bench)
        }
        let perMs = Double(DispatchTime.now().uptimeNanoseconds - start)
            / Double(iterations) / 1_000_000.0
        #expect(perMs < 10.0, "変換が遅すぎる: \(perMs) ms/回")
    }
}
