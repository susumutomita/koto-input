import Foundation

/// 決定論的なローマ字 → ひらがな変換。
///
/// boiled-egg / Boiling Egg（Egg・Tamago）が確立した「素打ちしたローマ字を
/// 後からまとめて変換する」方式のかな化部分を担う。規則はヘボン式・訓令式の
/// 標準的な対応表（Egg の its/hira.el 等で公知のもの）を参考にした独自実装
/// （ADR-0006。GPL コードの移植ではない）。
///
/// 安全規則: 変換するのは「小文字だけで構成され、ローマ字として最後まで
/// 解釈できる単語」のみ。英単語（解釈不能）・大文字を含む単語（固有名詞）・
/// パスや識別子に隣接する単語・保護語はそのまま残す。
public enum RomajiKanaConverter {
    /// テキスト中の変換可能なローマ字単語だけをひらがなへ置き換える。
    /// `protectedTerms` は語境界で照合した出現箇所だけ原文のまま保持する
    /// （validator の保護語検証と層を揃えるため）。語の途中の部分一致
    /// （term `bun` と語 `tabun` 等）で保護すると語を破壊するため一致させない。
    public static func normalize(
        _ text: String,
        protecting protectedTerms: [String] = []
    ) -> String {
        // サニタイズは ConversionSettings に一元化した規則を使い、raw な配列を
        // 受け取っても安全にする。同位置で重なる候補は長いフレーズを優先する。
        let terms = ConversionSettings.sanitizeProtectedTerms(protectedTerms)
            .sorted { $0.count > $1.count }
            .map(Array.init)
        guard !terms.isEmpty else {
            return normalizeSegment(text)
        }
        let chars = Array(text)
        var result = ""
        var segment = ""
        var index = 0
        // テキスト先頭は語境界。
        var atTermBoundary = true
        while index < chars.count {
            if atTermBoundary,
                let length = protectedTermLength(in: chars, at: index, terms: terms)
            {
                result += normalizeSegment(segment)
                segment = ""
                result += String(chars[index..<(index + length)])
                index += length
                atTermBoundary = false
                continue
            }
            let character = chars[index]
            segment.append(character)
            atTermBoundary = isTermBoundary(character)
            index += 1
        }
        result += normalizeSegment(segment)
        return result
    }

    /// index（語境界直後）から始まり、終端が語境界（テキスト末尾・空白・
    /// 変換可能句読点）である保護語の一致長を返す。複数語フレーズ
    /// （`Claude Code` 等）も 1 つの出現として照合する。
    private static func protectedTermLength(
        in chars: [Character],
        at index: Int,
        terms: [[Character]]
    ) -> Int? {
        for term in terms {
            let end = index + term.count
            guard end <= chars.count, chars[index..<end].elementsEqual(term) else {
                continue
            }
            if end == chars.count || isTermBoundary(chars[end]) {
                return term.count
            }
        }
        return nil
    }

    /// 保護語の語境界。空白に加えて、かな化が 。、 へ変換する句読点を区切りに
    /// 含め、`sudo,` のような出現も保護できるようにする。
    private static func isTermBoundary(_ character: Character) -> Bool {
        character.isWhitespace || punctuationKana[character] != nil
    }

    /// 保護語を含まない区間の変換本体。
    private static func normalizeSegment(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var index = 0
        while index < chars.count {
            let character = chars[index]
            guard isWordCharacter(character) else {
                result.append(character)
                index += 1
                continue
            }
            var end = index
            while end < chars.count, isWordCharacter(chars[end]) {
                end += 1
            }
            let word = String(chars[index..<end])
            let previous = index > 0 ? chars[index - 1] : nil
            let next = end < chars.count ? chars[end] : nil
            let afterNext = end + 1 < chars.count ? chars[end + 1] : nil
            if isConvertibleContext(previous: previous, next: next, afterNext: afterNext),
                !word.contains(where: { $0.isUppercase }),
                let kana = convertWord(word)
            {
                result += kana
                // かなへ変換した語に隣接する語末・語間の . , は文の句読点として
                // 。、 へ変換する。パス・識別子（node.js 等）は文脈判定で語自体が
                // 変換されないため、ここへは来ない。
                if let next, let mark = punctuationKana[next] {
                    result += mark
                    index = end + 1
                    continue
                }
            } else {
                result += word
            }
            index = end
        }
        return result
    }

