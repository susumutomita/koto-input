# Koto

Koto は、ローマ字・英語・日本語の混在テキストを自然な日本語へ変換する macOS 用入力メソッド。変換には macOS 組み込みのオンデバイスモデル（Apple Intelligence の FoundationModels framework）を使う。Claude Code や Codex CLI などのターミナルアプリへ送信する前のテキストを、composition バッファ内で変換する。

入力例。

```text
kono authentication no sekinin han'i ga aimai dakara application layer dake de check suru noha abunai
```

変換例。

```text
この認証設計は責任範囲が曖昧なので、アプリケーション層だけでチェックするのは危険です。
```

## 特徴

- 変換はデバイス上で完結し、入力テキストを外部サービスへ送信しない。
- 変換と送信が分離しており、`Shift + Space` は変換だけを行う。
- Escape で変換前のテキストへ戻せる。
- 特定アプリ向けの拡張ではなく入力メソッドとして動くため、ターミナル以外でも使える。

## 必要環境

| 項目 | 要件 |
|------|------|
| OS | macOS 26 (Tahoe) 以降 |
| ハードウェア | Apple Silicon 搭載 Mac |
| 設定 | Apple Intelligence を有効化済み |
| ビルド | Xcode 26 以降（FoundationModels SDK を含む） |

## インストール

ソースからビルドする場合。

```bash
make ime-install   # ビルドして ~/Library/Input Methods へ配置
```

Homebrew を使う場合（GitHub Releases にリリースがあるとき）。

```bash
brew install --cask ./Casks/koto.rb
```

リリースは tag（`v*`）の push で `release` workflow が自動作成する。署名・公証は secrets（Developer ID 証明書と App Store Connect API キー）を設定した場合のみ行われ、未設定のリリースは Gatekeeper にブロックされるためソースビルドを使う。

配置後の手順。

1. システム設定 > キーボード > 入力ソース > 編集 > + ボタンを押す。
2. 「日本語」から「Koto」を追加する。一覧に出ない場合は一度ログアウトして再ログインする。
3. メニューバーの入力ソースで Koto を選択する。

アンインストールは入力ソースから Koto を外し、`~/Library/Input Methods/Koto.app` をゴミ箱へ移す。

## キー操作

| キー | 動作 |
|------|------|
| `Shift + Space` | AI 変換を要求する |
| `Tab` | ローマ字をその場でひらがなに変換する（AI 不要・即時） |
| `Escape` | 変換のキャンセル、または変換前テキストの復元 |
| `Enter` | composition の確定（送信はしない） |
| `Control + Enter` | composition 内に改行を挿入する |

Enter は確定だけを行う。Claude Code / Codex へプロンプトを送信するのは、確定後にもう一度押す Enter。

変換結果が気に入らない場合、編集せずにもう一度 `Shift + Space` を押すと別候補を再抽選する（初回は決定的、2 回目以降は揺らぎあり）。`Escape` を押せば何回再変換した後でも元のローマ字へ戻る。

## 設定

設定は `com.susumutomita.inputmethod.Koto` ドメインの UserDefaults に JSON 文字列で保存する。

```bash
defaults write com.susumutomita.inputmethod.Koto conversionSettings -string \
  '{"style":"polite","customInstruction":"","protectedTerms":["Claude Code","Codex"],"maximumExpansionRatio":4}'

# デフォルトへ戻す
defaults delete com.susumutomita.inputmethod.Koto conversionSettings
```

| キー | 値 |
|------|----|
| `style` | `neutral` / `polite` / `plain` |
| `customInstruction` | 追加の変換指示テキスト |
| `protectedTerms` | 出力に原文どおり残す語の配列 |
| `maximumExpansionRatio` | 出力長の上限倍率（デフォルト 4.0） |

## プライバシー

- 変換は Apple Foundation Models（オンデバイス）のみで行い、クラウドフォールバックを持たない（[ADR-0002](./docs/adr/0002-apple-foundation-models-をオンデバイス変換プロバイダに採用.md)）。
- 入力テキストと変換結果をログに残さない。
- アナリティクスを持たない。

