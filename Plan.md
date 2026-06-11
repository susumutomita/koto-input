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

### 変換の安定化（greedy sampling + few-shot） - 2026-06-10

#### 目的

実機検証で「変換が安定しない」とのフィードバックを受け、変換の決定性と小型モデルの指示追従を改善する（F-200357262 の前倒し）。

#### タスク

- [x] AppleFoundationModelsProvider: `GenerationOptions(sampling: .greedy)` を指定し、同じ入力には同じ出力を返す
- [x] PromptBuilder: REQUIREMENTS に「出力は日本語」を明記し、[EXAMPLE] セクション（few-shot 1 例）を追加
- [x] PromptBuilder のテストを更新
- [ ] ゲート → push → PR → CI green

#### 検証手順

1. CI の swift ジョブ green。
2. 実機で同じローマ字入力に対する変換結果が毎回一致すること（ユーザー確認）。

#### 進捗ログ

- 2026-06-10: 実機フィードバック「変換が安定しない」を受け、greedy sampling と few-shot を実装。

#### 振り返り

- 問題: デフォルトの温度付きサンプリングのまま出荷し、変換結果が毎回揺れた。
- 根本原因: GenerationOptions の API 表記をローカルで確認できず、コンパイル安全性を優先して指定を見送っていた（フォローアップ化していたが、ユーザー影響を過小評価した）。
- 予防策: 出力の決定性が要件になる機能（変換・整形等）では、サンプリング設定を MVP の必須項目として扱う。

### 変換の工夫の取り込み（Issue 5） - 2026-06-10

#### 目的

Issue 5（https://github.com/susumutomita/koto-input/issues/5 ）。lazyjp-vscode の変換の工夫を Koto に移植する。プロンプト規則強化・変換中のタイプ先行（prefix-splice）・prewarm によるレイテンシ改善。

#### 制約

- 変換は引き続き Apple Foundation Models（オンデバイス）のみ。
- stale 結果の三重照合は維持し、prefix 一致を第 4 の防御として追加する。
- 会話継続（transcript チェーン）は採用しない（ADR-0005）。

#### タスク

- [x] PromptBuilder: `[]`→`「」`、Markdown 行頭マーカー保持、typo 推測修正、自然な漢字使いの規則を追加
- [x] reducer: タイプ先行（末尾追記で変換継続、結果の prefix-splice、prefix 破壊でキャンセル、Escape の追記保持分岐）
- [x] TextConversionProvider に prewarm を追加（デフォルト no-op）、Coordinator が idle→composing で発火
- [x] AppleFoundationModelsProvider を actor 化し、prepared session + prewarm を実装
- [x] テスト: reducer 新遷移 6 件、coordinator のタイプ先行 splice / prefix 破壊キャンセル / prewarm、プロンプト新規則
- [x] ADR-0005 / architecture.md 更新
- [ ] ゲート → コミット → push → PR → CI green

#### 検証手順

1. CI の swift ジョブ green（新テスト含む）。
2. 実機: 変換中に続きを打っても入力が止まらず、結果が先頭部分にだけ適用されること。

#### 進捗ログ

- 2026-06-10: lazyjp-vscode のソースを読み、工夫を特定（プロンプト規則・pending 行追跡による背景変換・会話モードは作者自身がデフォルト OFF）。Issue 5 起票、実装一式を作成。

### 決定論ローマ字→ひらがな変換（Issue 13） - 2026-06-10

#### 目的

Issue 13（https://github.com/susumutomita/koto-input/issues/13 ）。Boiling Egg 方式の決定論かな変換を取り込み、LLM の仕事を「かな漢字変換 + 整文」に絞って精度を上げる。

#### 制約

- Egg の its/hira.el（GPL）は規則の参考のみ。コードは Swift で独自実装（MIT 維持、ADR-0006）。
- 変換対象は「小文字のみ・ローマ字として完全解釈できる単語」に限定（英単語・固有名詞・パスを破壊しない）。

