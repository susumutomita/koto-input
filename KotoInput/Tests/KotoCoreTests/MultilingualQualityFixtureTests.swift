import Foundation
import KotoCore
import Testing

/// 多言語品質フィクスチャの 1 ケース（Issue 36、ADR-0010 の契約）。
/// ゴールデン一致は要求せず、acceptableOutputs は人間評価の参考、
/// mustPreserve / mustNotAdd / rejectedOutputs を機械検証する。
private struct MultilingualQualityFixture: Decodable {
    let id: String
    let source: String
    /// ConversionTarget.localeIdentifier と一致する BCP 47 識別子。
    let targetLanguage: String
    /// OutputProfile の rawValue。
    let profile: String
    let acceptableOutputs: [String]
    /// validator が必ず拒否すべき出力（任意）。
    let rejectedOutputs: [String]?
    let mustPreserve: [String]
    let mustNotAdd: [String]
}

@Suite("多言語品質フィクスチャの契約検証（モデル非呼び出し）")
struct MultilingualQualityFixtureTests {
    private func loadFixtures() throws -> [MultilingualQualityFixture] {
        let url = try #require(
            Bundle.module.url(
                forResource: "multilingual-quality",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "フィクスチャ multilingual-quality.json がテストバンドルに見つかりません。"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([MultilingualQualityFixture].self, from: data)
    }

    private func resolveTarget(_ fixture: MultilingualQualityFixture) -> ConversionTarget? {
        ConversionTarget.allCases.first {
            $0.localeIdentifier == fixture.targetLanguage
        }
    }

    private func settings(for fixture: MultilingualQualityFixture) -> ConversionSettings {
        var settings = ConversionSettings.default
        settings.protectedTerms = fixture.mustPreserve
        settings.outputProfile = OutputProfile(rawValue: fixture.profile) ?? .neutral
        return settings
    }

    @Test("フィクスチャはスキーマどおり decode でき、10 件以上で id が一意")
    func fixtureDecodesWithUniqueIDs() throws {
        let fixtures = try loadFixtures()
        #expect(fixtures.count >= 10)
        let ids = fixtures.map(\.id)
        #expect(Set(ids).count == ids.count)
        for fixture in fixtures {
            #expect(!fixture.id.isEmpty, "id が空: \(fixture.id)")
            #expect(!fixture.source.isEmpty, "source が空: \(fixture.id)")
            #expect(
                !fixture.acceptableOutputs.isEmpty,
                "acceptableOutputs が空: \(fixture.id)"
            )
        }
    }

    @Test("targetLanguage は ConversionTarget の localeIdentifier に解決できる")
    func targetLanguageResolvesToConversionTarget() throws {
        let fixtures = try loadFixtures()
        for fixture in fixtures {
            #expect(
                resolveTarget(fixture) != nil,
                "未知の targetLanguage \(fixture.targetLanguage): \(fixture.id)"
            )
        }
        // 日本語・英語に加え、キー割当の無いアラビア語も 2 件以上含む
        // （ADR-0010 の決定 3）。
        let languages = fixtures.map(\.targetLanguage)
        #expect(languages.contains("ja"))
        #expect(languages.contains("en"))
        #expect(languages.filter { $0 == "ar" }.count >= 2)
    }

    @Test("profile は OutputProfile の rawValue に解決できる")
    func profileResolvesToOutputProfile() throws {
        let fixtures = try loadFixtures()
        for fixture in fixtures {
            #expect(
                OutputProfile(rawValue: fixture.profile) != nil,
                "未知の profile \(fixture.profile): \(fixture.id)"
            )
        }
    }

    @Test("mustPreserve の語は source に原文どおり含まれ、検証が必ず束縛される")
    func mustPreserveTermsAppearInSource() throws {
        let fixtures = try loadFixtures()
        for fixture in fixtures {
            for term in fixture.mustPreserve {
                #expect(
                    fixture.source.contains(term),
                    "mustPreserve「\(term)」が source に無い: \(fixture.id)"
                )
            }
        }
    }

    @Test("acceptableOutputs は mustPreserve を残し、mustNotAdd を加えない")
    func acceptableOutputsHonorPreserveAndNotAdd() throws {
        let fixtures = try loadFixtures()
        for fixture in fixtures {
            for output in fixture.acceptableOutputs {
                for term in fixture.mustPreserve {
                    #expect(
                        output.contains(term),
                        "mustPreserve「\(term)」が無い: \(fixture.id)"
                    )
                }
                for term in fixture.mustNotAdd {
                    #expect(
                        output.range(of: term, options: .caseInsensitive) == nil,
                        "mustNotAdd「\(term)」が混入: \(fixture.id)"
                    )
                }
            }
        }
    }

    @Test("acceptableOutputs は mustPreserve を保護語にした validator を通る")
    func acceptableOutputsPassValidator() throws {
        let fixtures = try loadFixtures()
        for fixture in fixtures {
            let target = try #require(resolveTarget(fixture))
            for output in fixture.acceptableOutputs {
                let result = ConversionOutputValidator.validate(
                    output: output,
                    source: fixture.source,
                    settings: settings(for: fixture),
                    target: target
                )
                guard case .success = result else {
                    Issue.record("validator が受理しなかった: \(fixture.id)")
                    return
                }
            }
        }
    }

    @Test("rejectedOutputs は validator が必ず拒否する")
    func rejectedOutputsFailValidator() throws {
        let fixtures = try loadFixtures()
        // 保護語消失の拒否ケースがフィクスチャに最低 1 件は存在する。
        let withRejections = fixtures.filter { !($0.rejectedOutputs ?? []).isEmpty }
        #expect(!withRejections.isEmpty)
        for fixture in withRejections {
            let target = try #require(resolveTarget(fixture))
            for output in fixture.rejectedOutputs ?? [] {
                let result = ConversionOutputValidator.validate(
                    output: output,
                    source: fixture.source,
                    settings: settings(for: fixture),
                    target: target
                )
                guard case .failure = result else {
                    Issue.record("validator が拒否しなかった: \(fixture.id)")
                    return
                }
            }
        }
    }
}
