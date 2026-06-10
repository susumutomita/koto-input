import Foundation
import KotoCore
import Testing

@Suite("UserDefaultsSettingsRepository の永続化")
struct SettingsRepositoryTests {
    @Test("保存していなければデフォルト設定を返す")
    func returnsDefaultsWhenEmpty() throws {
        let suite = "koto-tests-\(UUID().uuidString)"
        let repository = try #require(UserDefaultsSettingsRepository(suiteName: suite))
        #expect(repository.load() == .default)
    }

    @Test("保存した設定を読み戻し、リセットでデフォルトへ戻る")
    func roundtripAndReset() throws {
        let suite = "koto-tests-\(UUID().uuidString)"
        let repository = try #require(UserDefaultsSettingsRepository(suiteName: suite))
        var settings = ConversionSettings.default
        settings.style = .polite
        settings.customInstruction = "簡潔に。"
        settings.protectedTerms = ["Koto"]
        settings.maximumExpansionRatio = 2.5

        repository.save(settings)
        #expect(repository.load() == settings)

        repository.resetToDefaults()
        #expect(repository.load() == .default)
    }

    @Test("壊れた JSON が保存されていてもデフォルトへフォールバックする")
    func corruptedPayloadFallsBack() throws {
        let suite = "koto-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("{ broken json", forKey: UserDefaultsSettingsRepository.settingsKey)
        let repository = try #require(UserDefaultsSettingsRepository(suiteName: suite))
        #expect(repository.load() == .default)
    }
}
