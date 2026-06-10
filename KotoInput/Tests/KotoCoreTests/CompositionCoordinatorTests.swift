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

        coordinator.handle(.insert("kyou ha ame."))
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

    @Test("スナップショットを壊す編集後に届いた古い結果は無視される")
    func staleResultAfterEditIsIgnored() async throws {
        let provider = ScriptedConversionProvider()
        await provider.setHonorsCancellation(false)
        let (coordinator, recorder) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }

        // スナップショットの先頭一致を壊す編集（先頭への挿入）で composing へ戻る。
        coordinator.handle(.moveCursor(offset: -4))
        coordinator.handle(.insert("x"))
        #expect(coordinator.state.phase == .composing)

        // その後に古い結果が遅れて届いても、新しい入力を上書きしない。
        await provider.resolveOldest(with: "今日")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(coordinator.state.phase == .composing)
        #expect(coordinator.state.displayedText == "xkyou")
        #expect(recorder.views.allSatisfy { $0.markedText != "今日" })
    }

    @Test("タイプ先行: 変換中の末尾追記は継続し、結果がスナップショット部分に splice される")
    func typeAheadSplicesResult() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }

        // 変換中に次のテキストを打ち続ける。
        coordinator.handle(.insert(" ashita"))
        if case .converting = coordinator.state.phase {
            // 変換は継続している。
        } else {
            Issue.record("末尾追記で変換がキャンセルされた: \(coordinator.state.phase)")
        }

        await provider.resolveOldest(with: "今日")
        try await eventually { coordinator.state.displayedText == "今日 ashita" }
        #expect(coordinator.state.phase == .composing)
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

    @Test("頭字語の表記が崩れた出力は拒否され元テキストを保持する")
    func lostAcronymKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        // 実機で観測したフロー: SWIFThaiigengodesu → モデルが
        // 「Swiftは、英語です」と表記崩れ + 意味置換した出力を返す。
        coordinator.handle(.insert("SWIFThaiigengodesu"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(await provider.receivedModelInputTexts == ["SWIFTはいいげんごです"])
        await provider.resolveOldest(with: "Swiftは、英語です")
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "SWIFThaiigengodesu")
    }

    @Test("スナップショットを壊す編集が provider のキャンセルとして観測される")
    func editCancellationReachesProvider() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }

        // 末尾削除はスナップショットの先頭一致を壊すためキャンセルされる。
        coordinator.handle(.deleteBackward)
        try await eventually { (await provider.cancellationCount) == 1 }
        try await eventually { (await provider.pendingCount) == 0 }
        #expect(coordinator.state.phase == .composing)
        #expect(coordinator.state.displayedText == "kyo")
    }

    @Test("composition 開始時に provider が prewarm される")
    func prewarmOnCompositionStart() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("k"))
        try await eventually { (await provider.prewarmCount) == 1 }

        // composing 中の追加入力では再 prewarm しない。
        coordinator.handle(.insert("yo"))
        for _ in 0..<500 { await Task.yield() }
        #expect(await provider.prewarmCount == 1)

        // commit で idle に戻った後、次の composition 開始で再び prewarm する。
        coordinator.handle(.commit)
        coordinator.handle(.insert("a"))
        try await eventually { (await provider.prewarmCount) == 2 }
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

    @Test("Tab 即時かな化でも設定の保護語が原文のまま残る")
    func normalizeToKanaUsesSettingsProtectedTerms() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.protectedTerms = ["bun"]
        let (coordinator, _) = makeCoordinator(provider: provider, settings: settings)

        coordinator.handle(.insert("bun wo tukau"))
        coordinator.handle(.normalizeToKana)
        #expect(coordinator.state.displayedText == "bun を つかう")
    }

    @Test("モデルへ渡る modelInputText はかな化済みで、表示と Escape 復元は元テキストのまま")
    func conversionRequestCarriesKanaizedModelInputText() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyouhaiihida"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }

        // モデルへはかな化済みテキストが渡り、表示はローマ字のまま。
        #expect(await provider.receivedModelInputTexts == ["きょうはいいひだ"])
        #expect(coordinator.state.displayedText == "kyouhaiihida")

        await provider.resolveOldest(with: "今日はいい日だ")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }

        // Escape 復元の対象は元のローマ字テキスト。
        coordinator.handle(.restoreSource)
        #expect(coordinator.state.displayedText == "kyouhaiihida")
    }

    @Test("保護語に一致する語はかな化されずにモデルへ渡る")
    func protectedTermSkipsKanaization() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.protectedTerms = ["make"]
        let (coordinator, _) = makeCoordinator(provider: provider, settings: settings)

        coordinator.handle(.insert("make wo tukau"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(await provider.receivedModelInputTexts == ["make を つかう"])

        await provider.resolveOldest(with: "make を使う")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "make を使う")
    }

    @Test("語境界なしで出現する保護語の喪失も元テキスト基準で検出する")
    func lostProtectedTermWithoutWordBoundaryKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.protectedTerms = ["bun"]
        let (coordinator, _) = makeCoordinator(provider: provider, settings: settings)

        // かな化後の modelInputText（ぶんをかくにん する）には「bun」が
        // 現れないが、検証は元テキスト基準なので保護語の喪失を検出できる。
        coordinator.handle(.insert("bunwokakunin suru"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "文を確認する")
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "bunwokakunin suru")
    }

    @Test("かな化後にだけ現れる保護語の部分一致では正当な変換を拒否しない")
    func kanaOverlapWithProtectedTermDoesNotRejectConversion() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.protectedTerms = ["こと"]
        let (coordinator, _) = makeCoordinator(provider: provider, settings: settings)

        // かな化後の modelInputText（そのことば を きく）に「こと」が部分一致
        // しても、元テキストに保護語が無いため正当な変換は受理される。
        coordinator.handle(.insert("sonokotoba wo kiku"))
        coordinator.handle(.requestConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "その言葉を聞く")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "その言葉を聞く")
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
