# ADR-0003: SwiftPM 単一パッケージ構成と Linux 縮退ビルド

- **Status**: Accepted
- **Date**: 2026-06-09
- **Deciders**: Susumu Tomita (susumutomita)

## Context

Issue 1 の提案構造はリポジトリ直下に `Apps/` と `Packages/`（独立 SwiftPM パッケージ群）を置く形だった。しかし本リポジトリには bun ワークスペースの `packages/`（小文字）が既にあり、macOS の既定ファイルシステム（APFS 大文字小文字非区別）では `Packages/` と衝突して git の状態が壊れる。また、開発・CI 環境の一部（Linux コンテナ、古い Xcode）には FoundationModels SDK が存在しないため、SDK の有無でビルド可否が変わらない構成が必要だった。

## Decision

Swift コードは `KotoInput/` 配下の単一 SwiftPM パッケージ（swift-tools-version 6.0）にまとめ、その内部でターゲットパスを Issue の提案構造（`Apps/` / `Packages/` / `Tests/`）に合わせる。

- `KotoCore`（library）: Foundation のみに依存。InputMethodKit / AppKit / FoundationModels を import しない。
- `AppleFoundationModelsProvider`（library）: `#if canImport(FoundationModels)` + `@available(macOS 26.0, *)` でガードし、SDK が無い環境では「モデル利用不可」を返す実装に縮退してコンパイルが通る。
- `KotoInputMethod`（executable）: `#if canImport(InputMethodKit)` でガード。IMK の API は Swift 6 strict concurrency と相性が悪いため、このターゲットのみ Swift 5 言語モードでコンパイルする。
- 入力メソッドの `.app` バンドルは Xcode プロジェクトではなく `scripts/build-koto-app.sh` で SwiftPM のビルド成果物から組み立てる。

## Consequences

- **Good**: `swift build` / `swift test` 一発で全ターゲットを検証できる。FoundationModels の無いランナーでもコンパイルとコアテストが通る。APFS 上のディレクトリ衝突がない。Xcode プロジェクトファイルの差分管理が不要。
- **Bad**: コード署名・アセットカタログ・notarization は手書きスクリプトでは扱いづらい（配布段階で Xcode プロジェクト化を再検討）。`KotoInputMethod` だけ言語モードが古い。
- **Tradeoff**: パッケージ分離（KotoCore を独立リポジトリ化等)の柔軟性を捨てた。CLI ツール等から KotoCore を使う需要が出た時点で分離を再検討する。

## References

- 関連コード: `KotoInput/Package.swift`、`scripts/build-koto-app.sh`
- 関連 Issue: https://github.com/susumutomita/koto-input/issues/1
- 関連 ADR: [ADR-0002](./0002-apple-foundation-models-をオンデバイス変換プロバイダに採用.md)
