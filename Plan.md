# Plan.md

### Koto MVP: オンデバイス AI 入力メソッド - 2026-06-09

#### 目的

Issue 1（https://github.com/susumutomita/koto-input/issues/1）の MVP を実装する。ローマ字・英語・日本語の混在テキストを、macOS 組み込みのオンデバイスモデル（Apple Intelligence / FoundationModels framework）で自然な日本語に変換する macOS 入力メソッド「Koto」を作る。変換はターゲットアプリ（Claude Code / Codex CLI 等のターミナル）の手前、つまり入力メソッドの composition バッファ内で行う。

#### 制約

- 変換は Apple Foundation Models（オンデバイス）のみ。Ollama / OpenAI 等の外部 API は使わない。ユーザーテキストを外部に送信しない。
- `KotoCore` は InputMethodKit / AppKit / FoundationModels を import しない（決定論的にテスト可能に保つ）。
- 本開発環境は Linux コンテナで Swift toolchain を導入できない（swift.org がネットワークポリシーで遮断）。コンパイルとテスト実行の検証は GitHub Actions の macOS ランナーで行い、CI green を完了条件とする（`ONE_PASS_CI`）。
- ターミナル実機での手動互換性検証（Issue の Scope 5）は物理 Mac が必要なためフォローアップとして記録し、チェックリストを `docs/terminal-compatibility.md` に用意する。
- 既存の bun ワークスペース `packages/`（小文字）と大文字小文字を区別しない APFS 上で衝突しないよう、Swift パッケージは `KotoInput/` ディレクトリ配下に置く。

#### タスク

- [x] Plan.md 作成
- [x] ドキュメント先行更新: `docs/architecture.md`（Koto 構成）、`docs/terminal-compatibility.md`（検証マトリクス）、ADR 0002（Apple Foundation Models 採用）、ADR 0003（SwiftPM 構成と Linux 縮退ビルド）、ADR 0004（Swift テストの ScriptedConversionProvider）
- [x] KotoCore: ドメインモデル（CompositionState / Phase / Command / KotoError / ConversionRequest / ConversionResult / TextSelection）
- [x] KotoCore: UTF-16 ベースの編集ヘルパー（絵文字・結合文字・サロゲートペア対応）
- [x] KotoCore: 純粋関数の状態遷移（CompositionTransition.reduce）
- [x] KotoCore: CompositionCoordinator（@MainActor、タスク管理、stale 結果排除）
- [x] KotoCore: PromptBuilder（ROLE / REQUIREMENTS / STYLE / PROTECTED_TERMS / INPUT のセクション構成）
- [x] KotoCore: ConversionOutputValidator（空応答・膨張率・保護語の検証）
- [x] KotoCore: ConversionSettings + SettingsRepository（UserDefaults 実装 + デフォルトへのリセット）
- [x] AppleFoundationModelsProvider: availability 確認・変換・キャンセル・エラーマッピング（`#if canImport(FoundationModels)` で縮退）
- [x] KotoInputMethod: IMKInputController / AppDelegate / main / Info.plist / キーボードルーティング
- [x] テスト: 状態遷移全網羅、stale 拒否、PromptBuilder、保護語、Coordinator 非同期シナリオ 5 種 + キャンセル統合テスト
- [x] scripts/build-koto-app.sh（.app バンドル組み立てとインストール）+ Makefile ターゲット
- [x] CI: macOS ランナーで `swift build` / `swift test` を実行するジョブ追加
- [x] README 書き換え（インストール・必要環境・キー操作・プライバシー・既知の制限）
- [x] フォローアップ記録（ターミナル実機検証、generation オプション調整、通知 UX、アイコン）
- [x] ゲート実行（architecture-harness / before-commit）→ コミット → push → draft PR
- [ ] CI green まで監視・修正

#### 検証手順

1. `bun scripts/architecture-harness.ts --staged --fail-on=error` がエラー 0。
2. `make before-commit`（harness + textlint + biome）が green。
3. GitHub Actions の `swift` ジョブ（macOS ランナー）で `swift build --package-path KotoInput` と `swift test --package-path KotoInput` が green。
4. 実機（macOS 26 + Apple Silicon + Apple Intelligence 有効）での一気通貫確認は `docs/terminal-compatibility.md` のチェックリストに従う（フォローアップ）。

#### 進捗ログ

