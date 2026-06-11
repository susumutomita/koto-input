# ADR-0012: 変換候補は marked text 内で巡回選択する

- **Status**: Accepted
- **Date**: 2026-06-11
- **Deciders**: Susumu Tomita (susumutomita)

## Context

多言語変換（Issue 34）では、変換結果を 1 つ以上の候補として表現し、ユーザーが明示的に選んでから commit できる必要がある（自動 commit 禁止・Escape で原文復元・Enter は commit のみ）。従来 IME の候補表示手段である IMKCandidates パネルは、現環境で実機検証ができないこと、主用途であるターミナルではパネルのフォーカス・座標計算の相性問題が知られていることから採用しにくい。また ADR-0008 で導入した再抽選は「押すたびに別候補が出る」が、一度通り過ぎた候補へ戻る手段が無かった。

## Decision

候補は別ウィンドウを出さず、**marked text の表示をその場で差し替える巡回選択**で表現する。

- **候補の蓄積**: ConversionOutputValidator を通過して converted として表示された結果だけを `ConversionCandidate` として `CompositionState.candidates` に蓄積する（検証通過済みが不変条件）。converted からの再変換要求（同 target の再抽選・別 target への切替）では候補をクリアせず蓄積を継続するため、日本語と英語の候補が共存できる。同一 text + target の結果は重複追加せず既存候補を選択し直す。
- **候補のリセット**: 原文スナップショットを壊す編集・タイプ先行の splice・cancel・commit・restoreSource・deactivate・新しい composition で `candidates` / `selectedCandidateIndex` をクリアする（retryCount のリセットと同じ文脈規則）。
- **巡回選択**: `.selectCandidate(offset:)`（+1 = 次、-1 = 前）は converted かつ候補 2 件以上のときだけ有効で、wrap around で移動し displayedText を候補テキストへ差し替える。sourceText / isSourcePreserved / candidates は不変のため、Escape は引き続き原文へ戻り、Enter は表示中の候補だけを commit する。
- **矢印キーの消費条件**: 上矢印（keyCode 126）/ 下矢印（keyCode 125）は「composition があり、修飾キーなしで、`canCycleCandidates`（converted かつ候補 2 件以上）」のときだけ消費する。条件を満たさなければ false で通し、ターミナルの履歴操作を奪わない。
- **複数候補の同時生成はしない**: 候補はあくまで再抽選・target 切替の履歴として蓄積する。1 回の変換で n 個の候補を同時生成するとオンデバイスモデルのレイテンシが n 倍になるため見送る（ADR-0008 と同じ判断）。
- **候補メタデータの導出**: `ConversionCandidate` は `text` / `target` / `attempt` のみ持ち、出力プロファイルは持たない。reducer は純粋関数で設定（ConversionSettings）にアクセスできず、ConversionResult もプロファイルを運ばないため、メタデータは reducer が既に保持する `conversionTarget` / `retryCount`（stale 照合を通過した結果の要求時の値）から導出する。入力モードの区別は target から導く（`.japanese` = 日本語変換、それ以外 = 翻訳）。

## Consequences

- **Good**: 追加 UI なしで候補の往復ができ、ターミナルでも動作が変わらない。Escape の復元・stale 拒否・タイプ先行の既存規則と直交し、reducer の純粋性を保ったままテストできる。
- **Bad**: 候補の一覧性が無い（1 つずつしか見えない）。候補は再抽選した分しか貯まらないため、最初の上下キーが効くのは 2 回目の変換以降になる。
- **Tradeoff**: IMKCandidates パネル（一覧表示・番号選択）を捨てた。実機検証の環境が整い、ターミナル以外のアプリでの利用が主になったら再検討する。複数候補の同時生成はレイテンシが許容できるモデル世代になったら再検討する。

## References

- 関連コード: `KotoInput/Packages/KotoCore/Sources/ConversionCandidate.swift`、`KotoInput/Packages/KotoCore/Sources/CompositionTransition.swift`、`KotoInput/Apps/KotoInputMethod/Sources/InputController.swift`
- 関連 Issue: https://github.com/susumutomita/koto-input/issues/34
- 関連 ADR: [ADR-0008](./0008-再変換は温度付き再抽選.md)、[ADR-0009](./0009-多言語変換はターゲット別-instructions-と使い捨てセッションで実現.md)