## 既知の制限

- Apple Intelligence が無効な環境では変換できない。その場合も元テキストは保持される。
- ターミナルごとの互換性検証の状況は [docs/terminal-compatibility.md](./docs/terminal-compatibility.md) を参照。
- 変換中の表示は marked text の下線のみで、スピナーや通知は出ない。

## 開発

Koto 本体は `KotoInput/` 配下の SwiftPM パッケージ。構成は [docs/architecture.md](./docs/architecture.md) を参照。

```bash
make swift-build   # 全ターゲットのビルド
make swift-test    # KotoCore / provider のテスト
make ime-build     # build/Koto.app の組み立てのみ
```

Linux など Swift toolchain の無い環境では、CI の macOS ジョブが swift build / swift test を実行する。

## リポジトリのツールスタック

| 用途 | ツール |
|------|--------|
| 入力メソッド本体 | Swift / SwiftPM / InputMethodKit / FoundationModels |
| ランタイム（開発ツール） | Bun |
| リンター/フォーマッター | Biome |
| ドキュメント lint | textlint |
| Git フック | Husky |

```bash
make install        # 開発ツールの依存をインストール（ignore-scripts）
make setup-hooks    # Husky hooks をセットアップ
make lint           # biome check
make lint_text      # textlint（README）
make before-commit  # コミット前チェック（harness + textlint + lint）
```

## ディレクトリ構成

```
.
├── .claude/                # Claude Code フック設定・スキル
├── KotoInput/              # Swift パッケージ（入力メソッド本体）
│   ├── Apps/KotoInputMethod/
│   ├── Packages/KotoCore/
│   ├── Packages/AppleFoundationModelsProvider/
│   └── Tests/
├── docs/                   # アーキテクチャ・ADR・互換性マトリクス
├── scripts/                # architecture-harness / Koto.app ビルド
├── biome.json
├── CLAUDE.md               # AI エージェント向け開発ガイドライン
└── Makefile
```

## サプライチェイン防御

このテンプレートは Shai-Hulud 系（[Flatt Security の解説](https://blog.flatt.tech/entry/mini_shai_hulud_2nd)）のサプライチェイン攻撃を多層で防ぐデフォルト値を持つ。

- `make install` / `make install_ci` は常に `--ignore-scripts` を付ける。**Bun は `.npmrc` の `ignore-scripts` も `npm_config_ignore_scripts` 環境変数も読まない**（公式 docs では `bunfig.toml` のみが設定経路）ため、Bun を叩くコマンド側で毎回明示する必要がある。husky の `prepare` も巻き添えで止まるので `make setup-hooks` で明示的に opt-in する。
- `bunfig.toml` の `trustedDependencies = []` で、Bun がデフォルトで信頼する「top 500 npm パッケージ」の lifecycle script もゼロにする。
- `make before-commit` が走らせる `architecture-harness` が、Git URL 依存・lifecycle hook の濫用・IOC ファイル名・ロックファイル内の Git 解決を機械的に検出する（`INVARIANT_NO_GIT_DEPENDENCY` / `INVARIANT_LIFECYCLE_HOOK_SCOPED` / `INVARIANT_NO_KNOWN_IOC` / `INVARIANT_LOCKFILE_NO_GIT_RESOLUTION`）。
- CI は `safe-chain` + 上記設定で重ねる。
- `.npmrc` は **意図的に置かない**。Bun は読まないので Bun の防御には寄与せず、「効いていそうで効いていない」security theater になるため。本テンプレートは Bun 専用。pnpm/npm/yarn を併用する派生プロジェクトは自分で `.npmrc` を足す。

設計判断の正本は [ADR-0001](./docs/adr/0001-supply-chain-hardening.md)、invariant 一覧は [docs/architecture/harness.md](./docs/architecture/harness.md) を参照。

## 開発ガイドライン

[CLAUDE.md](./CLAUDE.md) を参照。