#### タスク

- [x] RomajiKanaConverter（変換表・促音・撥音の文脈判定・小書き・長音・単語境界の安全規則）
- [x] 撥音の n 分割規則（onna→おんな、konnyaku→こんにゃく、nn 単独→ん）
- [x] reducer に normalizeToKana コマンド追加（編集として扱い、変換中は prefix 変化でキャンセル）
- [x] InputController: Tab キー（composition 中のみ消費）
- [x] PromptBuilder.prompt の前段かな正規化 + few-shot 例をかな化後の形へ更新
- [x] テスト: 変換規則 12 ケース + reducer 2 件 + プロンプト 2 件
- [x] ADR-0006 / README キー表 / architecture.md 更新
- [ ] ゲート → コミット → push → PR → CI green

#### 検証手順

1. CI の swift ジョブ green。
2. 実機: composition 中の Tab で即時ひらがな化、Shift+Space の変換品質向上（ローマ字解釈の揺れ消滅）。

#### 進捗ログ

- 2026-06-10: its/hira.el の規則を確認し独自実装。撥音の nn 分割（2 つ目の n が次音節の頭になるケース）のバグをテスト設計段階で検出して修正。

### converter 補強と Homebrew 配布整備（Issue 15 の取り込み + Issue 11） - 2026-06-10

#### 目的

ローカルセッションのハンドオフ（Issue 15）に記載されたバグ群のうち、本実装に該当するものを取り込み、Issue 11 の Homebrew 配布を整備する。ローカルブランチ feature/romaji-kana-layer は未 push のため、バグは記述から独自に再現・修正した。

#### タスク

- [x] RomajiKanaConverter: 音節区切りアポストロフィの対称処理（zen'in / zenn'in → ぜんいん）、語頭 ' の拒否
- [x] RomajiKanaConverter: 保護語のかな化除外（normalize(_:protecting:)）。validator の保護語検証との層間不整合（小文字保護語がかな化され検証が偽陽性で落ちる）を解消
- [x] PromptBuilder.prompt に settings を渡し、保護語を原文のまま [INPUT] へ
- [x] テスト: zenn'in 対称・nnn・語末 n'・保護語除外・小文字保護語のプロンプト保持
- [x] release.yml: tag push で Koto.app をビルドし Releases へ zip + sha256 を添付。署名（Developer ID）と公証（notarytool）は secrets 設定時のみ実行
- [x] build-koto-app.sh: KOTO_CODESIGN_IDENTITY による hardened runtime 署名対応
- [x] Casks/koto.rb（tap 整備までは `brew install --cask ./Casks/koto.rb` で導入可能）
- [x] README に配布手順を追記
- [ ] ゲート → コミット → push → PR → CI green

#### 検証手順

1. CI の swift ジョブ green（新テスト含む）。
2. 署名 secrets 設定後に tag push し、Releases の zip から `brew install --cask` できること（オーナー作業）。

#### 進捗ログ

- 2026-06-10: feature/romaji-kana-layer が未 push のため、Issue 15 記載のバグ記述から該当分（アポストロフィ対称性・保護語の層間不整合）を独自修正。・゠/々〆 の passthrough は本実装では非 ASCII 素通しのため該当なし。release workflow / cask / 署名対応を追加。

### Issue ゼロ化: 仕様書・E2E シナリオの整備とクローズ - 2026-06-10

#### 目的

open Issue（6〜11、15）をゼロにする。ローカルセッションの /feature フロー Issue 群（6〜10、15）は、main の実装（PR 14・16）が機能要件を満たしているため、不足している成果物（仕様書・E2E シナリオ・instructions 文言）を補って完了させる。

#### タスク

