# Koto アーキテクチャ

Koto は macOS の入力メソッド（InputMethodKit）として動作し、ローマ字・英語・日本語の混在テキストを Apple Foundation Models（Apple Intelligence のオンデバイスモデル）で自然な日本語に変換する。Ctrl + Shift + 言語キーによる英語・中国語（簡体字）・韓国語・フランス語・ドイツ語・スペイン語への翻訳変換も、同じ状態機械と検証機構で行う（ADR-0009）。正本の要求仕様は Issue 1（https://github.com/susumutomita/koto-input/issues/1）とその詳細設計コメント、および `docs/specs/` の承認済み仕様書。

## レイヤー構成

```text
┌───────────────────────────────────────────────────────────────┐
│ クライアントアプリケーション                                       │
│ Terminal / Ghostty / iTerm2 / VS Code → Claude Code / Codex   │
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
│  - ConversionTarget: 変換先言語と言語キー解決                     │
│  - RomajiKanaConverter: 決定論ローマ字かな変換 (ADR-0006)        │
│  - PromptBuilder / ConversionOutputValidator                  │
│  - SettingsRepository / TextConversionProvider (protocol)     │
└───────────────────────────────┬───────────────────────────────┘
                                │ ConversionRequest (target / attempt 付き)
┌───────────────────────────────▼───────────────────────────────┐
│ AppleFoundationModelsProvider                                 │
│  - SystemLanguageModel の availability 確認                    │
│  - LanguageModelSession によるオンデバイス変換（使い捨て）          │
│  - target 別 prepared box（prewarm は日本語のみ）                │
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
- 変換要求は `ConversionTarget` を持つ。`Shift + Space` は日本語、`Ctrl + Shift + 言語キー`（E/C/K/F/G/S）は翻訳ターゲットを指定する（ADR-0009）。言語キーはキーコードではなく文字で判定し、composition が無いときは消費しない。
- 再変換（ADR-0008、ADR-0015）: converted / failed から編集せずに再要求されると、原文スナップショットから変換し直す。同じ target / 文脈有無なら attempt + 1 の再抽選（温度付き）、別の組なら attempt 0 で変換し直す。Escape の復元先は常に原文。
- 候補巡回（ADR-0012）: 検証を通過した変換結果は同一スナップショットの候補として蓄積され、converted 中の ↑/↓ で marked text 内を巡回選択できる（日本語と各言語の候補が共存）。候補はスナップショットを壊す編集・commit・cancel・restoreSource でクリアされる。候補ウィンドウ（IMKCandidates）は実機検証の不確実性とターミナル相性から見送った。
- タイプ先行（ADR-0005）: 変換中でも、スナップショットが先頭に残る末尾追記は変換を継続する。結果はスナップショット部分だけに splice され、追記分は保持される。スナップショットを壊す編集は従来どおりキャンセルする。
- Tab は `RomajiKanaConverter` によるその場ひらがな化（AI 不要・即時、ADR-0006）。編集として扱われ、変換中なら既存のタイプ先行ルールに従う。保護語は AI 経路と同じ規則で除外される（ADR-0007）。
- Escape の解釈は状態に依存する。変換中・変換後・失敗時は `restoreSource`（元テキスト復元）、素の入力中は `cancel`（composition 破棄）。タイプ先行の追記がある場合はテキストを保持して変換だけを中止する。
- 入力ソース切替やフォーカス移動（`deactivate`）では、表示中テキストが空でなければ commit、空なら cancel する。タイプ済みテキストを消失させない。

## 変換の並行性

レイテンシ設計の知見（prewarm・タイプ先行・最小プロンプト等がなぜ速さに効くのか）は [docs/performance.md](./performance.md) を参照。

- `CompositionCoordinator` は @MainActor。変換タスクは常に 1 本で、新しい要求・commit・cancel・deactivate、およびスナップショットを壊す編集が走ると既存タスクを cancel する。
- provider の cancellation はベストエフォート。stale 判定（上記 3 条件 + prefix 一致）は cancellation が成功しても必ず行う。
- モデル呼び出しはキーイベントの同期ハンドリング中には行わない。`converting` 状態を描画してから非同期タスクで実行する。
- composition 開始（idle → composing）時に provider を prewarm し、変換要求時のレイテンシを下げる（ADR-0005）。prewarm は日本語のみで、翻訳セッションは要求時にその場で作る（ADR-0009）。セッションは全 target で使い捨てのまま（ADR-0002）。
- 再変換の attempt は provider のサンプリングを切り替える。attempt 0 は greedy（決定的）、attempt 1 以降は温度 0.8 の抽選（ADR-0008）。validator が拒否した出力は coordinator が同一リクエスト内で最大 2 回まで自動再試行し、成功・失敗のどちらでも最後に試した attempt を状態へ反映する（ADR-0015）。

## プロンプトと出力検証

- プロンプトは `[ROLE]` `[REQUIREMENTS]` `[EXAMPLE]` `[STYLE]` `[PROTECTED_TERMS]` を instructions に、`[INPUT]` をユーザープロンプトに分けて構築する（`PromptBuilder`）。入力テキストは「変換対象のコンテンツ」であり指示ではない、と instructions 側で明示する。
- instructions は `ConversionTarget` ごとに分けて構築する（ADR-0009）。日本語は整文と文体設定（`style` / `customInstruction`）を含む変換 instructions、翻訳は忠実な訳・保護語/識別子の verbatim 維持・忠実な few-shot 1 例で構成する。few-shot に言い換えの例を入れない（小型モデルが意味置換を学習するため。Issue 22）。文体設定とカスタム指示は翻訳には適用しない。翻訳のトーンは `OutputProfile`（neutral / polite / business / casual / technical）を `[STYLE]` へ写像する（ADR-0010）。用途別の `OutputPreset`（standard / chat / email / codeReview / agentPrompt）はプロファイルと抑制系の追加指示の明示的な束で、`appAwarePresetsEnabled` による opt-in のときだけ実効になる（ADR-0011）。
- アラビア語はキー割当の無い表現可能ターゲット（ADR-0010）。実行時にモデルが対象言語へ対応しない場合は `modelUnavailable` で fail-safe（原文保持）する。翻訳品質はゴールデン一致ではなく品質フィクスチャ（`KotoInput/Tests/KotoCoreTests/Fixtures/`、Issue 36）の機械検証契約（保護語の残存・無断の断定の不在）で評価する。
- [INPUT] は `RomajiKanaConverter` で決定論的にかな正規化してから渡す（ADR-0006）。モデルの仕事はかな漢字変換・翻訳と整文に絞られ、ローマ字解釈の揺れが構造的に消える。かな正規化は全 target 共通で、同じ変換器を Tab キー（その場ひらがな化）でも使う。保護語は語境界照合で正規化から除外する（ADR-0007）。
- プロンプトはセキュリティ境界ではないため、出力は `ConversionOutputValidator` で決定論的に検証する。
  - 全 target 共通: 空・空白のみの出力は失敗。出力長が「元テキストの UTF-16 長 × 膨張率（既定 4 倍）+ 固定許容量 64」を超えたら失敗。元テキストに含まれる保護語（protected term）と頭字語（長さ 2 以上の大文字連続）が出力から消えたり表記が崩れたりしたら失敗。生成後の機械的な置換はしない。
  - 日本語のみ: 元テキストに無い末尾句点の strip と、出力全体を包む鉤括弧の unwrap を決定論で行う（小型モデルの出力癖への安全側の正規化）。翻訳では訳文の句読点・括弧を訳の一部として保持する。
  - 失敗時は必ず元テキストを保持する。破壊的な自動修復はしない。検証失敗だけは上限付きで自動再試行し、キャンセルや編集で確実に停止する（ADR-0015）。

## プライバシー

- ユーザーテキストを外部サービスへ送信しない（オンデバイスモデルのみ。ADR-0002 参照）。
- 入力テキスト・変換結果をログに残さない。診断ログはリクエスト ID・所要時間・状態遷移・エラー種別のみ。
- アナリティクスなし。

## ビルドと検証

- macOS: `make ime-build` で `.app` バンドルを組み立て、`make ime-install` で `~/Library/Input Methods` に配置する。
- テスト: `swift test --package-path KotoInput`。`KotoCore` は Foundation のみに依存するため、FoundationModels の無い環境（古い Xcode / Linux toolchain）でもコンパイル・テストできる（`#if canImport(FoundationModels)` による縮退）。
- CI: ubuntu ジョブ（bun の lint / harness）に加え、macOS ジョブで `swift build` / `swift test` を実行する。
