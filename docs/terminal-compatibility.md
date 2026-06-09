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

## 既知の制限（実装由来）

- `Control + Enter` は composition 内に改行を挿入するが、ターミナル側の行レンダリングによっては marked text の複数行表示が崩れる場合がある。挙動はターミナル実装依存。
- 変換中であることの表示は marked text の下線スタイルのみ。スピナーや通知は MVP では出さない。
- モデル利用不可（Apple Intelligence 無効等）のときは、元テキストを保持したまま状態を `failed` にする。エラーメッセージをターミナルの入力欄に挿入することはしない。
- アプリケーション固有のハックは入れない方針のため、ターミナル側の不具合は本ファイルに記録して回避策の有無のみ書く。