- 2026-06-09: Issue 1 と詳細設計コメントを読み込み。Linux コンテナに Swift toolchain が導入不可（swift.org 403 host_not_allowed）と確認。CI macOS ランナー検証方針を決定。Plan.md 作成。
- 2026-06-09: ドキュメント・ADR 3 本・KotoCore（reducer + coordinator + validator + prompt builder + settings）・provider・IMK アプリ・テスト 8 ファイル・ビルドスクリプト・CI swift ジョブ・README を実装。`make before-commit` green（textlint の「既定→デフォルト」指摘を 1 件修正）。フォローアップ 7 件を記録。コミットして push、draft PR（https://github.com/susumutomita/koto-input/pull/2）を作成。
- 2026-06-09: CI 1 回目。macos-26 ランナーで `swift build` 成功（全ターゲットがコンパイル）。テストは 66 件中 65 件成功、1 件失敗。`trimLineEndings` が末尾 CRLF を除去できていなかった（Swift では `"\r\n"` が 1 書記素のため `== "\n"` 比較にマッチしない）。`Character.isNewline` 判定へ修正して再 push。
- 2026-06-09: CI 2 回目 green（`ci` / `swift` 両ジョブ、66 テスト全成功）。/review（16 候補 → 確定 3 件: render の選択範囲クランプ、insert/replaceSelection の case 結合、conversionFailed 構築の重複排除）と /security-review（検出なし）を実施し、修正を反映して再 push。

#### 振り返り

- 問題: 初回 CI でテスト 1 件失敗（末尾 CRLF の trim 漏れ）。
- 根本原因: Swift の String は CRLF を 1 つの Character として扱う仕様を、ローカルで Swift を実行できない環境での静的読解で取りこぼした。
- 予防策: 文字単位の比較では `isNewline` / `isWhitespace` などの分類プロパティを既定とする。push 単位で CI の swift ジョブを回す検証ループを維持し、将来的に devcontainer へ Swift toolchain を導入する（フォローアップ記録済み）。

### フォローアップ一括処理（リポジトリ chore） - 2026-06-10

#### 目的

PR 2（マージ済み）で記録したフォローアップのうち、この環境で対応できるリポジトリ chore を別 PR で処理する。

#### 制約

- 開発ブランチは `claude/friendly-bell-51toy1` のみ（マージ済み main を取り込んで継続使用）。
- `.claude/settings.json` の hook 修正（F-179415533）は、ハーネス自己修正のガードにより自動編集が拒否されたため、本 PR には含めない。修正案（PostToolUse の bash 構文 `[[ ]]` を POSIX の `case` へ置換）は dash で検証済みであり、ユーザーの明示的な承認後に適用する。

#### タスク

- [x] actions/checkout の SHA ピンを v5.0.1（Node 24 対応）へ更新（F-019445087）
- [x] package.json の name を koto-input へ変更（F-251286027）
- [x] ゲート実行 → コミット → push → draft PR → CI green 確認
- [x] テンプレート残骸の削除（ユーザー指示）: 空の `packages/` と `contracts/`、未使用の `.huskyrc.json`（husky v4 形式）/ `.lintstagedrc.json`（呼び出し元なし）/ `.oxfmtrc.jsonc`（参照ゼロ）/ `docs/follow-ups.md`（参照ゼロ）、scaffold 用スキル `init-project` / `frontend-design`
- [x] package.json をワークスペース前提から開発ツール専用へ（workspaces / dev / build / test / typecheck / clean / lint-staged / rimraf を削除）。Makefile も同期し、`make build` / `make test` を Swift へ委譲
- [x] セキュリティ: `bun audit` の 28 件（high 13）を 0 件に解消。lint-staged / rimraf 削除で依存チェーンを削減し、textlint の推移的依存（@modelcontextprotocol/sdk / cross-spawn / js-yaml / fast-uri / path-to-regexp / ajv / lodash / minimatch / brace-expansion / qs / flatted）は package.json の overrides で修正版へ固定。`diff` は 4.x（prh 用 4.0.4）と 5.x（fixer-formatter 用 5.2.2）が併存するため lock のエントリを修正版へ更新。frozen-lockfile の整合を検証済み
- [x] ドキュメント同期: CLAUDE.md / AGENTS.md / README をワークスペース前提から Swift 実態へ更新

#### 検証手順

1. `make before-commit` が green。
2. push 後の CI（ubuntu / macos-26 の両ジョブ）が checkout v5.0.1 で green。

#### 進捗ログ

- 2026-06-10: PR 2 マージ・Issue 1 クローズを確認。`git ls-remote` で actions/checkout v5.0.1 の SHA を取得し ci.yml を更新。package.json の name を変更。settings.json の hook 修正は自己修正ガードで拒否されたためフォローアップのまま維持。
- 2026-06-10: draft PR（https://github.com/susumutomita/koto-input/pull/3）を作成。CI 全チェック（ci / swift / CodeQL / GitGuardian）green を確認。

#### 振り返り

- 問題: `.claude/settings.json` の hook 修正が自動編集ガードで適用できなかった。
- 根本原因: ハーネス設定の自己修正は明示的なユーザー承認が必要という安全装置によるもの（妥当な制約）。
- 予防策: ハーネス設定の変更はユーザーへ修正案を提示して承認を得てから適用する運用にする。修正案は dash で検証済みのまま F-179415533 に保持。
