import Foundation
import KotoCore
import Testing

@MainActor
@Suite("CompositionCoordinator の変換ライフサイクル")
struct CompositionCoordinatorTests {
    @Test("変換成功で marked text が置き換わり、commit で確定する")
    func successfulConversionAndCommit() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, recorder) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou ha ame"))
        coordinator.handle(.requestConversion)
        #expect(recorder.last?.status == .converting)

        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "今日は雨です。")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "今日は雨です。")
        #expect(recorder.last?.markedText == "今日は雨です。")

        coordinator.handle(.commit)
        #expect(coordinator.state.phase == .idle)
        #expect(recorder.last?.shouldCommit == true)
        #expect(recorder.last?.committedText == "今日は雨です。")
    }

    @Test("編集後に届いた古い結果は無視される")
    func staleResultAfterEditIsIgnored() async throws {
        let provider = ScriptedConversionProvider()
        await provider.setHonorsCancellation(false)
        let (coordinator, recorder) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }

        // 変換中の編集で composing へ戻る。
        coordinator.handle(.insert("x"))
        #expect(coordinator.state.phase == .composing)

        // その後に古い結果が遅れて届いても、新しい入力を上書きしない。
        await provider.resolveOldest(with: "今日")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(coordinator.state.phase == .composing)
        #expect(coordinator.state.displayedText == "kyoux")
        #expect(recorder.views.allSatisfy { $0.markedText != "今日" })
    }

    @Test("要求 B が要求 A を置き換えたら、後から完了した A は無視される")
    func replacedRequestResultIsIgnored() async throws {
        let provider = ScriptedConversionProvider()
        await provider.setHonorsCancellation(false)
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 2 }

        // A が先に完了しても無視される。
        await provider.resolveOldest(with: "A の結果")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(coordinator.state.displayedText == "kyou")

        // B の結果は適用される。
        await provider.resolveOldest(with: "今日")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "今日")
    }

    @Test("変換中の deactivate はタスクを取り消し、後から描画されない")
    func deactivateDuringConversion() async throws {
        let provider = ScriptedConversionProvider()
        await provider.setHonorsCancellation(false)
        let (coordinator, recorder) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }

        coordinator.handle(.deactivate)
        #expect(coordinator.state.phase == .idle)
        // 表示テキストが空でないため commit される（タイプ済みテキストの保全）。
        #expect(recorder.last?.committedText == "kyou")
        let renderCount = recorder.views.count

        await provider.resolveOldest(with: "遅延した結果")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(recorder.views.count == renderCount)
        #expect(recorder.views.allSatisfy { $0.markedText != "遅延した結果" })
    }

    @Test("provider が利用不可なら元テキストを保持して failed になる")
    func unavailableProviderKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        await provider.setAvailability(
            .unavailable(reason: "Apple Intelligence が無効です。")
        )
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "kyou")
    }

    @Test("準備中の provider でも元テキストを保持して failed になる")
    func preparingProviderKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        await provider.setAvailability(.preparing)
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "kyou")
    }

    @Test("空の出力では元テキストを保持して failed になる")
    func emptyOutputKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "\n \n")
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "kyou")
    }

    @Test("保護語が消えた出力は拒否され元テキストを保持する")
    func lostProtectedTermKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("Claude Code de naosu"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "クロードコードで直す")
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "Claude Code de naosu")
    }

    @Test("変換中の編集が provider のキャンセルとして観測される")
    func editCancellationReachesProvider() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }

        coordinator.handle(.insert("x"))
        try await eventually { (await provider.cancellationCount) == 1 }
        try await eventually { (await provider.pendingCount) == 0 }
        #expect(coordinator.state.phase == .composing)
        #expect(coordinator.state.displayedText == "kyoux")
    }

    @Test("provider が KotoError で失敗したら failed になり元テキストを保持する")
    func providerFailureKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.failOldest(with: .generationFailed("guardrail"))
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "kyou")
    }

    @Test("変換後の restoreSource で元テキストへ戻り、再変換できる")
    func restoreAndReconvert() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "今日")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }

        #expect(coordinator.state.canRestoreSource)
        coordinator.handle(.restoreSource)
        #expect(coordinator.state.phase == .composing)
        #expect(coordinator.state.displayedText == "kyou")

        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "今日")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "今日")
    }
}
