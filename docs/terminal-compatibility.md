# ターミナル互換性マトリクス

Issue 1 の Scope 5 で要求される手動検証の記録。実機（macOS 26 / Apple Silicon / Apple Intelligence 有効）でしか実施できないため、未実施の組み合わせは「未検証」のまま残し、検証のたびに更新する。

## 検証手順（各組み合わせ共通）

1. Koto を入力ソースとして選択する。
2. ターミナルで Claude Code または Codex CLI を起動する。
3. ローマ字・英語・日本語の混在テキストを入力する（例: `kono authentication no sekinin han'i ga aimai`）。
4. 以下を確認して記録する。

| 確認項目 | 期待動作 |
|---|---|
| marked text 表示 | 未確定テキストが下線付きで表示される |
| 変換が送信を起こさない | `Shift + Space` でプロンプトが送信されない |
| commit と送信の分離 | 1 回目の Enter は確定のみ。2 回目の Enter で送信される |
| Escape 復元 | 変換後の Escape で元テキストに戻る |
| Unicode 耐性 | 絵文字・コードスパン・パス・複数行が壊れない |
| カーソル移動と Backspace | marked text 内で正しく動く |
| 入力ソース切替 | composition 途中の切替で stale な marked text が残らない |
| 変換中のアプリ切替 | 変換タスクが cancel され、後から描画されない |

## マトリクス

| ターミナル | アプリ | 状態 | 備考 |
|---|---|---|---|
| Apple Terminal | Claude Code | 未検証 | |
| Apple Terminal | Codex CLI | 未検証 | |
| Ghostty | Claude Code | 未検証 | |
| Ghostty | Codex CLI | 未検証 | |
| iTerm2 | Claude Code | 未検証 | |
| iTerm2 | Codex CLI | 未検証 | |
| VS Code 統合ターミナル | Claude Code | 未検証 | Ctrl + Shift + キーの衝突確認を含む（下記） |

## 多言語変換キーの E2E シナリオと既知のキー衝突

多言語変換キー（`docs/specs/2026-06-11-多言語変換キー.md`）の実機確認。英語 + もう 1 言語で実施し、結果をマトリクスの備考に記録する。

1. `kyouhaiihida` と入力し `Ctrl + Shift + E` → 「Today is a good day」相当の自然な英語になること。
2. 編集せずにもう一度 `Ctrl + Shift + E` → 別候補に変わること（再抽選）。
3. `Ctrl + Shift + K`（または他言語キー）→ その言語の訳へ変わること。
4. `Shift + Space` → 日本語変換へ戻ること。`Escape` → `kyouhaiihida` へ復元されること。
5. `Claude Code wo tamesu` で `Ctrl + Shift + E` → 出力に `Claude Code` が原文のまま残ること（保護語）。
6. composition が無い状態で `Ctrl + Shift + E` 等を押し、ターミナル側のショートカットとして動作すること（Koto が奪わないこと）。

既知の衝突（アプリ側がキーを先取りし得る組み合わせ。composition 中でもアプリ設定によっては届かない）。

| キー | 衝突するアプリ・機能 | 回避策 |
|---|---|---|
| `Ctrl + Shift + E` | VS Code（エクスプローラーフォーカス） | VS Code 側のキーバインド変更、または `terminal.integrated.sendKeybindingsToShell` の調整 |
| `Ctrl + Shift + C` | VS Code（ターミナルへのコピー）・Ghostty（コピー） | 同上。Ghostty は `keybind` 設定で変更可能 |
| `Ctrl + Shift + F` / `G` | VS Code（検索 / ソース管理） | 同上 |
| `Ctrl + Shift + Space` | JetBrains 系 IDE（Smart Type Completion） | IDE 側のキーバインド変更。衝突するのは `contextMemoryEnabled` が true かつ composition 中のみ（false の間は Koto がキーを消費しない） |

## セッション内文脈メモリの E2E シナリオ（Issue 46）

セッション内文脈メモリ（`docs/specs/2026-06-11-セッション内文脈メモリ.md`、ADR-0013）の実機確認。`contextMemoryEnabled` を true にして実施し、結果をマトリクスの備考に記録する。

1. OFF（デフォルト）のまま composition 中に `Ctrl + Shift + Space` → Koto が消費せずアプリ側ショートカットとして動作すること。
2. ON にして `Issue 46 no review wo onegai` を変換・確定し、続けて `arewoyatteoite` と入力して `Ctrl + Shift + Space` → 直前に確定した内容を踏まえた展開候補が出ること。
3. 同じ状態で `Shift + Space` → 文脈なしの変換となり、`↑` / `↓` で文脈つき候補と見比べられること。
4. 別アプリ（メモ等）で文を確定してからターミナルへ戻り、`reinoken` + `Ctrl + Shift + Space` → 別アプリで確定した内容も文脈として参照されること（プロセス共有）。
5. `contextMemoryEnabled` を false に戻して任意のテキストを確定 → 以後の `Ctrl + Shift + Space` がアプリへ通り、文脈が消去されていること。
6. ON のまま Koto を再起動（入力ソース切替 + プロセス終了）→ 文脈が空から始まること（ディスク永続なし）。

## かな正規化の E2E シナリオ（Issue 10）

ローマ字かな変換層（ADR-0006）の実機確認。各ターミナルで以下を実施し、結果をマトリクスの備考に記録する。

1. Koto を選択し、`kyouhaiihida` と分かち書きなしで入力する。
2. `Tab` を押す → marked text が「きょうはいいひだ」になること（即時・AI 不要）。
3. もう一度 `Tab` → 「キョウハイイヒダ」、さらに `Tab` → 「きょうはいいひだ」へ巡回すること（かな形態巡回）。
4. `Escape` → `kyouhaiihida` に戻ること。
4. もう一度ひらがな化せずに `Shift + Space` → 「今日はいい日だ」相当の自然な日本語になること（前段かな正規化によりモデルの誤読が出ないこと）。
5. `Claude Code wo tamesu` で `Shift + Space` → 出力に `Claude Code` が原文のまま残ること（保護語）。

## 既知の制限（実装由来）

- `Control + Enter` は composition 内に改行を挿入するが、ターミナル側の行レンダリングによっては marked text の複数行表示が崩れる場合がある。挙動はターミナル実装依存。
- 変換中であることの表示は marked text の下線スタイルのみ。スピナーや通知は MVP では出さない。
- モデル利用不可（Apple Intelligence 無効等）のときは、元テキストを保持したまま状態を `failed` にする。エラーメッセージをターミナルの入力欄に挿入することはしない。
- アプリケーション固有のハックは入れない方針のため、ターミナル側の不具合は本ファイルに記録して回避策の有無のみ書く。
