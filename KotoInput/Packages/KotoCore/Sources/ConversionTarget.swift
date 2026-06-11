/// 変換先の言語。Shift + Space は .japanese、Ctrl + Shift + 言語キーは
/// 翻訳ターゲットへの変換を要求する（E = 英語、C = 中国語（簡体字）、
/// K = 韓国語、F = フランス語、G = ドイツ語、S = スペイン語）。
/// アラビア語はキー割当の無い表現可能ターゲットで、設定経由でのみ使う
/// （ADR-0010）。
public enum ConversionTarget: String, CaseIterable, Sendable, Equatable {
    case japanese
    case english
    case chineseSimplified
    case korean
    case french
    case german
    case spanish
    case arabic

    /// プロンプトでモデルに指示する英語の言語名。
    public var languageName: String {
        switch self {
        case .japanese:
            return "Japanese"
        case .english:
            return "English"
        case .chineseSimplified:
            return "Simplified Chinese"
        case .korean:
            return "Korean"
        case .french:
            return "French"
        case .german:
            return "German"
        case .spanish:
            return "Spanish"
        case .arabic:
            return "Arabic"
        }
    }

    /// BCP 47 のロケール識別子。品質フィクスチャの targetLanguage や、
    /// 実行時の利用可否判定（provider 側）との突き合わせに使う。
    public var localeIdentifier: String {
        switch self {
        case .japanese:
            return "ja"
        case .english:
            return "en"
        case .chineseSimplified:
            return "zh-Hans"
        case .korean:
            return "ko"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .spanish:
            return "es"
        case .arabic:
            return "ar"
        }
    }

    /// 設定 UI・候補ラベル用の日本語表示名。
    public var displayName: String {
        switch self {
        case .japanese:
            return "日本語"
        case .english:
            return "英語"
        case .chineseSimplified:
            return "中国語（簡体字）"
        case .korean:
            return "韓国語"
        case .french:
            return "フランス語"
        case .german:
            return "ドイツ語"
        case .spanish:
            return "スペイン語"
        case .arabic:
            return "アラビア語"
        }
    }

    /// 右から左へ書く言語かどうか。候補表示のレイアウト判断に使う。
    public var isRightToLeft: Bool {
        self == .arabic
    }

    /// Ctrl + Shift + 言語キーの文字からターゲットを解決する純関数。
    /// キーコードではなく文字で判定し、キーボードレイアウト差を吸収する。
    /// Shift 併用で大文字が届くため大文字・小文字の両方を受け付ける。
    /// 日本語変換は Shift + Space が担うため、言語キーからは解決しない。
    /// アラビア語にはキーを割り当てない（ADR-0010）。
    public init?(languageKey: Character) {
        switch languageKey.lowercased() {
        case "e":
            self = .english
        case "c":
            self = .chineseSimplified
        case "k":
            self = .korean
        case "f":
            self = .french
        case "g":
            self = .german
        case "s":
            self = .spanish
        default:
            return nil
        }
    }
}
