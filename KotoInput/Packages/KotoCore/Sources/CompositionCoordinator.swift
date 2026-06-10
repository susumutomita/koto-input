import Foundation

/// composition 状態と変換タスクを所有する調整役。
/// - 状態遷移は CompositionTransition.reduce（純粋関数）に委譲する。
/// - 変換タスクは常に 1 本。新しい要求・編集・commit・cancel・deactivate で
///   既存タスクをキャンセルする。
/// - provider のキャンセルはベストエフォートであり、stale 結果の排除は
///   reducer 側の compositionID / requestID / revision 照合で必ず行う。
@MainActor
public final class CompositionCoordinator {
    public private(set) var state: CompositionState
    private var conversionTask: Task<Void, Never>?

    private let provider: any TextConversionProvider
    private let settingsRepository: any SettingsRepository
    private let renderer: @MainActor (CompositionViewState) -> Void

    public init(
        provider: any TextConversionProvider,
        settingsRepository: any SettingsRepository,
        renderer: @escaping @MainActor (CompositionViewState) -> Void
    ) {
        self.provider = provider
        self.settingsRepository = settingsRepository
        self.renderer = renderer
        self.state = .idle()
    }

    public func handle(_ command: CompositionCommand) {
        let wasIdle = state.phase == .idle
        let outcome = CompositionTransition.reduce(state, command)
        state = outcome.state
        switch outcome.effect {
        case .none:
            break
        case .cancelConversion:
            cancelConversionTask()
        case .startConversion(
            let requestID, let compositionID, let revision, let sourceText, let attempt
        ):
            cancelConversionTask()
            startConversion(
                requestID: requestID,
                compositionID: compositionID,
                revision: revision,
                sourceText: sourceText,
                attempt: attempt
            )
        }
        if wasIdle, state.phase == .composing {
            // composition 開始時にモデルを温めて、変換要求時のレイテンシを下げる。
            prewarmProvider()
        }
        renderer(outcome.view)
    }

    /// fire-and-forget の prewarm。失敗してもユーザー影響はない（変換時に
    /// その場でセッションが作られるだけ）。
    private func prewarmProvider() {
        let settings = settingsRepository.load()
        let provider = self.provider
        Task.detached {
            await provider.prewarm(settings: settings)
        }
    }

    private func cancelConversionTask() {
        conversionTask?.cancel()
        conversionTask = nil
    }

    /// モデル呼び出しはキーイベントの同期ハンドリング中には行わない。
    /// converting 状態を描画してから非同期タスクで実行する。
    private func startConversion(
        requestID: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        sourceText: String,
        attempt: Int
    ) {
        // 設定はタスク開始時点の不変スナップショットを使う。
        let settings = settingsRepository.load()
        let request = ConversionRequest(
            id: requestID,
            compositionID: compositionID,
            revision: revision,
            sourceText: sourceText,
            settings: settings,
            attempt: attempt
        )
        let provider = self.provider
        conversionTask = Task { [weak self] in
            let command = await Self.performConversion(provider: provider, request: request)
            guard !Task.isCancelled, let self, let command else { return }
            self.handle(command)
        }
    }

    private nonisolated static func performConversion(
        provider: any TextConversionProvider,
        request: ConversionRequest
    ) async -> CompositionCommand? {
        func failed(_ error: KotoError) -> CompositionCommand {
            .conversionFailed(
                requestID: request.id,
                compositionID: request.compositionID,
                revision: request.revision,
                error: error
            )
        }

        switch await provider.availability() {
        case .available:
            break
        case .preparing:
            return failed(
                .modelUnavailable("モデルを準備しています。しばらくしてからもう一度お試しください。")
            )
        case .unavailable(let reason):
            return failed(.modelUnavailable(reason))
        }

        do {
            let result = try await provider.convert(request)
            switch ConversionOutputValidator.validate(
                output: result.convertedText,
                source: request.sourceText,
                settings: request.settings
            ) {
            case .success(let text):
                return .conversionSucceeded(
                    ConversionResult(
                        requestID: request.id,
                        compositionID: request.compositionID,
                        revision: request.revision,
                        convertedText: text
                    )
                )
            case .failure(let error):
                return failed(error)
            }
        } catch is CancellationError {
            return nil
        } catch let error as KotoError {
            if case .cancelled = error { return nil }
            return failed(error)
        } catch {
            return failed(.generationFailed(String(describing: error)))
        }
    }
}
