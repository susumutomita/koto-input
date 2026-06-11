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
    /// セッション内文脈メモリの [CONTEXT] エントリ（任意、古い→新しい順。
    /// Issue 46、ADR-0013 Decision 8）。存在するケースは id 接尾辞
    /// `-with-context` を持ち、同じ題材の `-without-context` とペアで収録する。
    let context: [String]?
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

    @Test("context つきケースは非空・各 entry が store 上限以内・文脈なしケースとペアで収録される")
    func contextCasesHonorPairContract() throws {
        let fixtures = try loadFixtures()
        let ids = Set(fixtures.map(\.id))
        let withSuffix = "-with-context"
        let withoutSuffix = "-without-context"

        var withContextCount = 0
        for fixture in fixtures {
            // 契約の核: id 接尾辞 -with-context ⟺ context フィールドの存在。
            // （-without-context は -with-context を接尾辞に持たないため、
            // この同値だけで「文脈なしケースに context が無い」ことも含意する。）
            #expect(
                (fixture.context != nil) == fixture.id.hasSuffix(withSuffix),
                "id 接尾辞 \(withSuffix) と context の有無が一致しない: \(fixture.id)"
            )
            if let context = fixture.context {
                withContextCount += 1
                #expect(!context.isEmpty, "context が空配列: \(fixture.id)")
                for entry in context {
                    // 上限の正本は store の予算定数。注入され得ない長さの
                    // context をフィクスチャに持ち込ませない。
                    #expect(
                        entry.utf16.count <= SessionContextStore.maxTotalUTF16Length,
                        "context entry が上限（UTF-16 長）超: \(fixture.id)"
                    )
                    #expect(
                        !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "context entry が空白のみ: \(fixture.id)"
                    )
                }
                let pairID = String(fixture.id.dropLast(withSuffix.count)) + withoutSuffix
                #expect(ids.contains(pairID), "文脈なしペア \(pairID) が無い: \(fixture.id)")
            } else if fixture.id.hasSuffix(withoutSuffix) {
                let pairID = String(fixture.id.dropLast(withoutSuffix.count)) + withSuffix
                #expect(ids.contains(pairID), "文脈ありペア \(pairID) が無い: \(fixture.id)")
            }
        }
        // 文脈あり / なしのペアが 2 組以上収録されている（仕様の評価方針）。
        #expect(withContextCount >= 2)
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
