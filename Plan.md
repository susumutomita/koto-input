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

### 多言語変換キー（Issue 24〜28） - 2026-06-11

#### 目的

Ctrl + Shift + 言語キー（E/C/K/F/G/S）で composition を英語・中国語（簡体字）・韓国語・フランス語・ドイツ語・スペイン語へ AI 変換する。仕様書 docs/specs/2026-06-11-多言語変換キー.md（承認済み）。Issue 24（https://github.com/susumutomita/koto-input/issues/24 ）〜 Issue 28。

#### 制約

- 完全オンデバイス（ADR-0002）。翻訳セッションの prewarm はしない（6 言語分の常駐回避）。
- 既存の状態機械のセマンティクス（原文スナップショット・stale 拒否・Escape 復元・type-ahead）を変えない。
- 日本語変換の instructions は一字一句変えない（既存テスト・実機品質の回帰防止）。

#### タスク

- [x] /feature フロー: ヒアリング（同時押し・6 言語フルセット・自然な訳）→ 仕様書承認 → Issue 24〜28 作成
- [x] 5 役割並列実装: PM レビュー / UI・UX 設計（キー衝突調査）/ コア実装 + キールーティング / テスト計画 / ユーザーフィードバック
- [x] ConversionTarget（languageKey 解決の純関数）、requestConversion(target)、reducer の「同 target = attempt + 1、異 target = attempt 0」、ConversionRequest.target、PromptBuilder の翻訳 instructions（忠実 few-shot）、provider の target 別 prepared box、validator の日本語固有規則の限定、InputController ルーティング
- [x] テスト 31 件追加（ConversionTarget 6、reducer 6、coordinator 4、PromptBuilder/Request 9、validator 6）
- [x] 統合: README キー一覧 + 使い分け + 衝突注意、terminal-compatibility.md に VS Code と多言語 E2E シナリオ + 既知の衝突表を追記
- [x] フォローアップ記録: F-2JBB48（変換中・失敗時の視覚フィードバック改善）
- [ ] ゲート → push → PR 29 本文更新 → CI green → マージ → Issue 24〜28 クローズ

#### 検証手順

1. CI の swift ジョブ green（ローカルに Swift toolchain なし。31 件の新テスト含む全件 pass）。
2. 実機: terminal-compatibility.md の「多言語変換キーの E2E シナリオ」（英語 + 1 言語、キー衝突確認含む）。

#### 進捗ログ

- 2026-06-11: ヒアリングで「追い打ちキーは次の文字入力と衝突するから同時押し」のユーザー判断を反映。6 言語フルセットで承認。5 エージェント並列実装が完了し、統合レビューで provider の prepared box・パラメタライズテスト・キールーティングのコンパイル整合を確認。QA/User の指摘から README・terminal-compatibility を統合時に反映。

### ドキュメント総点検（多言語変換後の設計反映） - 2026-06-11

#### 目的

多言語変換キー（PR 29）までの設計変更をドキュメント正本へ反映し、乖離と構造的な不備（ADR 番号衝突）を解消する。

#### 制約

- コード変更を伴わないドキュメント専用の作業。
- ADR の番号変更は git mv と表題の番号のみで、決定内容は不変。

#### タスク

- [x] ADR 番号衝突の解消: `0007-再変換は温度付き再抽選` を 0008 へ繰り下げ（保護語 ADR が先にマージされていたため。git mv + 表題更新のみで内容は不変）
- [x] ADR-0009 新規作成: 多言語変換はターゲット別 instructions と使い捨てセッションで実現（target 貫通・翻訳 instructions・prewarm 日本語のみ・validator の言語分岐・文字判定キー解決）
- [x] docs/architecture.md: ConversionTarget / RomajiKanaConverter をレイヤー図へ、再変換（ADR-0008）・多言語（ADR-0009）・Tab かな化（ADR-0006/0007）・[EXAMPLE] セクション・頭字語検査・日本語固有の正規化を本文へ反映
- [x] README: 冒頭と特徴に翻訳変換、英語の変換例、設定表に適用範囲（style/customInstruction は日本語のみ）、既知の制限に翻訳初回レイテンシ
- [ ] ゲート → push → PR → CI green

#### 検証手順

`make before-commit`（harness / textlint / biome）green、CI green。ADR 旧ファイル名への参照が無いことを grep で確認済み。

#### 進捗ログ

