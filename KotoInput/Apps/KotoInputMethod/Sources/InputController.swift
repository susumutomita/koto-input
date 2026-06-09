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

    private enum KeyCode {
        static let enter: UInt16 = 36
        static let space: UInt16 = 49
        static let backspace: UInt16 = 51
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
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
        // 矢印キー等は .function / .numericPad が立つため、判定からは除外する。
        let essentialFlags = flags.subtracting([.function, .numericPad])

        switch event.keyCode {
        case KeyCode.space where essentialFlags == .shift:
            // 変換ショートカット。composition が無ければターミナルへ通す。
            guard composing else { return false }
            coordinator.handle(.requestConversion)
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

        default:
            break
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
        let repository: any SettingsRepository =
            UserDefaultsSettingsRepository() ?? EphemeralSettingsRepository()
        let created = CompositionCoordinator(
            provider: AppleFoundationModelsProvider(),
            settingsRepository: repository,
            renderer: { [weak self] view in
                self?.render(view)
            }
        )
        coordinator = created
        return created
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
            client.setMarkedText(
                attributed,
                selectionRange: NSRange(
                    location: view.selection.location,
                    length: view.selection.length
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
