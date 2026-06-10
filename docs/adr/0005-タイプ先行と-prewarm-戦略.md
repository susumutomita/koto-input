# ADR-0005: 変換中のタイプ先行（prefix-splice）と prewarm 戦略

- **Status**: Accepted
- **Date**: 2026-06-10
- **Deciders**: Susumu Tomita (susumutomita)

## Context

実機検証で「変換完了を待つ間、入力が止まる」という体験上の課題が出た。lazyjp-vscode（エディタプラグイン型の同種ツール）は、変換を背景実行して元の行を追跡し、ユーザーは先へ入力し続けられる。Issue 1 の元設計は「変換中の編集は変換をキャンセルする」と定めており（stale 結果の安全側設計）、タイプ先行とは両立しない。また、変換ごとに `LanguageModelSession` を新規作成するため（ADR-0002）、instructions の前処理がレイテンシに毎回乗っていた。

## Decision

### タイプ先行（prefix-splice）

変換中の編集を一律キャンセルから、次の条件分岐に変える。

- 変換要求時のスナップショット（`sourceText`）が composition の先頭にそのまま残る編集（末尾追記・追記分の編集）は変換を**継続**する。
- 結果が届いたら、スナップショット部分だけを変換結果に差し替え（splice）、追記分は保持する。カーソルは UTF-16 差分だけシフトする。
- スナップショットの先頭一致を壊す編集（prefix 内への挿入・削除）は従来どおり**キャンセル**する。
- splice 適用後と、追記がある状態での Escape は、追記分を失わないことを優先して Escape 復元を無効化（テキスト保持で変換のみ中止）する。

stale 結果の三重照合（compositionID / requestID / revision）は維持し、prefix 一致を第 4 の防御として追加する。

### prewarm（会話継続は採用しない）

- composition 開始（idle → composing）時に、設定スナップショットから作った `LanguageModelSession` を事前作成して `prewarm()` し、変換要求時はそれを 1 回だけ使い捨てる。
- transcript を持ち越す会話継続（lazyjp の continuous mode 相当）は採用しない。lazyjp 作者自身がコストに対して効果が薄いとしてデフォルト OFF にしており、Koto は greedy sampling + few-shot で出力の一貫性を担保済みのため。ADR-0002 の「セッション使い捨て」原則は維持される。

## Consequences

- **Good**: 変換待ちで入力が止まらない。変換の決定性を保ったままレイテンシを削減できる。prefix が壊れた場合は従来の安全側（キャンセル）へ自然に退避する。
- **Bad**: splice 後は Escape での原文復元ができない（追記保持とのトレードオフ）。状態遷移の分岐が増え、Issue 1 の元設計表とは挙動が異なる（本 ADR が正本）。
- **Tradeoff**: 会話継続による語彙一貫性を捨てた。変換間の語彙ブレが問題になったら、保護語・カスタム指示での対応を先に試し、それでも不足なら設定として会話継続を再検討する。

## References

- 関連コード: `KotoInput/Packages/KotoCore/Sources/CompositionTransition.swift`、`KotoInput/Packages/AppleFoundationModelsProvider/Sources/AppleFoundationModelsProvider.swift`
- 関連 Issue: https://github.com/susumutomita/koto-input/issues/5
- 関連 ADR: [ADR-0002](./0002-apple-foundation-models-をオンデバイス変換プロバイダに採用.md)
- 外部資料: https://github.com/raspy135/lazyjp-vscode
