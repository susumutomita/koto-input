# Koto アーキテクチャ

Koto は macOS の入力メソッド（InputMethodKit）として動作し、ローマ字・英語・日本語の混在テキストを Apple Foundation Models（Apple Intelligence のオンデバイスモデル）で自然な日本語に変換する。正本の要求仕様は Issue 1（https://github.com/susumutomita/koto-input/issues/1）とその詳細設計コメント。

## レイヤー構成

```text
┌───────────────────────────────────────────────────────────────┐
│ クライアントアプリケーション                                       │
│ Terminal / Ghostty / iTerm2 → Claude Code / Codex CLI         │
└───────────────────────────────▲───────────────────────────────┘
                                │ marked text / committed text
┌───────────────────────────────┴───────────────────────────────┐
│ KotoInputMethod (Apps/KotoInputMethod)                        │
│  - InputController: キーイベントをドメインコマンドへ翻訳            │
│  - InputClientAdapter: IMKTextInput 呼び出しを隔離               │
└───────────────────────────────┬───────────────────────────────┘
                                │ CompositionCommand / CompositionViewState
┌───────────────────────────────▼───────────────────────────────┐
│ KotoCore (Packages/KotoCore)                                  │
│  - CompositionTransition: 純粋関数の状態遷移 (reducer)           │
│  - CompositionCoordinator: @MainActor、変換タスク管理            │
│  - PromptBuilder / ConversionOutputValidator                  │
│  - SettingsRepository / TextConversionProvider (protocol)     │
└───────────────────────────────┬───────────────────────────────┘
                                │ ConversionRequest
┌───────────────────────────────▼───────────────────────────────┐
│ AppleFoundationModelsProvider                                 │
│  - SystemLanguageModel の availability 確認                    │
│  - LanguageModelSession によるオンデバイス変換                    │
│  - フレームワークエラーの KotoError への写像                       │
└───────────────────────────────────────────────────────────────┘
```

依存方向は `KotoInputMethod → KotoCore ← AppleFoundationModelsProvider`。`KotoCore` は InputMethodKit / AppKit / FoundationModels を import しない。これにより状態遷移とプロンプト構築を決定論的にテストできる。

## ディレクトリレイアウト

Swift パッケージは `KotoInput/` 配下の単一 SwiftPM パッケージ（複数ターゲット）。bun ワークスペースの `packages/`（小文字）と APFS（大文字小文字非区別）上で衝突しないため、Issue の提案構造（リポジトリ直下の `Packages/`）から 1 段ずらしている。判断の経緯は [ADR-0003](./adr/0003-swiftpm-単一パッケージ構成.md) を参照。

```text
KotoInput/
├── Package.swift
├── Apps/KotoInputMethod/        # IMK アプリ (executable target)
│   ├── Sources/
│   └── Info.plist
├── Packages/
│   ├── KotoCore/Sources/
│   └── AppleFoundationModelsProvider/Sources/
└── Tests/
    ├── KotoCoreTests/
    └── AppleFoundationModelsProviderTests/
```

## 合成（composition）状態機械

状態は `CompositionState` に集約し、遷移は純粋関数 `CompositionTransition.reduce(_:_:)` で行う。

```text
idle → composing → converting → converted → (commit) → idle
         ▲             │            │
         └─────────────┴────────────┘  編集 / restoreSource / 失敗からの復帰
```

- `revision` はユーザー編集・restore・新規変換要求のたびに増える。
- 変換結果は `compositionID` / `requestID` / `revision` の 3 つが現在状態と一致するときだけ適用する。古い結果が新しい入力を上書きすることはない。
- Escape の解釈は状態に依存する。変換中・変換後・失敗時は `restoreSource`（元テキスト復元）、素の入力中は `cancel`（composition 破棄）。
- 入力ソース切替やフォーカス移動（`deactivate`）では、表示中テキストが空でなければ commit、空なら cancel する。タイプ済みテキストを消失させない。

## 変換の並行性

- `CompositionCoordinator` は @MainActor。変換タスクは常に 1 本で、新しい要求・編集・commit・cancel・deactivate が走ると既存タスクを cancel する。
- provider の cancellation はベストエフォート。stale 判定（上記 3 条件）は cancellation が成功しても必ず行う。
- モデル呼び出しはキーイベントの同期ハンドリング中には行わない。`converting` 状態を描画してから非同期タスクで実行する。

## プロンプトと出力検証

- プロンプトは `[ROLE]` `[REQUIREMENTS]` `[STYLE]` `[PROTECTED_TERMS]` を instructions に、`[INPUT]` をユーザープロンプトに分けて構築する（`PromptBuilder`）。入力テキストは「変換対象のコンテンツ」であり指示ではない、と instructions 側で明示する。
- プロンプトはセキュリティ境界ではないため、出力は `ConversionOutputValidator` で決定論的に検証する。
  - 空・空白のみの出力は失敗。
  - 出力長が「元テキストの UTF-16 長 × 膨張率（既定 4 倍）+ 固定許容量 64」を超えたら失敗。
  - 元テキストに含まれる保護語（protected term）が出力から消えていたら失敗。生成後の機械的な置換はしない。
  - 失敗時は必ず元テキストを保持する。破壊的な自動修復はしない。

## プライバシー

- ユーザーテキストを外部サービスへ送信しない（オンデバイスモデルのみ。ADR-0002 参照）。
- 入力テキスト・変換結果をログに残さない。診断ログはリクエスト ID・所要時間・状態遷移・エラー種別のみ。
- アナリティクスなし。

## ビルドと検証

- macOS: `make ime-build` で `.app` バンドルを組み立て、`make ime-install` で `~/Library/Input Methods` に配置する。
- テスト: `swift test --package-path KotoInput`。`KotoCore` は Foundation のみに依存するため、FoundationModels の無い環境（古い Xcode / Linux toolchain）でもコンパイル・テストできる（`#if canImport(FoundationModels)` による縮退）。
- CI: ubuntu ジョブ（bun の lint / harness）に加え、macOS ジョブで `swift build` / `swift test` を実行する。