- 2026-06-11: ADR 0007 の重複は PR 17 と PR 18 が互いを見ずにマージされたことが原因（git log で確認）。歴史記録である Plan.md 過去節と 2026-06-10 仕様書の「ADR-0007」参照は当時の文脈（保護語 = 0007 は不変、再変換への参照は当時の番号）として残置。

### セマンティック多言語出力モード基盤（Issue 30〜33・36） - 2026-06-11

#### 目的

Issue 30 の設計を ADR-0010 として固定し、設定モデル（Issue 31）・多言語プロンプト（Issue 32）・多言語検証の契約固定（Issue 33）・品質フィクスチャ（Issue 36）を実装する。

#### 制約

- 日本語変換の既定動作・instructions は一字一句変えない。
- モデル呼び出し・UI 変更・アプリ検出は本 PR ではしない（Issue 34・37 は別 PR）。
- 旧 JSON 設定は既定値で decode 成功（後方互換）。クラウド・外部ランタイム禁止。

#### タスク

- [x] ADR-0010: ConversionMode 独立型を作らない判断、言語メタデータ、arabic はキー割当なし、OutputProfile、中間意味表現の見送り、フィクスチャ契約
- [x] ConversionTarget: arabic 追加・localeIdentifier・displayName・isRightToLeft
- [x] OutputProfile（5 値）+ ConversionSettings.outputProfile（decodeIfPresent + 未知値は .neutral へフォールバック）
- [x] PromptBuilder: [STYLE] のプロファイル分岐・arabic の instructions / few-shot
- [x] validator: RTL・短出力・メッセージ非混入の契約をテストで固定（本体修正は不要だった）
- [x] フィクスチャ 13 件 + Package.swift リソース + MultilingualQualityFixtureTests + 形式ドキュメント
- [x] README 設定表に outputProfile、architecture.md にプロファイル写像・arabic・フィクスチャ評価を追記
- [ ] ゲート → push → PR → CI green → Issue 30〜33・36 クローズ

#### 検証手順

CI の swift ジョブで新規テスト 29 件 + フィクスチャ検証が pass すること。`make before-commit` green。

#### 進捗ログ

- 2026-06-11: Issue 35 は 34 の完全重複としてクローズ。PR 38 の CodeRabbit 指摘は制約節欠落のみ採用（本 PR に同梱）、ADR リナンバー不変性違反の指摘は「決定内容を変えない番号衝突の機械的修正」として理由つきで見送り。

### README の公開向け整備 - 2026-06-11

#### 目的

GitHub を初見した人が「何のプロジェクトか・なぜ使うのか」を README だけで理解できるようにする（ユーザー要望）。

#### 制約

- ドキュメントのみの変更。textlint の規則（だ・である調の統一等）を守る。

#### タスク

- [x] CI バッジと英語 1 文サマリーを冒頭へ追加
- [x] 「なぜ Koto か」節（従来 IME の不便と設計方針）を追加
- [x] テンプレート由来の文言（「このテンプレートは」「本テンプレートは Bun 専用」）をリポジトリ主語へ修正
- [ ] ゲート → push → PR → About 説明とトピックの提案をユーザーへ提示（API ツールが無いため手動設定を依頼）

#### 検証手順

`make before-commit`（textlint 含む）green、CI green。

#### 進捗ログ

- 2026-06-11: リポジトリの About 説明・トピックは利用可能な GitHub ツールに更新 API が無いため、提案文をユーザーへ提示して手動設定を依頼する方針にした。

### release ワークフロー失敗の修正（v1.0.0） - 2026-06-11

#### 目的

タグ v1.0.0 の release ジョブが `scripts/build-koto-app.sh: line 55: APP_DIR�: unbound variable` で失敗した（ユーザー報告）。原因を修正してリリースを成立させる。

#### 制約

- ブランチは claude/friendly-bell-51toy1 のみのため、修正コミットは PR 40 に同乗させる（軽微な 1 行修正で、PR 本文に明記）。

#### タスク

- [x] 原因特定: `"$APP_DIR（…"` のように変数の直後に全角文字が続くと、macOS の bash が変数名の境界を誤判定し `set -u` で unbound になる。ビルド・署名は成功しており最後の echo のみで失敗
- [x] `${APP_DIR}` へ修正 + 再発防止コメント。リポジトリ全体を grep し同パターンが他に無いことを確認
- [ ] PR 40 マージ後、タグ v1.0.0 を修正後の main へ付け直して release を再実行（release は未公開のため安全）

