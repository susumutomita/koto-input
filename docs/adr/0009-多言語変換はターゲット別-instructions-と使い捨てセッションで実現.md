# ADR-0009: 多言語変換はターゲット別 instructions と使い捨てセッションで実現

- **Status**: Accepted
- **Date**: 2026-06-11
- **Deciders**: Susumu Tomita (susumutomita)

## Context

Ctrl + Shift + 言語キーで composition を英語・中国語（簡体字）・韓国語・フランス語・ドイツ語・スペイン語へ変換する多言語変換キー（Issue 24〜28、仕様書 `docs/specs/2026-06-11-多言語変換キー.md`）を導入した。実現方式には複数の選択肢があった。(a) Apple Translation framework との 2 段変換、(b) 単一セッションの instructions に全言語を書きユーザープロンプトで言語を指定、(c) ターゲット言語ごとに instructions を分けてセッションを構築。また、日本語変換向けに調整済みの出力検証（末尾句点 strip・鉤括弧 unwrap）やキー判定の方式も決める必要があった。

## Decision

1. **`ConversionTarget` を導入し、変換要求（`requestConversion` / `ConversionRequest`）に変換先言語を貫通させる**。状態機械の構造（原文スナップショット・stale 拒否・Escape 復元・タイプ先行）は変更せず、converted からの再要求を「同じ target = attempt + 1 の再抽選（ADR-0008）、異なる target = attempt 0 の変換し直し」と解釈する。
2. **instructions はターゲット言語ごとに分けて構築する（方式 c）**。小型のオンデバイスモデルに全言語の指示を同居させると指示追従が不安定になるため。日本語の instructions は従来のまま一字一句変えない。翻訳の instructions は忠実な訳・保護語/識別子の verbatim 維持・忠実な few-shot 1 例で構成し、言い換えを教えない（Issue 22 の教訓）。文体設定（`style`）とカスタム指示は日本語変換向けの設定なので翻訳には適用しない。
3. **セッションは target をキーにした prepared box で管理し、prewarm は日本語のみ行う**。翻訳 6 言語分のセッション常駐を避け、翻訳セッションは要求時にその場で作る。セッションが使い捨てで transcript を持ち越さない原則（ADR-0002、ADR-0005）は全 target で維持する。
4. **出力検証は共通検査と日本語固有検査に分ける**。空・膨張率・保護語・頭字語の検査は全言語共通。末尾句点 strip と鉤括弧 unwrap は日本語の出力癖への対処なので `.japanese` のみに適用し、訳文の句読点・括弧は訳の一部として保持する。
5. **言語キーはキーコードではなく文字（`charactersIgnoringModifiers`）で判定する**。`ConversionTarget(languageKey:)` の純関数に切り出し、キーボードレイアウト差を吸収する。composition が無いときはイベントを消費せずアプリへ通す。
6. **Translation framework との 2 段変換（方式 a）は採らない**。対応言語はオンデバイスモデルの範囲に限定し、非対応言語への拡張は別機能として検討する。

## Consequences

- **Good**: 状態機械の構造変更ゼロで多言語化でき、既存のすべての安全機構（stale 拒否・原文復元・保護語検証）が翻訳にもそのまま効く。日本語変換の品質・決定性に影響しない。
- **Bad**: 翻訳の初回変換は prewarm が無いぶん日本語より遅い。言語キーの割当（E/C/K/F/G/S）は固定で、VS Code 統合ターミナル等のアプリ側ショートカットと衝突した場合はアプリ側の設定変更でしか回避できない。
- **Tradeoff**: 言語ごとの instructions 分割はプロンプトの保守箇所を増やすが、単一プロンプトへの同居による品質劣化より保守コストを取った。キーマップのカスタマイズ・翻訳セッションの prewarm 最適化は将来の Issue で再検討する。

## References

- 関連コード: `KotoInput/Packages/KotoCore/Sources/ConversionTarget.swift`、`PromptBuilder.swift`、`ConversionOutputValidator.swift`、`CompositionTransition.swift`、`KotoInput/Packages/AppleFoundationModelsProvider/Sources/AppleFoundationModelsProvider.swift`
- 関連 Issue: https://github.com/susumutomita/koto-input/issues/24 〜 https://github.com/susumutomita/koto-input/issues/28
- 関連 ADR: [ADR-0002](./0002-apple-foundation-models-をオンデバイス変換プロバイダに採用.md)、[ADR-0005](./0005-タイプ先行と-prewarm-戦略.md)、[ADR-0008](./0008-再変換は温度付き再抽選.md)
- 仕様書: `docs/specs/2026-06-11-多言語変換キー.md`