- [x] docs/specs/2026-06-10-ローマ字かな変換層.md（要件・受け入れ基準と実装テストの対応・UI/UX 決定・テスト計画・設計差分の記録）
- [x] docs/terminal-compatibility.md にかな正規化の E2E シナリオを追加
- [x] PromptBuilder の REQUIREMENTS を「ひらがな・ローマ字・英語・日本語混在」前提へ更新（Issue 9）
- [x] Issue 10 の実測ケース kyouhaiihida → きょうはいいひだ をテストで固定
- [ ] ゲート → コミット → push → PR → CI green → マージ
- [ ] Issue 6/7/8/9/10/15 をクローズ（実装との対応をコメント）。Issue 11 は配布基盤完了としてクローズ（初回リリースはオーナーの鍵設定後）。

#### 進捗ログ

- 2026-06-10: feature/romaji-kana-layer は未 push のまま。main の実装を正として成果物ギャップを補完。

### ローマ字かな変換層の堅牢化（ローカル実装の合流） - 2026-06-10

#### 目的

ローカルセッションで /feature フローにより実装したローマ字かな変換層（仕様書: `docs/specs/2026-06-10-ローマ字かな変換層.md`、Issue 6〜10・15）と、クラウドセッションが先行マージした ADR-0006 実装（PR 14・16）を合流させる。クラウド実装を基盤とし、ローカルのコードレビュー（7 観点 finder + 実証検証）で確認されたバグ修正・テスト・ドキュメントを移植する。

#### 制約

- クラウド実装（文脈規則・Tab 即時変換・prewarm・actor provider）が正。逆移植による機能退行をしない。
- 移植対象は実機コンパイルで再現確認できたバグに限る。

#### タスク

- [x] ローカル実装を feature/romaji-kana-layer にスナップショット退避（c2fd8c1）
- [x] クラウド実装との意味レベル照合（/tmp で両実装をコンパイルし挙動差を実証）
- [x] 保護語の語境界照合（substring 一致が `tabun`+`bun` → 「たbun」と語を破壊する問題の修正）
- [x] 保護語 sanitize の一元化（`ConversionSettings.sanitizeProtectedTerms`。前後空白付き保護語が黙って消える問題の修正）
- [x] Tab 即時変換への保護語注入（reduce の環境引数方式。AI 経路との分裂解消）
- [x] アポストロフィの撥音区切り限定（`goin'` 破壊の修正。`kon'` → こん は原文維持へ仕様変更）
- [x] 語末句読点 `.` `,` → 。、（`hai,soudesu.` が全体原文のまま残る問題の修正。識別子規則は不変）
- [x] `dhu` → でゅ の表追加
- [x] `ConversionRequest.modelInputText`（computed）導入と `PromptBuilder.prompt(modelInput:)` 化、scripted provider での観測
- [x] 保護語安全網のコーディネータテスト 2 本（喪失検出・ひらがな保護語の偽陽性なし）
- [x] ドキュメント: 仕様書 5 点の復元 + 合流補記、ADR-0007、README 既知の制限、biome.json の `.build` ignore（ユーザー承認済み）
- [ ] ゲート → コミット → push → PR → CI green → マージ（ユーザー承認済み）

#### 検証手順

1. `swift test --package-path KotoInput` 全件 pass（移植後 111 件）。
2. `bun scripts/architecture-harness.ts --staged --fail-on=error` → `make before-commit` green。
3. CI（ci / swift）green。
4. 実機: kyouhaiihida → Shift + Space → 「今日はいい日だ」相当、Tab → きょうはいいひだ。

#### 進捗ログ

- 2026-06-10: ローカルで仕様承認 → 5 役割並列実装 → コードレビューでバグ 5 群を実証修正（99 テスト）。ユーザー指示で区切り、ハンドオフ Issue 15 を作成。
- 2026-06-10: クラウドが PR 14・16 をマージ済みと判明。両実装を実機コンパイルで照合し、クラウド側に残る実害バグ（保護語の語破壊・sanitize 分裂・Tab 経路の保護語欠落・`'` 無条件読み飛ばし・語末句読点の未変換・`dhu` 欠落）を特定して移植。テスト 94 → 111 件、harness Error 0。
- 2026-06-10: /security-review（ローカル実装に対し指摘 0 件）、/simplify（modelInputText の computed 化・サニタイズ一元化等を適用）はローカル実装で実施済み。移植はその確定結果を反映。Homebrew フォローアップ（01KTQXP0BFHCYY32PGKFD2XW4Z）は PR 16 で解消済みとして resolve。

