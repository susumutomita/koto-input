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
    /// セッション内文脈メモリ（ADR-0013）。既定はプロセス共有の `.shared` で、
    /// 全アプリの commit テキストが合流する。テストは個別インスタンスを注入する。
    private let contextStore: SessionContextStore
    private let renderer: @MainActor (CompositionViewState) -> Void

    public init(
        provider: any TextConversionProvider,
        settingsRepository: any SettingsRepository,
        contextStore: SessionContextStore = .shared,
        renderer: @escaping @MainActor (CompositionViewState) -> Void
    ) {
        self.provider = provider
        self.settingsRepository = settingsRepository
        self.contextStore = contextStore
        self.renderer = renderer
        self.state = .idle()
    }

    public func handle(_ command: CompositionCommand) {
        let wasIdle = state.phase == .idle
        let outcome = CompositionTransition.reduce(
            state,
            command,
            protectedTerms: protectedTerms(for: command)
        )
        state = outcome.state
        switch outcome.effect {
        case .none:
            break
        case .cancelConversion:
            cancelConversionTask()
        case .startConversion(
            let requestID, let compositionID, let revision, let sourceText, let target,
            let useContext, let attempt
        ):
            cancelConversionTask()
            startConversion(
                requestID: requestID,
                compositionID: compositionID,
                revision: revision,
                sourceText: sourceText,
                target: target,
                useContext: useContext,
                attempt: attempt
            )
        }
        if wasIdle, state.phase == .composing {
            // composition 開始時にモデルを温めて、変換要求時のレイテンシを下げる。
            prewarmProvider()
        }
        renderer(outcome.view)
        if outcome.view.shouldCommit, let committed = outcome.view.committedText {
            // Enter commit と deactivate 由来の commit の両方が収集対象
            // （ADR-0013）。描画後に遅延タスクで行い、hot path には入れない。
            recordCommittedText(committed)
        }
    }

    /// normalizeToKana だけが設定の保護語を参照する。キーストローク毎の
    /// 設定ロードを避けるため、他のコマンドでは空配列を渡す。
    private func protectedTerms(for command: CompositionCommand) -> [String] {
        guard case .normalizeToKana = command else { return [] }
        return settingsRepository.load().sanitizedProtectedTerms
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

    /// commit テキストのセッション内文脈メモリへの追記。同期キーハンドリングの
    /// 外（Task）で行い、store・設定ロードを hot path から外す（ADR-0013）。
    /// 設定の確認もタスク内で行い、OFF の観測時は store 側の入口（append）が
    /// 保持分を全消去する（ON→OFF 切替後の最初の確定・変換要求で確実に
    /// 消えるようにする）。deactivate 由来の commit 直後に coordinator が
    /// 解放されても追記を取りこぼさないよう、self ではなく store と
    /// repository を直接捕捉する（store はプロセス共有の .shared であり、
    /// coordinator より長生きする）。
    private func recordCommittedText(_ text: String) {
        let settingsRepository = self.settingsRepository
        let contextStore = self.contextStore
        Task { @MainActor in
            contextStore.append(
                text,
                enabled: settingsRepository.load().contextMemoryEnabled
            )
        }
    }

    /// モデル呼び出しはキーイベントの同期ハンドリング中には行わない。
    /// converting 状態を描画してから非同期タスクで実行する。
    /// 設定ロード（JSON decode）と文脈の読み出しもタスク内で行い、同期
    /// キーハンドリングから外す。MainActor のジョブは投入順に実行されるため、
    /// 直前の commit の遅延追記（recordCommittedText の Task）が必ず先に
    /// 走り、「commit 直後の文脈つき変換にその commit が含まれる」ことが
    /// 決定論的に成立する。
    private func startConversion(
        requestID: ConversionRequestID,
        compositionID: CompositionID,
        revision: UInt64,
        sourceText: String,
        target: ConversionTarget,
        useContext: Bool,
        attempt: Int
    ) {
        let provider = self.provider
        let settingsRepository = self.settingsRepository
        let contextStore = self.contextStore
        conversionTask = Task { [weak self] in
            // 設定はタスク開始時点の不変スナップショットを使う。文脈の読み出しは
            // 変換要求のたびに行い、設定 OFF の観測時は store 側の入口
            // （snapshot）が保持分を全消去する（追記側 append と対）。
            // 注入するのは文脈つき変換（useContext）のときだけ。
            let settings = settingsRepository.load()
            let entries = contextStore.snapshot(enabled: settings.contextMemoryEnabled)
            let request = ConversionRequest(
                id: requestID,
                compositionID: compositionID,
                revision: revision,
                sourceText: sourceText,
                settings: settings,
                target: target,
                attempt: attempt,
                contextEntries: useContext ? entries : []
            )
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
                settings: request.settings,
                target: request.target
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