#### 検証手順

CI green。タグ再 push 後の release ジョブが assets（Koto-v1.0.0.zip + sha256）の添付まで完走すること。

#### 進捗ログ

- 2026-06-11: ローカルで再現しなかった理由は、ローカルは `--install` 分岐（line 55 を通らない）だったため。echo は ad-hoc 署名完了後なので成果物自体は壊れていなかった。

### 候補巡回・出力プリセット・性能知見・release 手動トリガー（Issue 34・37 ほか） - 2026-06-11

#### 目的

Issue 34（候補表示）と Issue 37（出力プリセット）の実装、デモへの「AI が速い」コメントを受けた性能設計の知見化、release のタグ push 不可環境向け手動トリガー、README へのビジョン明文化をまとめて出荷する。

#### 制約

- 候補 UI は marked text 内巡回（ユーザー承認。IMKCandidates は実機検証不可のため見送り = ADR-0012）。
- プリセットはアプリ検出なしの opt-in 基盤のみ（Issue 37 の制約 = ADR-0011）。
- 単一ブランチ運用のため 1 PR に同乗（コミットで分離）。

#### タスク

- [x] Issue 34: ConversionCandidate・候補蓄積/クリア規則・selectCandidate（wrap 巡回）・↑/↓ ルーティング・ADR-0012・テスト 17 件
- [x] Issue 37: OutputPreset（5 種・製品名非依存）・appAwarePresetsEnabled・effectiveProfile 優先規則・[STYLE] への束反映・ADR-0011・テスト 22 件
- [x] docs/performance.md（レイテンシ収支と 8 つの工夫）+ README / architecture.md リンク
- [x] release.yml に workflow_dispatch（タグ入力）を追加（タグ push 不可環境からの v1.0.1 再実行用）
- [x] README: ビジョン（IME を切り替えない体験）・↑/↓ キー・プリセット設定表
- [x] かな形態巡回の仕様書 + Issue 41 作成（実装は次 PR）
- [ ] ゲート → push → PR → CI green → マージ → workflow_dispatch で v1.0.1 release → Issue 34・37 クローズ

#### 検証手順

CI の swift ジョブで新規テスト 39 件を含む全件 pass。release は workflow_dispatch 実行で assets 添付まで完走を確認。

#### 進捗ログ

- 2026-06-11: 並行 2 エージェント（Issue 34 / 37）の編集ファイルを排他に分割して衝突ゼロで統合。candidate のメタデータは reducer の純粋性維持のため text / target / attempt とし、profile は持たせない判断（ADR-0012 に記録）。Mozc 検討を F-SW4978 に記録。

### かな形態巡回（Issue 41） - 2026-06-11

#### 目的

Issue 41（https://github.com/susumutomita/koto-input/issues/41 ）。Tab 連打でひらがな ⇄ カタカナを巡回し、カタカナ語を確実に打てるようにする（実機フィードバック）。仕様書 docs/specs/2026-06-11-かな形態巡回.md（承認済み）。

#### 制約

- AI 不要・決定論・即時。Shift + Space 再抽選・↑/↓ 候補切替と衝突しない（ヒアリングで Tab 連打方式に決定）。
- InputController は変更しない（reducer の normalizeToKana の解釈のみ変更）。

#### タスク

- [x] RomajiKanaConverter: ひらがな ⇄ カタカナのコードポイントシフト（U+3041–U+3096 ⇄ U+30A1–U+30F6、長音符・記号・ASCII 不変）
- [x] KanaForm + CompositionState.kanaCycleForm、normalizeToKana の巡回分岐（applyEdit 経由で既存の編集規則を踏襲）
- [x] リセット経路の網羅: テキスト変更編集・requestConversion・conversionSucceeded（両分岐）・restoreSource（両分岐）・commit / cancel / deactivate。moveCursor は維持
- [x] テスト 14 件（converter 4 + transition 10）
- [x] README の Tab 行・terminal-compatibility.md の E2E シナリオ更新
- [ ] ゲート → push → PR → CI green → マージ → Issue 41 クローズ

#### 検証手順

CI の swift ジョブで新規テスト 14 件を含む全件 pass。実機: `katakananihenkan` → Tab ×2 → 「カタカナニヘンカン」（terminal-compatibility.md の手順 3）。

#### 進捗ログ

