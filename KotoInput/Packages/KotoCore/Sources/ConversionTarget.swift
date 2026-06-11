/// 変換先の言語。Shift + Space は .japanese、Ctrl + Shift + 言語キーは
/// 翻訳ターゲットへの変換を要求する（E = 英語、C = 中国語（簡体字）、
/// K = 韓国語、F = フランス語、G = ドイツ語、S = スペイン語）。
public enum ConversionTarget: String, CaseIterable, Sendable, Equatable {
    case japanese
    case english
    case chineseSimplified
    case korean
    case french
    case german
    case spanish

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
        }
    }

    /// Ctrl + Shift + 言語キーの文字からターゲットを解決する純関数。
    /// キーコードではなく文字で判定し、キーボードレイアウト差を吸収する。
    /// Shift 併用で大文字が届くため大文字・小文字の両方を受け付ける。
    /// 日本語変換は Shift + Space が担うため、言語キーからは解決しない。
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
