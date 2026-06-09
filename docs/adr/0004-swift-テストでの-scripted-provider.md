# ADR-0004: Swift テストでの ScriptedConversionProvider 許容

- **Status**: Accepted
- **Date**: 2026-06-09
- **Deciders**: Susumu Tomita (susumutomita)

## Context

CLAUDE.md と `INVARIANT_NO_MOCK_DATA` は「テストでは実 DB・実 API を使う（No Mock）」を原則とする。一方、Issue 1 の詳細設計は CompositionCoordinator のテストに「suspend・成功・失敗・キャンセル観測を制御できる provider」を明示的に要求している。実際の Apple Foundation Models は (1) Apple Intelligence が有効な実機でしか動かず CI ランナーでは利用不可、(2) 出力が非決定的で stale 判定やキャンセル順序の検証に使えない、という 2 点で「実 API を使う」原則をそのまま適用できない。

## Decision

Swift のテストターゲット限定で、`TextConversionProvider` を実装したテスト制御用 actor `ScriptedConversionProvider` を許容する。適用範囲を以下に限定する。

- 置き場所はテストターゲット（`KotoInput/Tests/`）のみ。アプリ実装ターゲットには固定スタブ・フェイクデータを置かない（`INVARIANT_NO_MOCK_DATA` の対象は従来どおり）。
- 検証対象は並行性・状態遷移（stale 拒否、キャンセル、描画順序）に限る。変換品質のテストには使わない。
- 実モデルでの変換は `AppleFoundationModelsProviderTests` が availability を確認した上で実行し、利用不可の環境ではスキップする。実機での一気通貫検証は `docs/terminal-compatibility.md` のチェックリストで担保する。

## Consequences

- **Good**: stale 結果の拒否・キャンセル・「provider 利用不可で元テキスト保持」のような異常系を決定論的に検証できる。CI（Apple Intelligence の無い macOS ランナー）でテストが安定する。
- **Bad**: ScriptedConversionProvider が実フレームワークの挙動（エラー型・タイミング）から乖離するリスクがある。乖離が見つかったら provider 実装ではなくテスト側を直す。
- **Tradeoff**: No Mock 原則の例外を 1 つ作った。例外の拡大（アプリ実装へのスタブ持ち込み等）はこの ADR の根拠にならない。

## References

- 関連コード: `KotoInput/Tests/KotoCoreTests/`
- 関連 Issue: https://github.com/susumutomita/koto-input/issues/1（「Coordinator tests with mocks」節）
- 関連 invariant: `INVARIANT_NO_MOCK_DATA`（`docs/architecture/harness.md`）