- 2026-06-11: 仕様の受け入れ例 `testo` は "st" がローマ字解釈不能で原文維持となるため、テストは `tesuto` で検証（仕様の「相当」の範囲内、テストコメントに理由を記載）。

### ローカル文脈メモリの設計 ADR（Issue 43） - 2026-06-11

#### 目的

Issue 43（https://github.com/susumutomita/koto-input/issues/43 ）の設計フェーズ。「あれやっといて」を文脈つき候補へ展開する AI Native IME 構想の基盤設計を ADR-0013 として起案する。

#### 制約

- ADR は Status: Proposed で起案し、ユーザー承認（PR レビュー）で Accepted 化する。
- 実装はしない（Accepted 後に実装フォローアップ Issue を作成）。

#### タスク

- [x] ADR-0013 起案: pull 型のみ / [CONTEXT] セクション（instructions 固定で prewarm 維持）/ 診断ログと作業記憶の概念分離 / 第一版はセッション内 in-memory / メモリ層・レイテンシ境界・プライバシーコントロール・評価方針
- [ ] PR レビューで承認 → Accepted 化 → マージ → 実装フォローアップ Issue 作成

#### 検証手順

ドキュメントのみ（textlint / harness green）。設計の妥当性は PR レビューで判断する。

#### 進捗ログ

- 2026-06-11: Issue 43 へ設計コメントを投稿（候補 UI の再利用・prewarm と文脈注入の干渉・ADR-0002 再定義・第一版スコープ）。同内容を骨格に ADR-0013 を起案。起案エージェントが scope 外の settings.json 修正を試みガードにブロックされた（ADR 本体に影響なし。hook 修正は F-179415533 のままユーザー承認待ち）。

### セッション内文脈メモリ（Issue 46 / ADR-0013 第一版） - 2026-06-11

#### 目的

Issue 46（https://github.com/susumutomita/koto-input/issues/46 ）の実装。commit テキスト直近 5 件（計 500 文字）を in-memory 保持し、Ctrl+Shift+Space で [CONTEXT] つき日本語 AI 変換を実行する。仕様書は `docs/specs/2026-06-11-セッション内文脈メモリ.md`（承認済み）。

#### 制約

- 既定 OFF（`contextMemoryEnabled = false`）で従来挙動と完全一致。OFF のとき Ctrl+Shift+Space は消費しない。
- instructions は固定のまま（prewarm 維持、ADR-0005）。[CONTEXT] はユーザープロンプト側。
- メモリ書き込みは hot path 禁止（Task で遅延）。ディスク永続なし。
- ヒアリング確定: トリガー = Ctrl+Shift+Space、N = 5 件、[CONTEXT] 上限 = 500 文字（UTF-16）。
- Issue 46 の「deactivate で消去」は仕様承認時に変更: 消去はプロセス終了・OFF 切替のみ（アプリ間フォーカス移動で消すと機能の核が成立しないため）。
- 本環境に Swift toolchain なし。コンパイル・テストの検証は CI の swift ジョブで行う。

#### タスク

- [x] ドキュメント先行: 仕様書（済）・Issue 46 追記・README（キー表・設定表・プライバシー）
- [x] ConversionSettings.contextMemoryEnabled（後方互換 decode）
- [x] SessionContextStore（@MainActor、FIFO 5 件・500 文字、サロゲート安全な切り詰め）
- [x] CompositionCommand.requestContextualConversion + reducer（attempt 判定キー = target + useContext）
- [x] CompositionCoordinator: commit 時追記（Task 遅延）・読み出し時 OFF クリア・ConversionRequest.contextEntries
- [x] PromptBuilder.prompt(modelInput:contextEntries:) + instructions の [CONTEXT] 固定行
- [x] InputController: Ctrl+Shift+Space ルーティング（OFF なら未消費）
- [x] フィクスチャ: context フィールド + 文脈あり/なしペア 2 組以上 + スキーマ契約拡張
- [x] 5 役割成果物（pm-review / design / test-plan / user-feedback）
- [x] ゲート（harness / before-commit / review / security-review / simplify）
- [x] コミット → push → draft PR（https://github.com/susumutomita/koto-input/pull/50 ）→ CI green

#### 検証手順

1. `bun scripts/architecture-harness.ts --staged --fail-on=error` がエラー 0。
2. `make before-commit` green。
3. CI swift ジョブで全テスト pass（カバレッジ 100% 維持）。
4. 実機確認はフォローアップ（`docs/terminal-compatibility.md` 方式）: ON にして文を commit → `arewoyatteoite` → Ctrl+Shift+Space → 文脈を踏まえた候補が出る。

