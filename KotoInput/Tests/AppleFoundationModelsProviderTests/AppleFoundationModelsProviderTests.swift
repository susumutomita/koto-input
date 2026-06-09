import AppleFoundationModelsProvider
import Foundation
import KotoCore
import Testing

@Suite("AppleFoundationModelsProvider")
struct AppleFoundationModelsProviderTests {
    private func makeRequest(_ text: String) -> ConversionRequest {
        ConversionRequest(
            id: ConversionRequestID(),
            compositionID: CompositionID(),
            revision: 1,
            sourceText: text,
            settings: .default
        )
    }

    @Test("availability は安定した値を返す")
    func availabilityIsStable() async {
        let provider = AppleFoundationModelsProvider()
        let first = await provider.availability()
        let second = await provider.availability()
        #expect(first == second)
    }

    @Test("モデルを利用できない環境では convert が KotoError を投げる")
    func convertFailsWhenUnavailable() async throws {
        let provider = AppleFoundationModelsProvider()
        guard await provider.availability() != .available else {
            // Apple Intelligence が利用可能な実機ではこのテストの対象外。
            return
        }
        await #expect(throws: KotoError.self) {
            _ = try await provider.convert(makeRequest("kyou ha ame"))
        }
    }

    @Test("モデルが利用可能なら混在テキストを変換して空でない結果を返す")
    func convertWhenAvailable() async throws {
        let provider = AppleFoundationModelsProvider()
        guard await provider.availability() == .available else {
            // CI ランナー等、Apple Intelligence が無い環境ではスキップ。
            // 実機での一気通貫検証は docs/terminal-compatibility.md に従う。
            return
        }
        let request = makeRequest("kyou ha ame nanode kasa wo motte iku")
        let result = try await provider.convert(request)
        #expect(!result.convertedText.isEmpty)
        #expect(result.requestID == request.id)
    }
}
