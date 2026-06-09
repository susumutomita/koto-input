import Foundation

/// 設定の永続化を KotoCore から隔離する。バッキングストアの変更が
/// KotoCore に波及しないよう protocol の背後に置く。
public protocol SettingsRepository: Sendable {
    func load() -> ConversionSettings
    func save(_ settings: ConversionSettings)
    func resetToDefaults()
}

/// UserDefaults ベースの実装。設定 JSON は手で編集できるよう文字列で保存する。
public final class UserDefaultsSettingsRepository: SettingsRepository, @unchecked Sendable {
    public static let defaultSuiteName = "com.susumutomita.inputmethod.Koto"
    public static let settingsKey = "conversionSettings"

    private let defaults: UserDefaults

    public init?(suiteName: String = UserDefaultsSettingsRepository.defaultSuiteName) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return nil
        }
        self.defaults = defaults
    }

    public func load() -> ConversionSettings {
        guard
            let json = defaults.string(forKey: Self.settingsKey),
            let data = json.data(using: .utf8),
            let settings = try? JSONDecoder().decode(ConversionSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public func save(_ settings: ConversionSettings) {
        guard
            let data = try? JSONEncoder().encode(settings),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: Self.settingsKey)
    }

    public func resetToDefaults() {
        defaults.removeObject(forKey: Self.settingsKey)
    }
}

/// 永続化を行わず常にデフォルト設定を返すリポジトリ。
/// 永続層を初期化できない場合の安全な代替として使う。
public struct EphemeralSettingsRepository: SettingsRepository {
    public init() {}

    public func load() -> ConversionSettings { .default }
    public func save(_ settings: ConversionSettings) {}
    public func resetToDefaults() {}
}
