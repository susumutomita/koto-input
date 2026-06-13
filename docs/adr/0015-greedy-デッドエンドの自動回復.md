# ADR-0015: greedy デッドエンドの自動回復

- **Status**: Accepted
- **Date**: 2026-06-13
- **Deciders**: Susumu Tomita (susumutomita)

## Context

ADR-0008 で、初回変換は greedy、converted からの再変換は温度付き再抽選と決めた。ところが検証で初回 greedy 出力が拒否されると、状態は failed になり、次の Shift + Space は「編集後の新規変換」と同じ扱いで attempt 0 に戻っていた。attempt 0 は決定的なので、頭字語を含む入力では同じ無効出力を繰り返し、ユーザーには何も変換されないように見える。validator が頭字語喪失や意味置換を拒否する判断は正しいため、検証を緩めずに retry 経路を直す必要がある。

## Decision

failed から編集せずに再要求された変換も、converted と同じ「同一スナップショットへの再要求」として扱う。同じ target / 文脈有無なら attempt を増やし、別 target / 文脈有無なら attempt 0 から変換し直す。

検証失敗は coordinator 内で上限付きに自動 retry する。最初の request attempt を実行し、validator が拒否した場合だけ、同じ requestID / compositionID / revision / sourceText のまま attempt を増やして最大 2 回まで追加で provider を呼ぶ。availability 失敗、provider 例外、キャンセルは自動 retry しない。自動 retry 中も同じ Task に閉じ込め、編集・Escape・commit・deactivate による cancellation と reducer の stale 照合を維持する。

成功・失敗のどちらでも、reducer が最後に実行した attempt を state に反映する。これにより、自動 retry 後にユーザーがさらに Shift + Space を押した場合も、既に試した attempt から戻らずに次の抽選へ進む。

決定論かな化結果を最終フォールバックとして自動提示する案は採用しない。かな化結果は Tab で明示的に得られるため、AI 変換の成功候補として混ぜると候補履歴と converted の意味が曖昧になる。

## Consequences

- **Good**: validator を緩めずに、greedy の同一失敗ループから自動で抜けられる。失敗後の手動再要求も attempt を継続する。
- **Bad**: 検証失敗時だけ provider 呼び出しが最大 3 回になり、レイテンシが増える。
- **Tradeoff**: 最終フォールバックのかな化提示は見送る。全 retry が検証失敗した場合は failed のまま原文を保持し、次の再要求でさらに attempt を進める。

## References

- 関連コード: `KotoInput/Packages/KotoCore/Sources/CompositionTransition.swift`、`KotoInput/Packages/KotoCore/Sources/CompositionCoordinator.swift`
- 関連 Issue: https://github.com/susumutomita/koto-input/issues/48
- 関連 ADR: [ADR-0008](./0008-再変換は温度付き再抽選.md)、[ADR-0004](./0004-swift-テストでの-scripted-provider.md)