#### 進捗ログ

- 2026-06-11: ヒアリング（トリガー・N・上限）→ 仕様書作成 → 承認。deactivate 消去の変更点を明示して承認を得た。Issue 構成は「Issue 46 単一 + docs/specs の役割別文書」で確定。
- 2026-06-11: Developer 実装完了（TDD: テスト先行）。新規 `SessionContextStore` + `SessionContextStoreTests`、`ConversionSettings.contextMemoryEnabled`（decodeIfPresent ?? false）、`CompositionCommand.requestContextualConversion`、`CompositionState.conversionUsedContext`、`Effect.startConversion` へ `useContext` 追加（attempt 同一性判定キー = target + useContext）、`ConversionRequest.contextEntries`、coordinator の commit 遅延追記（Task / hot path 外）と OFF 時クリア、`PromptBuilder.prompt(modelInput:contextEntries:)` と日本語 instructions の [CONTEXT] 固定行、provider のプロンプト経路、InputController の Ctrl+Shift+Space（OFF なら未消費）と repository プロパティ化、フィクスチャ context ペア 2 組 + 契約テスト、README（キー表・設定表・プライバシー）。Swift toolchain が無いため、コンパイル検証は CI の swift ジョブで行う。
- 2026-06-11: 統合レビューで 5 役割の申し送りを反映。(1) 候補重複なしテスト（文脈が結果を変えないケース）と [INPUT] リテラルの構造偽装防御テストを追加。(2) instructions の [CONTEXT] 固定行を「Return only the converted text.」の前へ移動（締めの指示を最後に保つ）。(3) README に設定 typo の無反応切り分け（defaults read）・膨張率調整ガイド・OFF→ON 残存の既知の制限を追記。(4) terminal-compatibility.md に JetBrains Smart Type Completion 衝突と Issue 46 の E2E シナリオ 6 手順を追記。(5) OFF→ON 残存穴（ポーリングでは遷移を観測不能）をフォローアップ F-69SKVN として記録。
- 2026-06-11: コードレビュー（7 finder 並列）の確定指摘を反映。正確性: recordCommittedText の [weak self] を store/repository 直接捕捉へ（deactivate 直後の解放で commit 収集が落ちる）、巨大単一書記素の切り詰めで空エントリが混入するのを切り詰め後ガードで防止、request 構築（設定ロード + snapshot）を変換 Task 内へ移動（MainActor ジョブの FIFO で「commit 直後の文脈つき変換にその commit が含まれる」を決定論化 + 同期キーパスから JSON decode を除去）、essentialFlags に .capsLock 除外を追加（Caps Lock 中に全変換キーが不一致になる既存バグ）、OFF 消去を全変換要求にも拡張して README の記述と一致。品質: OFF ゲートの正本を store 入口（append/snapshot の enabled 引数）へ一本化、PromptBuilder.bulletList を切り出し信頼境界で改行正規化（[CONTEXT] 構造偽装防御の正本を移設）、provider で japanese 以外への文脈注入を遮断、prompt オーバーロードを既定引数に統合、Ctrl+Shift+Space のガード順（composing 先行）、FIFO ループの合計長を差分更新化、テストヘルパー統合（converted へ via 引数 / FixedSettingsRepository を MutableSettingsRepository へ統合）、フィクスチャ契約を単一ループ + store 定数参照へ。フォローアップ: F-PKTPY4（converting 中再押下で候補消失・既存バグ）、F-2SCPV7（attempt キー値型化）。
- 2026-06-11: /security-review は High/Medium 検出なし（opt-in の fail-closed・テキストの非永続/非送信・[CONTEXT] 偽装防御・プロセス共有 store の境界を確認）。/simplify（4 角度）を実施し、改行正規化を String.collapsedToSingleLine（KotoCore 共有ヘルパー）へ集約、coordinator の commit 判定を committedText 単独条件へ、テストの converting/converted を単一の via ノブへ統合（英語系 4 呼び出し更新）、フィクスチャのペア検査を base ID の Set 比較へ。running total の差し戻しとテストセットアップ共通化・received* 配列統合は判断つきでスキップ。設計深度の残課題は F-D36AHW として記録。
- 2026-06-11: draft PR 50 を作成。CI 1 回目は swift テストビルドが失敗（非 MainActor suite の #expect の nonisolated autoclosure から @MainActor static 定数 maxTotalUTF16Length を参照不可）。定数 2 つへ nonisolated を明示して再 push（24cd169）→ CI 2 回目 green（swift / ci / GitGuardian。swift build は 1 回目から全ソース成功で、SE-0411 default 引数等の懸念箇所は問題なし）。

