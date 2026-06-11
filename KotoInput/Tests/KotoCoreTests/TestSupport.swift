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
    /// 受け取った変換要求のターゲット言語。多言語変換キーがリクエスト経路を
    /// 通っていることの観測に使う。
    private(set) var receivedTargets: [ConversionTarget] = []
    /// 受け取った変換要求の attempt。同 target の再抽選と異 target の
    /// リセット規則の観測に使う。
    private(set) var receivedAttempts: [Int] = []
    /// 受け取った変換要求の contextEntries。文脈つき変換がリクエスト経路を
    /// 通っていること・通常変換に文脈が混入しないことの観測に使う。
    private(set) var receivedContextEntries: [[String]] = []

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
        receivedTargets.append(request.target)
        receivedAttempts.append(request.attempt)
        receivedContextEntries.append(request.contextEntries)
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

/// テスト用の設定リポジトリ。save しない限り固定のスナップショットを返し、
/// save で切り替えれば ON→OFF の即時全消去など実行中の設定変更に対する
/// coordinator の挙動も検証できる（固定用と可変用の 2 つのテストダブルを
/// 並存させない）。テストは MainActor 上からのみアクセスするため
/// @unchecked Sendable で十分。
final class MutableSettingsRepository: SettingsRepository, @unchecked Sendable {
    private var settings: ConversionSettings

    init(settings: ConversionSettings) {
        self.settings = settings
    }

    func load() -> ConversionSettings { settings }
    func save(_ settings: ConversionSettings) { self.settings = settings }
    func resetToDefaults() { settings = .default }
}

@MainActor
func makeCoordinator(
    provider: ScriptedConversionProvider,
    settings: ConversionSettings = .default,
    contextStore: SessionContextStore = SessionContextStore()
) -> (CompositionCoordinator, RenderRecorder) {
    makeCoordinator(
        provider: provider,
        settingsRepository: MutableSettingsRepository(settings: settings),
        contextStore: contextStore
    )
}

/// テストは `.shared` を使わず個別の store を注入し、テスト間の文脈混入を
/// 防ぐ（仕様書「テストは個別インスタンス」）。
@MainActor
func makeCoordinator(
    provider: ScriptedConversionProvider,
    settingsRepository: any SettingsRepository,
    contextStore: SessionContextStore = SessionContextStore()
) -> (CompositionCoordinator, RenderRecorder) {
    let recorder = RenderRecorder()
    let coordinator = CompositionCoordinator(
        provider: provider,
        settingsRepository: settingsRepository,
        contextStore: contextStore,
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
