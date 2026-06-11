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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
        try await eventually { (await provider.pendingCount) == 1 }
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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
        coordinator.handle(.requestConversion(.japanese))
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

        coordinator.handle(.requestConversion(.japanese))
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "今日")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "今日")
    }

    // MARK: - 多言語変換ターゲット

    @Test("英語変換: provider へ target とかな化済み入力が届き、Escape で元のローマ字へ戻る")
    func englishConversionLifecycle() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, recorder) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyouhaiihida"))
        coordinator.handle(.requestConversion(.english))
        #expect(recorder.last?.status == .converting)
        try await eventually { (await provider.pendingCount) == 1 }

        // provider はターゲット言語付きのリクエストを受け取り、モデル入力は
        // 日本語変換と同じ前段かな化を通る。表示はローマ字のまま。
        #expect(await provider.receivedTargets == [.english])
        #expect(await provider.receivedModelInputTexts == ["きょうはいいひだ"])
        #expect(coordinator.state.displayedText == "kyouhaiihida")

        await provider.resolveOldest(with: "Today is a good day")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "Today is a good day")
        #expect(recorder.last?.markedText == "Today is a good day")

        // Escape 復元の対象は元のローマ字テキスト。
        coordinator.handle(.restoreSource)
        #expect(coordinator.state.displayedText == "kyouhaiihida")
    }

    @Test("converted（英語）から日本語へ切り替えると attempt 0 のリクエストが provider へ届く")
    func switchingTargetSendsFreshAttempt() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion(.english))
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "Today")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }

        // 同じ target の連打は attempt + 1 の再抽選。
        coordinator.handle(.requestConversion(.english))
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "This day")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }

        // Shift + Space で日本語へ戻すと attempt 0 から変換し直す。
        coordinator.handle(.requestConversion(.japanese))
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(await provider.receivedAttempts == [0, 1, 0])
        #expect(await provider.receivedTargets == [.english, .english, .japanese])

        await provider.resolveOldest(with: "今日")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "今日")
    }

    @Test("英語変換でも保護語が消えた出力は拒否され元テキストを保持する")
    func englishConversionLostProtectedTermKeepsSource() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("Claude Code de naosu"))
        coordinator.handle(.requestConversion(.english))
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "Fix it with claude code")
        try await eventually {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "Claude Code de naosu")
    }

    @Test("英語変換では日本語固有の鉤括弧 unwrap が適用されない（target が検証へ届く）")
    func englishConversionSkipsJapaneseSpecificValidation() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion(.english))
        try await eventually { (await provider.pendingCount) == 1 }
        // 日本語ターゲットなら外側の鉤括弧は取り除かれるが、英語では
        // 訳文の一部として保持される。
        await provider.resolveOldest(with: "「Today」")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "「Today」")
    }

    // MARK: - 変換候補の巡回選択

    @Test("再抽選後の selectCandidate(-1) で 1 件目の候補表示へ戻り、commit が選択候補を確定する")
    func cycleBackToFirstCandidateAfterReroll() async throws {
        let provider = ScriptedConversionProvider()
        let (coordinator, recorder) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion(.japanese))
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "今日")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        // 候補が 1 件の間は巡回できない（上下キーはアプリへ通す）。
        #expect(!coordinator.state.canCycleCandidates)

        // 再抽選で 2 件目の候補が蓄積される。
        coordinator.handle(.requestConversion(.japanese))
        try await eventually { (await provider.pendingCount) == 1 }
        await provider.resolveOldest(with: "京")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "京")
        #expect(coordinator.state.canCycleCandidates)

        // 上矢印相当の selectCandidate(-1) で 1 件目の表示へ戻る。
        coordinator.handle(.selectCandidate(offset: -1))
        #expect(coordinator.state.displayedText == "今日")
        #expect(recorder.last?.markedText == "今日")

        // Enter は選択中の候補を確定するだけで、自動 commit は無い。
        coordinator.handle(.commit)
        #expect(coordinator.state.phase == .idle)
        #expect(recorder.last?.shouldCommit == true)
        #expect(recorder.last?.committedText == "今日")
    }

    // MARK: - セッション内文脈メモリ（Issue 46、ADR-0013）

    @Test("ON のとき commit したテキストが hot path 外で store へ追記される")
    func commitAppendsToStoreWhenEnabled() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.contextMemoryEnabled = true
        let store = SessionContextStore()
        let (coordinator, _) = makeCoordinator(
            provider: provider,
            settings: settings,
            contextStore: store
        )

        coordinator.handle(.insert("asu kaigi"))
        coordinator.handle(.commit)
        // 追記は同期キーハンドリングの外（Task）で行われるため、commit 直後の
        // 同期時点では store はまだ空（hot path 禁止の観測）。
        #expect(store.snapshot().isEmpty)
        try await eventually { store.snapshot() == ["asu kaigi"] }
    }

    @Test("deactivate 由来の commit も ON なら store へ追記される")
    func deactivateCommitAppendsToStore() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.contextMemoryEnabled = true
        let store = SessionContextStore()
        let (coordinator, _) = makeCoordinator(
            provider: provider,
            settings: settings,
            contextStore: store
        )

        coordinator.handle(.insert("kyou no shinchoku"))
        coordinator.handle(.deactivate)
        try await eventually { store.snapshot() == ["kyou no shinchoku"] }
    }

    @Test("ON の文脈つき変換で request.contextEntries が store のスナップショットと一致する")
    func contextualConversionCarriesStoreSnapshot() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.contextMemoryEnabled = true
        let store = SessionContextStore()
        store.append("Issue 46 のレビューを依頼した")
        store.append("明日の朝までに返す")
        let (coordinator, _) = makeCoordinator(
            provider: provider,
            settings: settings,
            contextStore: store
        )

        coordinator.handle(.insert("arewoyatteoite"))
        coordinator.handle(.requestContextualConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(
            await provider.receivedContextEntries
                == [["Issue 46 のレビューを依頼した", "明日の朝までに返す"]]
        )

        await provider.resolveOldest(with: "あれをやっておいて")
        try await eventually {
            if case .converted = coordinator.state.phase { return true }
            return false
        }
        #expect(coordinator.state.displayedText == "あれをやっておいて")
    }

    @Test("OFF（既定）では commit しても store へ収集されない")
    func commitDoesNotCollectWhenDisabled() async throws {
        let provider = ScriptedConversionProvider()
        let store = SessionContextStore()
        let (coordinator, _) = makeCoordinator(provider: provider, contextStore: store)

        coordinator.handle(.insert("asu kaigi"))
        coordinator.handle(.commit)
        // 遅延タスクが走り切った後も収集ゼロのまま。
        for _ in 0..<1_000 { await Task.yield() }
        #expect(store.snapshot().isEmpty)
    }

    @Test("ON で蓄積した後 OFF へ切り替えると、次の commit で全消去される")
    func turningOffClearsStoreOnNextCommit() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.contextMemoryEnabled = true
        let repository = MutableSettingsRepository(settings: settings)
        let store = SessionContextStore()
        let (coordinator, _) = makeCoordinator(
            provider: provider,
            settingsRepository: repository,
            contextStore: store
        )

        coordinator.handle(.insert("asu kaigi"))
        coordinator.handle(.commit)
        try await eventually { store.snapshot() == ["asu kaigi"] }

        // OFF へ切り替えた後の commit では、追記ではなく全消去になる。
        settings.contextMemoryEnabled = false
        repository.save(settings)
        coordinator.handle(.insert("tsugi no bun"))
        coordinator.handle(.commit)
        try await eventually { store.snapshot().isEmpty }
    }

    @Test("OFF 中の文脈つき変換は文脈を注入せず store を全消去する")
    func contextualConversionWhileDisabledClearsStore() async throws {
        let provider = ScriptedConversionProvider()
        let store = SessionContextStore()
        store.append("残っていた文脈")
        let (coordinator, _) = makeCoordinator(provider: provider, contextStore: store)

        coordinator.handle(.insert("arewoyatteoite"))
        coordinator.handle(.requestContextualConversion)
        // 読み出し側の消去は変換タスク内（hot path 外）で行われる。
        try await eventually { store.snapshot().isEmpty }
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(await provider.receivedContextEntries == [[]])
    }

    @Test("OFF 中は通常変換でも保持済み文脈が全消去される")
    func plainConversionWhileDisabledClearsStore() async throws {
        // OFF 中は Ctrl + Shift + Space が InputController で消費されないため、
        // 本番経路の消去契機は commit と変換要求。変換要求側をここで固定する
        // （README の「次のテキスト確定または AI 変換要求の時点で全消去」）。
        let provider = ScriptedConversionProvider()
        let store = SessionContextStore()
        store.append("残っていた文脈")
        let (coordinator, _) = makeCoordinator(provider: provider, contextStore: store)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion(.japanese))
        try await eventually { store.snapshot().isEmpty }
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(await provider.receivedContextEntries == [[]])
    }

    @Test("commit 直後の文脈つき変換は、その commit のテキストを文脈に含む")
    func contextualConversionImmediatelyAfterCommitSeesThatCommit() async throws {
        // 追記（recordCommittedText の Task）と読み出し（変換タスク内の
        // snapshot）はどちらも MainActor のジョブで、投入順に実行される。
        // commit → 即入力 → 即 Ctrl + Shift + Space の最速操作でも直前の
        // commit が [CONTEXT] から欠落しないことを順序の契約として固定する。
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.contextMemoryEnabled = true
        let store = SessionContextStore()
        let (coordinator, _) = makeCoordinator(
            provider: provider,
            settings: settings,
            contextStore: store
        )

        coordinator.handle(.insert("Issue 46 no review wo onegai"))
        coordinator.handle(.commit)
        coordinator.handle(.insert("arewoyatteoite"))
        coordinator.handle(.requestContextualConversion)
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(
            await provider.receivedContextEntries
                == [["Issue 46 no review wo onegai"]]
        )
    }

    @Test("通常変換（useContext false）では store に文脈があっても contextEntries は空")
    func plainConversionDoesNotCarryContext() async throws {
        let provider = ScriptedConversionProvider()
        var settings = ConversionSettings.default
        settings.contextMemoryEnabled = true
        let store = SessionContextStore()
        store.append("残っている文脈")
        let (coordinator, _) = makeCoordinator(
            provider: provider,
            settings: settings,
            contextStore: store
        )

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion(.japanese))
        try await eventually { (await provider.pendingCount) == 1 }
        #expect(await provider.receivedContextEntries == [[]])
        // 通常変換は store を消去しない（ON のままなので保持される）。
        #expect(store.snapshot() == ["残っている文脈"])
    }

    @Test("stale な結果は候補に入らない")
    func staleResultDoesNotBecomeCandidate() async throws {
        let provider = ScriptedConversionProvider()
        await provider.setHonorsCancellation(false)
        let (coordinator, _) = makeCoordinator(provider: provider)

        coordinator.handle(.insert("kyou"))
        coordinator.handle(.requestConversion(.japanese))
        try await eventually { (await provider.pendingCount) == 1 }

        // スナップショットを壊す編集で composing へ戻ってから古い結果が届く。
        coordinator.handle(.deleteBackward)
        #expect(coordinator.state.phase == .composing)
        await provider.resolveOldest(with: "今日")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(coordinator.state.candidates.isEmpty)
        #expect(coordinator.state.selectedCandidateIndex == nil)
    }
}