#### 振り返り

- 問題: 初回 CI で swift テストビルドが 1 件のコンパイルエラー（@MainActor 型の static 定数を非 MainActor テストから参照）。
- 根本原因: #expect マクロが比較の右辺を nonisolated autoclosure へ展開することを、ローカルで Swift を実行できない環境での静的読解で取りこぼした（グローバルアクター隔離型の static 定数はモジュール外の非隔離文脈から同期参照できない）。
- 予防策: @MainActor 型に置く不変の公開定数は nonisolated を既定とする。テストから参照する公開定数は、非隔離 suite からの参照を想定して宣言時に隔離属性を確認する。

### Homebrew 配布フォローアップ解消（version 刻印 + tap 化） - 2026-06-12

#### 目的

フォローアップ 2 件を解消する。(1) `01KTX3RT4KZXY139S2EDV2V97A`: リリース zip 内の Koto.app の `CFBundleShortVersionString` が 0.1.0 のままでタグと不一致。(2) `01KTX3RSR6FXJ5GFTGFBJS3T2G`: Homebrew 4.x でパス指定 cask インストールが廃止され、README と `Casks/koto.rb` の手順（`brew install --cask ./Casks/koto.rb`）が動作しない。

#### 制約

- フォローアップは原則別 PR のため 2 PR に分割する（PR A: version 刻印、PR B: tap 化）。
- tap の自動更新に新しい PAT を要求しない。tap リポジトリ自身の cron + workflow_dispatch ワークフローが公開 API で最新リリースを照会し、自身の `GITHUB_TOKEN` で commit する構成にする（cross-repo push を避ける）。
- GitHub Actions は ADR-0001 に従い commit SHA でピン留めする。
- cask の正本は tap リポジトリ（`susumutomita/homebrew-tap`）へ移し、koto-input 側の `Casks/koto.rb` は `git rm` で削除する（二重管理によるドリフト防止）。判断は ADR-0014 に記録する。

#### タスク

- [x] PR A: `scripts/build-koto-app.sh` に `KOTO_VERSION` 刻印（PlistBuddy、codesign 前）+ `release.yml` の Build ステップでタグから `KOTO_VERSION` を渡す
- [x] PR A: ローカルで `KOTO_VERSION=9.9.9` ビルドし plist を確認
- [x] tap リポジトリ `susumutomita/homebrew-tap` を作成（cask v1.0.1 + sync ワークフロー）
- [x] ローカルの暫定 tap（koto-local）から公開 tap へ移行してインストール検証
- [x] PR B: README のインストール手順を tap 経由へ更新、`Casks/koto.rb` を `git rm`、ADR-0014 起案
- [x] 各 PR でゲート（harness / before-commit / review / security-review / simplify）→ push → PR

#### 検証手順

1. `KOTO_VERSION=9.9.9 bash scripts/build-koto-app.sh` 後に `PlistBuddy -c "Print :CFBundleShortVersionString" build/Koto.app/Contents/Info.plist` が 9.9.9。
2. `brew tap susumutomita/tap && brew install --cask susumutomita/tap/koto` がローカルで成功。
3. 次回リリース後、tap の sync ワークフローが cask を新バージョンへ更新する（リリース後に確認）。

#### 進捗ログ

