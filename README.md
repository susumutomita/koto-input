# Koto

[![CI](https://github.com/susumutomita/koto-input/actions/workflows/ci.yml/badge.svg)](https://github.com/susumutomita/koto-input/actions/workflows/ci.yml)

Koto は、ローマ字・英語・日本語の混在テキストを自然な日本語へ変換する macOS 用入力メソッド。`Ctrl + Shift + 言語キー` を押すと、同じテキストを英語・中国語（簡体字）・韓国語・フランス語・ドイツ語・スペイン語へ翻訳変換する。変換に使う AI は macOS 組み込みのオンデバイスモデル（Apple Intelligence の FoundationModels framework）だけで、クラウドや外部の AI サービスには接続しない。Claude Code や Codex CLI は変換に使う AI ではなく「入力先」の例で、これらのターミナルアプリへ送信する前のテキストを composition バッファ内で変換する。

> Koto is an on-device AI input method for macOS. Type romaji anywhere, then convert it into natural Japanese — or into English and 5 other languages — using Apple Intelligence. No cloud, no logging.

入力例。

```text
kono authentication no sekinin han'i ga aimai dakara application layer dake de check suru noha abunai
```

変換例。

```text
この認証設計は責任範囲が曖昧なので、アプリケーション層だけでチェックするのは危険です。
```

同じ入力から `Ctrl + Shift + E` で英語へも変換できる。

```text
This authentication design has ambiguous responsibility boundaries, so checking only at the application layer is risky.
```

## なぜ Koto か

ターミナルで Claude Code や Codex CLI に指示を書くとき、従来の日本語 IME には不便が多い。スペースで変換候補が割り込み、Enter の確定がそのままプロンプト送信になり、技術用語やコマンド名が勝手にかな漢字へ変換される。Koto は変換・確定・送信を分離し、AI への指示を書く流れを壊さないことを最優先に設計した入力メソッド。変換は明示的なキー（`Shift + Space` など）を押したときだけ起き、`Claude Code` のような保護語やコマンド名は原文のまま残る。

Koto が目指すのは「IME を切り替えない」体験。日本語にする・英語で送る・別の言語へ訳す — これらはすべて「打ったテキストをどの形にするか」の選択であって、入力ソースの切替を要求すべきではない。Koto はその選択をキー 1 つで行える単一の入力レイヤーとして設計している。

## 特徴

- 変換はデバイス上で完結し、入力テキストを外部サービスへ送信しない。変換エンジンは Apple のオンデバイスモデルのみで、OpenAI / Codex 等の外部 AI は使わない。
- 変換と送信が分離しており、`Shift + Space` は変換だけを行う。
- `Ctrl + Shift + 言語キー` で 6 言語への翻訳変換ができる。打った場所にそのまま訳文が入る。
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

Homebrew を使う場合（[susumutomita/homebrew-tap](https://github.com/susumutomita/homebrew-tap) 経由）。

```bash
brew install --cask susumutomita/tap/koto
```

リリースは tag（`v*`）の push で `release` workflow が自動作成し、tap 側の `sync-cask` workflow が cask を最新リリースへ自動追従させる（最長 6 時間遅延。詳細は [ADR-0014](./docs/adr/0014-homebrew-配布は公開-tap-リポジトリ経由.md)）。署名・公証は secrets（Developer ID 証明書と App Store Connect API キー）を設定した場合のみ行われ、未設定のリリースは Gatekeeper にブロックされるため `xattr -dr com.apple.quarantine ~/Library/Input\ Methods/Koto.app` を実行するか、ソースビルドを使う。

配置後の手順。

1. システム設定 > キーボード > 入力ソース > 編集 > + ボタンを押す。
2. 「日本語」から「Koto」を追加する。一覧に出ない場合は一度ログアウトして再ログインする。
3. メニューバーの入力ソースで Koto を選択する。

アンインストールは入力ソースから Koto を外し、Homebrew 経由なら `brew uninstall --cask koto`、ソースビルドなら `~/Library/Input Methods/Koto.app` をゴミ箱へ移す。

## キー操作

| キー | 動作 |
|------|------|
| `Shift + Space` | AI 変換を要求する（日本語） |
| `Ctrl + Shift + E` | 英語へ AI 変換する |
| `Ctrl + Shift + C` | 中国語（簡体字）へ AI 変換する |
| `Ctrl + Shift + K` | 韓国語へ AI 変換する |
| `Ctrl + Shift + F` | フランス語へ AI 変換する |
| `Ctrl + Shift + G` | ドイツ語へ AI 変換する |
| `Ctrl + Shift + S` | スペイン語へ AI 変換する |
| `Ctrl + Shift + Space` | セッション内文脈つきで日本語へ AI 変換する（`contextMemoryEnabled` が true のときだけ。false の間はキーを消費せずアプリへ通す） |
| `Tab` | ローマ字をその場でひらがなにし、連打でひらがな ⇄ カタカナを巡回する（AI 不要・即時） |
| `↑` / `↓` | 変換後に、これまでに生成した候補（日本語・各言語）を切り替える |
| `Escape` | 変換のキャンセル、または変換前テキストの復元 |
| `Enter` | composition の確定（送信はしない） |
| `Control + Enter` | composition 内に改行を挿入する |

Enter は確定だけを行う。Claude Code / Codex へプロンプトを送信するのは、確定後にもう一度押す Enter。

変換結果が気に入らない場合、編集せずにもう一度同じ変換キーを押すと別候補を再抽選する（初回は決定的、2 回目以降は揺らぎあり）。変換後に別の言語キーを押せばその言語へ変換し直し、`Shift + Space` で日本語へ戻せる。再抽選・言語切替で生成した候補は捨てられず、`↑` / `↓` で見比べて選び直せる。`Escape` を押せば何回再変換した後でも元のローマ字へ戻る。`↑` / `↓` は候補が 2 件以上あるときだけ Koto が消費し、それ以外はアプリへ通す。

言語キーは入力中（composition がある間）だけ Koto が消費する。composition が無いときはアプリへそのまま通すため、ターミナルのショートカットを奪わない。ただし VS Code 統合ターミナル等では入力中でもアプリ側が `Ctrl + Shift + E`（エクスプローラー）などを先取りする場合がある。その場合はアプリ側のキーバインド変更で回避する（既知の衝突は `docs/terminal-compatibility.md` を参照）。

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
| `style` | `neutral` / `polite` / `plain`（日本語変換のみに適用） |
| `customInstruction` | 追加の変換指示テキスト（日本語変換のみに適用） |
| `protectedTerms` | 出力に原文どおり残す語の配列（翻訳にも適用） |
| `maximumExpansionRatio` | 出力長の上限倍率（デフォルト 4.0） |
| `outputProfile` | `neutral` / `polite` / `business` / `casual` / `technical`（翻訳のトーン。日本語変換には適用しない） |
| `outputPreset` | `standard` / `chat` / `email` / `codeReview` / `agentPrompt`（用途別のトーンと指示の束。`appAwarePresetsEnabled` が true のときだけ有効） |
| `appAwarePresetsEnabled` | プリセット適用の総スイッチ（デフォルト false。false なら `outputProfile` をそのまま使う） |
| `contextMemoryEnabled` | セッション内文脈メモリの総スイッチ（デフォルト false）。true にすると commit したテキストの直近 5 件（計 500 文字以内）を in-memory で保持し、`Ctrl + Shift + Space` の文脈つき日本語変換で参照する |

設定 JSON に typo があると設定全体がデフォルトへフォールバックする（エラーは出ない）。`Ctrl + Shift + Space` が反応しないときは、まず `defaults read com.susumutomita.inputmethod.Koto conversionSettings` で `contextMemoryEnabled` が true で保存されているかを確認する。それでも反応しない場合は、アプリ側が同じキーを先取りしている可能性がある（JetBrains 系 IDE の Smart Type Completion 等。`docs/terminal-compatibility.md` を参照）。

## プライバシー

- 変換は Apple Foundation Models（オンデバイス）のみで行い、クラウドフォールバックを持たない（[ADR-0002](./docs/adr/0002-apple-foundation-models-をオンデバイス変換プロバイダに採用.md)）。
- 入力テキストと変換結果をログに残さない。
- アナリティクスを持たない。
- セッション内文脈メモリ（[ADR-0013](./docs/adr/0013-ローカル文脈メモリは-opt-in-のセッション内記憶から始める.md)）はデフォルトで OFF。有効化しても文脈はデバイスから出ず、プロンプト構築にのみ使う。
- 文脈メモリを OFF へ切り替えると、次のテキスト確定または AI 変換要求の時点で保持済みの文脈は全消去される。
- 文脈メモリはディスクへ永続化せず、Koto の再起動で消える。
- パスワード欄では macOS が IME を無効化するため、セキュアフィールドへの入力は収集されない。

## 既知の制限

- Apple Intelligence が無効な環境では変換できない。その場合も元テキストは保持される。
- 翻訳の初回変換は日本語より待ち時間が長い場合がある（prewarm は日本語のみ）。速度を出している設計は [docs/performance.md](./docs/performance.md) を参照。
- ターミナルごとの互換性検証の状況は [docs/terminal-compatibility.md](./docs/terminal-compatibility.md) を参照。
- 変換中の表示は marked text の下線のみで、スピナーや通知は出ない。
- ローマ字として最後まで解釈できる小文字の英単語（例: `sudo` → すど）はかな化される。`protectedTerms` への登録で防げる。
- 短い入力を文脈で大きく展開した出力は、出力長の検証（`maximumExpansionRatio`、デフォルト 4.0 倍）で拒否されることがある。文脈つき変換で展開を多用する場合は値を上げて調整する。
- 文脈メモリを OFF へ切り替えた後、一度も確定・AI 変換をせずに ON へ戻すと、切替前の文脈が残ったままになる（消去は OFF 後の最初の確定・変換要求の時点のため）。確実に消すには OFF のまま任意のテキストを一度確定するか、Koto を再起動する。

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

このリポジトリは Shai-Hulud 系（[Flatt Security の解説](https://blog.flatt.tech/entry/mini_shai_hulud_2nd)）のサプライチェイン攻撃を多層で防ぐデフォルト値を持つ。

- `make install` / `make install_ci` は常に `--ignore-scripts` を付ける。**Bun は `.npmrc` の `ignore-scripts` も `npm_config_ignore_scripts` 環境変数も読まない**（公式 docs では `bunfig.toml` のみが設定経路）ため、Bun を叩くコマンド側で毎回明示する必要がある。husky の `prepare` も巻き添えで止まるので `make setup-hooks` で明示的に opt-in する。
- `bunfig.toml` の `trustedDependencies = []` で、Bun がデフォルトで信頼する「top 500 npm パッケージ」の lifecycle script もゼロにする。
- `make before-commit` が走らせる `architecture-harness` が、Git URL 依存・lifecycle hook の濫用・IOC ファイル名・ロックファイル内の Git 解決を機械的に検出する（`INVARIANT_NO_GIT_DEPENDENCY` / `INVARIANT_LIFECYCLE_HOOK_SCOPED` / `INVARIANT_NO_KNOWN_IOC` / `INVARIANT_LOCKFILE_NO_GIT_RESOLUTION`）。
- CI は `safe-chain` + 上記設定で重ねる。
- `.npmrc` は **意図的に置かない**。Bun は読まないので Bun の防御には寄与せず、「効いていそうで効いていない」security theater になるため。このリポジトリの開発ツールは Bun 専用。pnpm/npm/yarn を併用する場合は自分で `.npmrc` を足す。

設計判断の正本は [ADR-0001](./docs/adr/0001-supply-chain-hardening.md)、invariant 一覧は [docs/architecture/harness.md](./docs/architecture/harness.md) を参照。

## 開発ガイドライン

[CLAUDE.md](./CLAUDE.md) を参照。
