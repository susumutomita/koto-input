import Foundation
import KotoCore
import Testing

/// テストから挙動を制御できる provider（ADR-0004）。
/// 並行性・状態遷移（stale 拒否・キャンセル・描画順序）の検証専用で、
/// 変換品質のテストには使わない。
actor ScriptedConversionProvider: TextConversionProvider {
    private struct PendingRequest {
        let request: ConversionRequest
        let continuation: CheckedContinuation<String, any Error>
    }

    private var availabilityResult: ProviderAvailability = .available
    private var honorsCancellation = true
    private var pending: [PendingRequest] = []
    private(set) var cancellationCount = 0
    private(set) var prewarmCount = 0
    /// 受け取った変換要求の modelInputText（モデルへ渡るかな化済み入力）。
    /// かな化がリクエスト経路を通っていることの観測に使う。
    private(set) var receivedModelInputTexts: [String] = []

    func prewarm(settings: ConversionSettings) async {
        prewarmCount += 1
    }

    func setAvailability(_ value: ProviderAvailability) {
        availabilityResult = value
    }

    /// false にするとキャンセルされても結果を返せる状態を保ち、
    /// stale 結果の排除（reducer 側の照合）を検証できる。
    func setHonorsCancellation(_ value: Bool) {
        honorsCancellation = value
    }

    var pendingCount: Int { pending.count }

    func availability() async -> ProviderAvailability {
        availabilityResult
    }

    func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        receivedModelInputTexts.append(request.modelInputText)
        let text: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(
                    PendingRequest(request: request, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.handleCancellation() }
        }
        return ConversionResult(
            requestID: request.id,
            compositionID: request.compositionID,
            revision: request.revision,
            convertedText: text
        )
    }

    private func handleCancellation() {
        cancellationCount += 1
        guard honorsCancellation, !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume(throwing: CancellationError())
    }

    /// 最も古い待機中リクエストへ結果を返す。
    func resolveOldest(with text: String) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume(returning: text)
    }

    func failOldest(with error: KotoError) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume(throwing: error)
    }
}

/// renderer へ渡された CompositionViewState を記録する。
@MainActor
final class RenderRecorder {
    private(set) var views: [CompositionViewState] = []

    func record(_ view: CompositionViewState) {
        views.append(view)
    }

    var last: CompositionViewState? { views.last }
}

/// 常に固定の設定スナップショットを返すリポジトリ。
struct FixedSettingsRepository: SettingsRepository {
    let settings: ConversionSettings

    func load() -> ConversionSettings { settings }
    func save(_ settings: ConversionSettings) {}
    func resetToDefaults() {}
}

@MainActor
func makeCoordinator(
    provider: ScriptedConversionProvider,
    settings: ConversionSettings = .default
) -> (CompositionCoordinator, RenderRecorder) {
    let recorder = RenderRecorder()
    let coordinator = CompositionCoordinator(
        provider: provider,
        settingsRepository: FixedSettingsRepository(settings: settings),
        renderer: { recorder.record($0) }
    )
    return (coordinator, recorder)
}

/// 条件が真になるまで協調的に待つ。無限ループは反復上限で防ぐ。
func eventually(
    _ comment: Comment? = nil,
    until condition: @MainActor () async -> Bool
) async throws {
    var iterations = 0
    while !(await condition()) {
        iterations += 1
        try #require(
            iterations < 200_000,
            comment ?? "条件が満たされないままタイムアウトしました。"
        )
        await Task.yield()
    }
}
