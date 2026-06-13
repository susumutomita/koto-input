#if canImport(AppKit) && canImport(InputMethodKit)
import AppKit
import AppleFoundationModelsProvider
import InputMethodKit
import KotoCore

/// InputMethodKit からのイベントをドメインコマンドへ翻訳する薄いアダプタ。
/// モデル呼び出し・プロンプト構築・状態遷移のロジックは持たない（KotoCore 側）。
/// IMK のコールバックはメインスレッドで届くため、MainActor.assumeIsolated で
/// @MainActor な CompositionCoordinator へ橋渡しする。
@objc(KotoInputController)
final class InputController: IMKInputController {
    private var coordinator: CompositionCoordinator?
    /// coordinator 生成と Ctrl + Shift + Space の設定判定で共用する
    /// リポジトリ。UserDefaults を初期化できない場合は永続化しない
    /// リポジトリへ縮退する。
    private lazy var settingsRepository: any SettingsRepository =
        UserDefaultsSettingsRepository() ?? EphemeralSettingsRepository()

    private enum KeyCode {
        static let enter: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let backspace: UInt16 = 51
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return MainActor.assumeIsolated {
            process(event)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        // 入力ソース切替やフォーカス移動で stale な marked text を残さない。
        // 表示テキストが空でなければ commit、空なら cancel（KotoCore 側の
        // deactivation ポリシー）。
        MainActor.assumeIsolated {
            coordinator?.handle(.deactivate)
        }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            coordinator?.handle(.commit)
        }
    }

    // MARK: - Key routing

    @MainActor
    private func process(_ event: NSEvent) -> Bool {
        let coordinator = activeCoordinator()
        let composing = coordinator.state.hasActiveComposition
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 矢印キー等は .function / .numericPad が立ち、Caps Lock 点灯中は
        // .capsLock が全イベントに立つため、判定からは除外する（残すと
        // Caps Lock 中に Shift + Space 等の全変換キーが不一致になる）。
        let essentialFlags = flags.subtracting([.function, .numericPad, .capsLock])

        switch event.keyCode {
        case KeyCode.space where essentialFlags == .shift:
            // 日本語変換ショートカット。composition が無ければターミナルへ通す。
            guard composing else { return false }
            coordinator.handle(.requestConversion(.japanese))
            return true

        case KeyCode.space where essentialFlags == [.control, .shift]:
            // 文脈つき日本語変換（Issue 46、ADR-0013）。composing を先に
            // 判定し、composition の無い素通しケース（アプリ側ショートカット
            // 利用時）では設定ロード（UserDefaults 読み + JSON decode）を
            // 払わない。設定のロードはこのキー押下時のみで、毎キーストローク
            // では行わない。OFF（既定）の間はキーを消費せずアプリへ通し、
            // 従来挙動と完全に一致させる。Ctrl + Shift + 言語キーは文字で
            // 判定するため space とは衝突しない。
            guard composing else { return false }
            guard settingsRepository.load().contextMemoryEnabled else { return false }
            coordinator.handle(.requestContextualConversion)
            return true

        case KeyCode.tab:
            // 決定論ローマ字 → ひらがな変換（AI 不要・即時）。
            // composition が無ければターミナルの補完を奪わない。
            guard composing, essentialFlags.isEmpty else { return false }
            coordinator.handle(.normalizeToKana)
            return true

        case KeyCode.escape:
            guard composing, essentialFlags.isEmpty else { return false }
            // 変換中・変換後・失敗時は元テキストの復元、素の入力中は破棄。
            coordinator.handle(
                coordinator.state.canRestoreSource ? .restoreSource : .cancel
            )
            return true

        case KeyCode.enter, KeyCode.keypadEnter:
            guard composing else { return false }
            if essentialFlags == .control {
                // Control + Enter: composition 内に改行を挿入する。
                coordinator.handle(.insert("\n"))
                return true
            }
            guard essentialFlags.isEmpty else { return false }
            // commit のみ行い、2 つ目の Enter を合成しない。プロンプト送信は
            // ユーザーが次に押す Enter が担う。
            coordinator.handle(.commit)
            return true

        case KeyCode.backspace:
            guard composing, essentialFlags.isEmpty else { return false }
            coordinator.handle(.deleteBackward)
            return true

        case KeyCode.leftArrow:
            guard composing, essentialFlags.isEmpty else { return false }
            coordinator.handle(.moveCursor(offset: -1))
            return true

        case KeyCode.rightArrow:
            guard composing, essentialFlags.isEmpty else { return false }
            coordinator.handle(.moveCursor(offset: 1))
            return true

        case KeyCode.upArrow:
            // converted で候補が 2 件以上のときだけ消費する。それ以外は
            // アプリ（ターミナルの履歴操作等）へ通す。
            guard composing, essentialFlags.isEmpty,
                coordinator.state.canCycleCandidates
            else { return false }
            coordinator.handle(.selectCandidate(offset: -1))
            return true

        case KeyCode.downArrow:
            guard composing, essentialFlags.isEmpty,
                coordinator.state.canCycleCandidates
            else { return false }
            coordinator.handle(.selectCandidate(offset: 1))
            return true

        default:
            break
        }

        // Control + Shift + 言語キー: composition をターゲット言語へ AI 変換
        // する（E = 英語、C = 中国語、K = 韓国語、F = フランス語、G = ドイツ語、
        // S = スペイン語）。キーコードではなく文字で判定し、キーボード
        // レイアウト差を吸収する。composition が無ければ消費せずアプリへ通す
        // （ターミナルのショートカットを奪わない）。
        if essentialFlags == [.control, .shift],
            let characters = event.charactersIgnoringModifiers,
            characters.count == 1,
            let languageKey = characters.first,
            let target = ConversionTarget(languageKey: languageKey)
        {
            guard composing else { return false }
            coordinator.handle(.requestConversion(target))
            return true
        }

        // Control + C: 変換タスクと composition を破棄した上で、ターミナルの
        // 割り込みとして通す。
        if essentialFlags.contains(.control),
            event.charactersIgnoringModifiers == "c"
        {
            if composing {
                coordinator.handle(.cancel)
            }
            return false
        }

        // Command / Control 等の修飾キー付きショートカットは消費しない。
        guard essentialFlags.subtracting(.shift).isEmpty else { return false }

        guard let characters = event.characters, !characters.isEmpty else {
            return false
        }
        guard isPrintable(characters) else { return false }

        if !composing {
            // 空白だけで composition を始めない（ターミナルの素のスペースを
            // 奪わない）。
            let trimmed = characters.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
        }
        coordinator.handle(.insert(characters))
        return true
    }