- 2026-06-12: Homebrew 4.x の「casks must be in a tap」でインストール不能の報告を受け調査。暫定としてローカル tap `susumutomita/koto-local` を作成し v1.0.1 を導入。リリース zip の版数不一致（0.1.0）と ad-hoc 署名 + quarantine を確認し、フォローアップ 2 件を記録。
- 2026-06-12: PR A 実装。刻印（PlistBuddy、codesign 前）+ タグ解決の `Resolve release tag` ステップへの一本化（simplify 指摘の反映: TAG 解決の重複排除・PlistBuddy 1 回化・`git describe --exact-match` によるローカルタグビルド補完）。ローカル実ビルドで刻印あり（9.9.9）・なし（0.1.0 のまま）の 2 通りと `codesign --verify` を確認。PR 51 を作成し CI 全項目 green。
- 2026-06-13: 公開 tap `susumutomita/homebrew-tap` を作成（ユーザー承認後）。cask v1.0.1 + `sync-cask` ワークフロー（cron 6h + dispatch、checkout は ADR-0001 と同じ SHA ピン）。workflow_dispatch で no-op パスの success を確認。ローカルを公開 tap へ移行（`brew tap susumutomita/tap` → インストール済み cask が新 tap へ解決されることを確認 → `koto-local` を untap → Homebrew 6 の tap trust を登録）。レビューで caveats の `"~/..."` がチルダ展開されない不具合を検出し `$HOME` へ修正。
- 2026-06-13: PR B 実装（README の tap 経由手順 + アンインストール手順の分岐、`Casks/koto.rb` を git rm、ADR-0014 起案）。PR 52 を作成し CI 全項目 green。フォローアップ 2 件の resolve はマージ後に実施。

#### 振り返り

- 問題: 配布手順が Homebrew の仕様変更（パス指定 cask インストールの廃止）で壊れており、さらに cask の `version` / `sha256` が v1.0.1 リリース後も手動更新されず 0.1.0 / `:no_check` のまま停滞していた。リリース zip 内の版数もタグと不一致だった。
- 根本原因: 「tap を作るまでの暫定」と明記したパス指定運用が恒久化していた。cask の鮮度維持とバージョン刻印がリリースフローに組み込まれておらず、人手の更新に依存していた。
- 予防策: リリースごとに追従が必要な配布メタデータは自動追従にする（tap 側 `sync-cask` と release workflow の刻印で構造化済み）。暫定運用を導入する時点で、恒久対応のフォローアップを同時に起票する。外部エコシステム（Homebrew 等）の breaking change はインストール手順の実地確認でしか発見できないため、リリース後に配布経路の実インストール確認を検証手順へ含める。

### greedy デッドエンドの自動回復（Issue 48） - 2026-06-13

#### 目的

Issue 48（https://github.com/susumutomita/koto-input/issues/48 ）。頭字語を含む入力で初回 greedy 出力が validator に拒否されたあと、Shift + Space を押しても attempt 0 に戻り続ける無音失敗ループを解消する。

#### タスク

- [x] ドキュメント先行更新: ADR-0015 と architecture.md に failed 再要求・上限付き自動 retry の仕様を記録
- [x] reducer: failed からの同一スナップショット再要求で attempt を引き継いで増やす
- [x] coordinator: validator 拒否時だけ同一 Task 内で最大 2 回の自動 retry を行う
- [x] テスト: scripted provider で failed 再要求、自動 retry、キャンセル停止を検証
- [x] 品質フィクスチャ: `SWIFThaiigengodesugahenkansarenaidesu` を再現ケースとして追加
- [ ] ゲート実行: staged harness → before-commit → swift-test

#### 検証手順

1. `swift build --package-path KotoInput` で実装ターゲットが compile。
2. `swift test --package-path KotoInput` で reducer / coordinator / フィクスチャの新規テストが pass。
3. `bun scripts/architecture-harness.ts --staged --fail-on=error` と `make before-commit` が green。

#### 進捗ログ

- 2026-06-13: Issue 48 を確認し、ADR-0015 を追加。ADR-0008 の「converted からの再抽選」を拡張し、failed からの再要求も同一スナップショットなら attempt を継続する判断を記録。coordinator は validator 拒否だけを同一 Task 内で最大 2 回自動 retry し、provider エラー・availability 失敗・キャンセルは retry しない設計にした。
- 2026-06-13: `ConversionResult` と `conversionFailed` に attempt を通し、成功・失敗のどちらでも最後に試した attempt を reducer が保持するよう実装。scripted provider で `SWIFThaiigengodesugahenkansarenaidesu` の invalid→valid 自動 retry、上限到達後 failed、retry 中の編集・Escape・commit cancellation、failed からの手動 retry attempt 継続を固定。品質フィクスチャにも Issue 48 入力を追加。
- 2026-06-13: ローカル検証は `swift build --package-path KotoInput` / `make swift-build` が成功。差分を一時 stage した状態で `make before-commit`（staged harness + textlint + biome）が green。`swift test --package-path KotoInput` / `make swift-test` はサンドボックス外で再実行してもローカル CommandLineTools に Swift Testing の `Testing` モジュールが無く、テストターゲットの compile 前に失敗した。Swift テストの最終確認は CI の macOS toolchain で行う。
