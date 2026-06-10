# ADR-0002: Apple Foundation Models をオンデバイス変換プロバイダに採用

- **Status**: Accepted
- **Date**: 2026-06-09
- **Deciders**: Susumu Tomita (susumutomita)

## Context

Koto はターミナル（Claude Code / Codex CLI）への入力テキストを日本語へ変換する入力メソッドであり、ユーザーが打つ内容にはコード・認証情報・未公開の設計判断が含まれうる。変換のためにテキストを外部 API（OpenAI、Ollama サーバー等）へ送ると、プライバシー・レイテンシ・オフライン動作の 3 点で入力メソッドとして成立しない。macOS 26 以降には Apple Intelligence のオンデバイスモデルへアクセスする FoundationModels framework（`SystemLanguageModel` / `LanguageModelSession`）が組み込まれている。

## Decision

変換は Apple Foundation Models（オンデバイス）のみで行う。Ollama・OpenAI を含む外部サービスへのフォールバックは実装しない。実装は `TextConversionProvider` protocol の背後に置き、`AppleFoundationModelsProvider` が以下を担う。

- 変換前に `SystemLanguageModel.default.availability` を確認し、利用不可ならユーザー可視のエラー（`KotoError.modelUnavailable`）を返す。`modelNotReady` は `preparing` として区別する。
- リクエストごとに `LanguageModelSession(instructions:)` を新規作成する。セッションは transcript（会話履歴）を保持するため、再利用すると過去の変換入力が次の変換に影響し、コンテキスト長も増える。入力メソッドの変換は独立した単発タスクであり、セッション再利用の利点がない。
- Swift の cooperative cancellation に従い、フレームワークのエラー（guardrail 拒否・コンテキスト超過等）は `KotoError` に写像する。

## Consequences

- **Good**: ユーザーテキストがデバイス外に出ない。ネットワーク不要。API キー・課金・レート制限の管理が不要。
- **Bad**: macOS 26 以降 + Apple Silicon + Apple Intelligence 有効化が必須。モデル品質を選べず、guardrail による拒否がありうる（拒否時は元テキストを保持して failed にする）。
- **Tradeoff**: クラウドモデルの方が変換品質は高いが、入力メソッドという用途ではプライバシーが品質に優先する。Apple がより高品質なオンデバイスモデルや adapter を公開したら provider 追加を再検討する。provider 抽象があるため追加は KotoCore に手を入れずにできる。

## References

- 関連コード: `KotoInput/Packages/AppleFoundationModelsProvider/Sources/AppleFoundationModelsProvider.swift`
- 関連 Issue: https://github.com/susumutomita/koto-input/issues/1
- 外部資料: https://developer.apple.com/documentation/foundationmodels