    private func isPrintable(_ characters: String) -> Bool {
        characters.unicodeScalars.allSatisfy { scalar in
            // 制御文字と、ファンクションキー由来の Private Use Area
            // (F700-F8FF) を除外する。
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    // MARK: - Coordinator / rendering

    @MainActor
    private func activeCoordinator() -> CompositionCoordinator {
        if let coordinator {
            return coordinator
        }
        // 文脈 store はプロセス共有の .shared を渡し、全アプリ・全 coordinator
        // の commit テキストが 1 つのセッション内文脈メモリへ合流する（ADR-0013）。
        let created = CompositionCoordinator(
            provider: makeProvider(),
            settingsRepository: settingsRepository,
            contextStore: .shared,
            renderer: { [weak self] view in
                self?.render(view)
            }
        )
        coordinator = created
        return created
    }

    /// 変換プロバイダを構築する。既定はハイブリッド（辞書バックボーン + AI
    /// 再ランク、ADR-0016）。同梱辞書のロードに失敗した場合のみ、AI 単独の
    /// AppleFoundationModelsProvider へ縮退して IME を動かし続ける
    /// （辞書が無くても従来どおり AI 変換は成立する）。
    private func makeProvider() -> any TextConversionProvider {
        if let hybrid = try? HybridConversionProvider() {
            return hybrid
        }
        return AppleFoundationModelsProvider()
    }

    @MainActor
    private func render(_ view: CompositionViewState) {
        guard let client = client() else { return }
        let notFound = NSRange(location: NSNotFound, length: NSNotFound)

        if view.shouldCommit, let committed = view.committedText {
            client.insertText(committed, replacementRange: notFound)
        }

        if let marked = view.markedText {
            let underline: NSUnderlineStyle =
                view.status == .converted ? .thick : .single
            let attributed = NSAttributedString(
                string: marked,
                attributes: [.underlineStyle: underline.rawValue]
            )
            // IMK 境界での防御: 不正な範囲はクラッシュさせずクランプする。
            let clamped = UTF16TextEditing.clampedSelection(view.selection, in: marked)
            client.setMarkedText(
                attributed,
                selectionRange: NSRange(
                    location: clamped.location,
                    length: clamped.length
                ),
                replacementRange: notFound
            )
        } else {
            client.setMarkedText(
                NSAttributedString(string: ""),
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: notFound
            )
        }
    }
}
#endif