    /// 単語全体がローマ字として解釈できればひらがなを返す。できなければ nil。
    static func convertWord(_ word: String) -> String? {
        guard word.contains(where: { $0.isLetter }) else { return nil }
        var out = ""
        var rest = Substring(word)
        while let first = rest.first {
            // 長音。語頭の「-」は不自然なので変換対象にしない。
            if first == "-" {
                guard !out.isEmpty else { return nil }
                out += "ー"
                rest.removeFirst()
                continue
            }
            // 促音の特例: match 系の tch。t を っ にして ch を残す。
            if rest.hasPrefix("tch") {
                out += "っ"
                rest.removeFirst()
                continue
            }
            // 撥音。末尾・子音前（y を除く）の n、区切り明示の n' / nn'、nn、
            // ヘボン式の m+b/m/p。アポストロフィは n の直後かつその次が母音 / y
            // の場合だけ撥音の区切りとして消費する。それ以外の ' を含む語
            // （goin' / don't / ka'ki 等の英語）は語全体を原文維持にする。
            if first == "n" {
                let following = rest.dropFirst().first
                if following == "'" {
                    guard isVowelOrY(rest.dropFirst(2).first) else { return nil }
                    out += "ん"
                    rest.removeFirst(2)
                    continue
                }
                if following == "n" {
                    // onna → おんな、konnichiha → こんにちは のように、2 つ目の n が
                    // 次の音節（na 行・nya 行）の頭になる場合は 1 文字だけ消費する。
                    // 明示的な nn（直後が母音・y 以外）は 2 文字で ん。
                    let afterPair = rest.dropFirst(2).first
                    if let afterPair, isVowel(afterPair) || afterPair == "y" {
                        out += "ん"
                        rest.removeFirst()
                    } else if afterPair == "'" {
                        // nn' も区切り明示（zenn'in → ぜんいん）。直後に母音 / y が
                        // 無い zenn' 等は原文維持。
                        guard isVowelOrY(rest.dropFirst(3).first) else { return nil }
                        out += "ん"
                        rest.removeFirst(3)
                    } else {
                        out += "ん"
                        rest.removeFirst(2)
                    }
                    continue
                }
                if following == nil || !(isVowel(following!) || following! == "y") {
                    out += "ん"
                    rest.removeFirst()
                    continue
                }
                // n + 母音 / y はテーブル（な行・にゃ行）で処理する。
            }
            if first == "m", let following = rest.dropFirst().first,
                "bmp".contains(following)
            {
                out += "ん"
                rest.removeFirst()
                continue
            }
            // 促音: 同一子音の連続（n は撥音、m はヘボン式で処理済み）。
            if let following = rest.dropFirst().first, following == first,
                "kstchgzdbpfjvqrwyl".contains(first)
            {
                out += "っ"
                rest.removeFirst()
                continue
            }
            // テーブル最長一致（最大 4 文字）。
            var matched = false
            for length in stride(from: min(4, rest.count), through: 1, by: -1) {
                let candidate = String(rest.prefix(length))
                if let kana = syllables[candidate] {
                    out += kana
                    rest.removeFirst(length)
                    matched = true
                    break
                }
            }
            if !matched {
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - 境界判定

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character == "'" || character == "-")
    }

    private static func isVowel(_ character: Character) -> Bool {
        "aiueo".contains(character)
    }

    /// 撥音区切りの ' の直後がな行・にゃ行の頭（母音 / y）になり得るか。
    private static func isVowelOrY(_ character: Character?) -> Bool {
        guard let character else { return false }
        return isVowel(character) || character == "y"
    }

    /// 単語の前後の文字から、変換してよい文脈かを判定する。
    /// パス・拡張子・識別子（`/` `.` `_` 等に隣接）は変換しない。
    static func isConvertibleContext(
        previous: Character?,
        next: Character?,
        afterNext: Character?
    ) -> Bool {
        if let previous {
            // 読点（,）の直後は hai,soudesu の soudesu のように語頭として扱う。
            let okPrevious =
                previous.isWhitespace || !previous.isASCII
                || "([{\"'「（【『,".contains(previous)
            if !okPrevious {
                return false
            }
        }
        guard let next else { return true }
        if next.isWhitespace || !next.isASCII {
            return true
        }
        if ")]}\"'」）】』!?".contains(next) {
            return true
        }
        // 読点（,）はパス・識別子にほぼ現れないため、直後に語が続いても
        // 文の区切りとして変換を許す（hai,soudesu → はい、そうです）。
        if next == "," {
            return true
        }
        // 文末の . ; : は許可。直後にさらに文字が続く場合（拡張子・URL 等）は
        // 識別子とみなして変換しない。
        if ".;:".contains(next) {
            return afterNext == nil || afterNext!.isWhitespace || !afterNext!.isASCII
        }
        return false
    }

    // MARK: - 変換表（ヘボン式・訓令式の標準対応）

    /// かなへ変換した語に隣接する場合だけ 。、 へ変換する句読点。
    /// 保護語の語境界判定（isTermBoundary）もこの表から導出する。
    static let punctuationKana: [Character: String] = [
        ".": "。",
        ",": "、",
    ]

    static let syllables: [String: String] = [
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
        "kya": "きゃ", "kyu": "きゅ", "kye": "きぇ", "kyo": "きょ",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
        "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
        "sha": "しゃ", "shi": "し", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
        "za": "ざ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
        "ja": "じゃ", "ji": "じ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
        "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
        "ta": "た", "ti": "ち", "tu": "つ", "te": "て", "to": "と",
        "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
        "cha": "ちゃ", "chi": "ち", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
        "tsa": "つぁ", "tsi": "つぃ", "tsu": "つ", "tse": "つぇ", "tso": "つぉ",
        "thi": "てぃ", "dhi": "でぃ", "dhu": "でゅ",
        "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
        "nya": "にゃ", "nyu": "にゅ", "nye": "にぇ", "nyo": "にょ",
        "ha": "は", "hi": "ひ", "hu": "ふ", "he": "へ", "ho": "ほ",
        "hya": "ひゃ", "hyu": "ひゅ", "hye": "ひぇ", "hyo": "ひょ",
        "fa": "ふぁ", "fi": "ふぃ", "fu": "ふ", "fe": "ふぇ", "fo": "ふぉ",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
        "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
        "ya": "や", "yu": "ゆ", "ye": "いぇ", "yo": "よ",
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
        "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        "wa": "わ", "wi": "うぃ", "we": "うぇ", "wo": "を",
        "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
        "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
        "lya": "ゃ", "lyu": "ゅ", "lyo": "ょ", "ltu": "っ", "ltsu": "っ", "lwa": "ゎ",
        "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
        "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ", "xtu": "っ", "xtsu": "っ", "xwa": "ゎ",
    ]
}
