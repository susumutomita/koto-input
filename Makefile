# 引数なしの `make` はヘルプを表示する（誤って install 等が走らないように）。
.DEFAULT_GOAL := help

.PHONY: help
help: ## このヘルプを表示する
	@echo "Koto - オンデバイス AI 日本語入力メソッド"
	@echo ""
	@echo "使い方: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: install
# --ignore-scripts: Mini Shai-Hulud 2nd (Flatt Security, 2026-05-12) を含む
# lifecycle script 系サプライチェイン攻撃を一段目で封じるフラグ。
# Bun は npm_config_ignore_scripts 環境変数も .npmrc の ignore-scripts も読まないため
# (公式 docs では bunfig.toml のみが設定経路)、Bun を叩く側で毎回明示する必要がある。
# Bun はデフォルトで「top 500 npm パッケージ」の lifecycle script を暗黙信頼する
# 仕様もあるため、ここで全停止させる方が事故が少ない。Husky の prepare も巻き添えで
# 止まるので、フックを使う場合は make setup-hooks で明示的に再有効化する。
install: ## 開発ツールの依存をインストールする (--ignore-scripts)
	bun install --ignore-scripts

.PHONY: install_ci
install_ci: ## CI 用インストール (--frozen-lockfile --ignore-scripts)
	bun install --frozen-lockfile --ignore-scripts

.PHONY: setup-hooks
# install 時に --ignore-scripts で止めた husky の prepare をここで明示的に走らせる。
# `bun run prepare` は package.json の "prepare": "husky" を叩くため、Husky 一発で済む。
setup-hooks: ## Husky の Git hooks を有効化する
	bun run prepare

.PHONY: lint
lint: ## biome check を実行する
	bun run lint

.PHONY: lint_fix
lint_fix: ## biome check --write で自動修正する
	bun run lint:fix

.PHONY: lint_text
lint_text: ## textlint で README を検査する
	bun run lint:text

.PHONY: format
format: ## biome format --write で整形する
	bun run format

.PHONY: format_check
format_check: ## biome format で整形差分を確認する
	bun run format:check

.PHONY: architecture_harness
architecture_harness: ## ステージ済み変更の invariant 違反を検査する
	bun scripts/architecture-harness.ts --staged --fail-on=error

.PHONY: before-commit
# Swift のビルド・テストは toolchain の無い環境 (Linux コンテナ等) では実行
# できないため既定ゲートに含めない。CI の swift ジョブが必ず実行する。
before-commit: architecture_harness lint_text lint ## コミット前ゲート一括 (harness + textlint + biome)

# --- Koto 入力メソッド (Swift) ---
# Linux 等 Swift toolchain の無い環境では実行できない。CI の macOS ジョブが
# swift build / swift test を担う (docs/architecture.md)。

.PHONY: build
build: swift-build ## swift-build のエイリアス

.PHONY: test
test: swift-test ## swift-test のエイリアス

.PHONY: swift-build
swift-build: ## Swift 全ターゲットをビルドする (要 macOS / Swift toolchain)
	swift build --package-path KotoInput

.PHONY: swift-test
swift-test: ## Swift テストを実行する (要 macOS / Swift toolchain)
	swift test --package-path KotoInput

.PHONY: ime-build
ime-build: ## build/Koto.app を組み立てる (要 macOS)
	bash scripts/build-koto-app.sh

.PHONY: ime-install
ime-install: ## Koto.app をビルドして ~/Library/Input Methods へ配置する (要 macOS)
	bash scripts/build-koto-app.sh --install