#### 振り返り

- 問題: ローカルとクラウドで同一機能が並行実装され、照合と移植の手戻りが発生した。
- 根本原因: ローカルの長時間セッション中に origin の進行を確認せず、ハンドオフ Issue 15 の作成とクラウド側の着手が前後した。
- 予防策: 長いローカルセッションでは着手前と PR 直前に `git fetch` で origin/main の進行を確認する。ハンドオフ Issue には「ローカルに未 push の実装がある」ことを冒頭に明記し、クラウド側はまず push を待つ運用にする。

### 実機フィードバック対応（Issue 19）と PR 18 の合流 - 2026-06-10

#### 目的

Issue 19（https://github.com/susumutomita/koto-input/issues/19 ）。実機で観測された「勝手な鉤括弧・再変換不可・誤変換から戻しにくい」を解消する。作業中に main へマージされた PR 18（ローカルセッションの堅牢化）を取り込み統合した。

#### タスク

- [x] ConversionOutputValidator: 元テキストに括弧（「『[）が無い場合のみ、出力全体を包む 「」/『』 を決定論的に unwrap
- [x] PromptBuilder: 「入力に無い引用符・括弧で出力を包まない」規則を追加
- [x] 再変換 = 候補の再抽選: converted から編集なしの再要求は原文スナップショットから attempt 付きで変換し直す。provider は attempt 0 を greedy、1 以降を温度 0.8 で抽選（ADR-0007）
- [x] 再変換中・再変換後も Escape で原文へ復元可能（sourceText 保持）。編集で attempt リセット
- [x] PR 18 の取り込み: 仕様書はローカル版を採用、kon' 原文維持・語末句読点変換の新仕様にテストを整合（ローカル側が更新済み）、modelInputText/attempt/unwrap の共存を確認
- [ ] ゲート → push → CI green → マージ → Issue クローズ

#### 検証手順

1. CI の swift ジョブ green。
2. 実機: 鉤括弧が付かない、Shift+Space 連打で候補が変わる、Escape で原文へ戻る。

#### 進捗ログ

- 2026-06-10: Issue 19 実装中に PR 18 の main マージを検出。マージコンフリクト（Plan.md・仕様書）を解決し、意味的整合（attempt × modelInputText × protectedTerms 注入）を確認して統合。

### 実機フィードバック対応（Issue 21）: 頭字語連結ローマ字と文末句点 - 2026-06-10

#### 目的

Issue 21（https://github.com/susumutomita/koto-input/issues/21 ）。実機で観測された「`SWIFThaiigengodesu` が変換できない」「入力に無い文末の 。 が付く」を解消し、ChatGPT 相当の体験へ近づける（決定論層で小型モデルの弱点を補う方針）。

#### 制約

- かな化の安全規則（識別子・パス・保護語の原文維持）を壊さない。`KotoInput` / `deCode` / `HTMLParser` は不変であること。
- 出力の機械的な修復は「入力に痕跡が無い付加物の除去」に限る（破壊的な自動修復はしない）。

#### タスク

- [x] RomajiKanaConverter.convertMixedCaseWord: 長さ 2 以上の大文字連続（頭字語）を含む語を大文字/小文字セグメントに分割し、5 文字以上かつ完全解釈できる小文字セグメントだけかな化（`SWIFThaiigengodesu` → `SWIFTはいいげんごです`）
- [x] 語末句読点の 。、 変換を「最終セグメントがかな化された場合」に限定（lastConverted）
- [x] ConversionOutputValidator.stripSpuriousTrailingPeriod: 元テキストが文末句読点で終わらない場合に限り、出力末尾の 。／． を除去（文中の句読点は不変）
- [x] PromptBuilder: few-shot 例の Output から末尾の 。 を除去（Input と整合）、REQUIREMENTS に文末句読点の付加禁止規則を追加
- [x] テスト: 頭字語連結の変換・識別子不変・末尾句点の除去/保持・括弧 unwrap 後の句点除去。既存テストは「元テキストが . で終わる」形に整合
- [ ] ゲート → push → CI green → PR 20 を拡張（タイトル・本文更新）→ マージ → Issue 21 クローズ

#### 検証手順

1. CI の swift ジョブ green（ローカルに Swift toolchain なし）。
2. 実機: `SWIFThaiigengodesu` → Shift + Space → 「SWIFTはいい言語です」相当（末尾 。 なし）。`nihongodesu` 等で勝手な 。 が付かない。

#### 進捗ログ

- 2026-06-10: 原因特定（大文字含み語の丸ごと素通し / few-shot Output の末尾 。）。converter・validator・prompt の 3 層で修正し、テストを追加。

### 実機フィードバック対応（Issue 22）: 同義語置換と頭字語の表記崩れ - 2026-06-10

#### 目的

Issue 22（https://github.com/susumutomita/koto-input/issues/22 ）。実機で観測された「げんごです → 日本語です」「SWIFThaiigengodesu → Swiftは、英語です」（同義語置換・入力に無い 、 の挿入・頭字語の表記崩れ）を解消する。

#### 制約

- 根本原因は few-shot 例自体が言い換え（あぶない → 危険です、authentication → 認証設計、だから → なので）を教えていたこと。例とルールの修正を第一手とし、決定論層（validator）は安全網として追加する。
- 仕様（docs/specs/2026-06-10-ローマ字かな変換層.md）どおり英語の語は崩さない方針に揃える。

#### タスク

- [x] PromptBuilder: few-shot 例 1 を忠実な変換へ修正（同じ単語の漢字化のみ。英語の語は原文維持、句読点の付加なし）
- [x] PromptBuilder: 実機の失敗ケースに対応する例 2 を追加（SWIFTはいいげんごです → SWIFTはいい言語です）
- [x] PromptBuilder: REQUIREMENTS に「単語を別の単語・同義語へ置き換えない」「入力に無い句読点を挿入しない」「英語の語は変更しない」を追加
- [x] ConversionOutputValidator: 元テキスト中の頭字語（長さ 2 以上の大文字連続）が出力から消えたら拒否する uppercaseRuns 検査を追加（保護語と同じ層）
- [x] テスト: few-shot の忠実性・例 2・新規則、頭字語の消失検出/保持受理、coordinator E2E（SWIFThaiigengodesu → 表記崩れ出力の拒否と原文保持）
- [ ] ゲート → push → PR → CI green → マージ → Issue 22 クローズ

#### 検証手順

1. CI の swift ジョブ green。
2. 実機: `gengodesu` → Shift + Space → 「言語です」。`SWIFThaiigengodesu` → 「SWIFTはいい言語です」。崩れた出力はモデルが返しても確定されず原文が残る。

#### 進捗ログ

- 2026-06-10: 実機報告 2 件（げんごです → 日本語です、SWIFThaiigengodesu → Swiftは、英語です）から few-shot の言い換え教示を root cause と特定。プロンプト・validator の 2 層で修正。

#### 振り返り

- 問題: Issue 21 で文末句点の除去はしたが、few-shot 例の本文に残っていた言い換え（同義語置換・単語付加）を見逃した。
- 根本原因: 例の Output を「自然な日本語」基準でレビューし、「入力との忠実性」基準でレビューしていなかった。
- 予防策: few-shot 例を変更するときは「Output の各語が Input のどの語に対応するか」を 1 対 1 で確認する。入力に無い語・句読点が例に含まれたら REQUIREMENTS と矛盾していないか確認する。
