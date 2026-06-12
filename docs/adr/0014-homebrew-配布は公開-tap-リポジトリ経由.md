# ADR-0014: Homebrew 配布は公開 tap リポジトリ経由にする

- **Status**: Accepted
- **Date**: 2026-06-13
- **Deciders**: susumutomita

## Context

これまで Homebrew でのインストールは、リポジトリ内の `Casks/koto.rb` をパス指定で渡す `brew install --cask ./Casks/koto.rb` を案内していた（cask ファイル自身に「tap を作るまでの暫定」と明記）。現行の Homebrew はパス指定の cask インストールを廃止しており、この手順は「Homebrew requires casks to be in a tap」エラーで失敗する。また cask の `version` / `sha256` は手動更新が前提で、実際には v1.0.1 リリース後も `0.1.0` / `:no_check` のまま停滞していた。配布経路として、cask を tap（git リポジトリ）に置くことが必須になった。

## Decision

公開 tap リポジトリ [susumutomita/homebrew-tap](https://github.com/susumutomita/homebrew-tap) を cask の正本とし、koto-input 側の `Casks/koto.rb` は削除する。インストール手順は `brew install --cask susumutomita/tap/koto` になる。

cask の `version` / `sha256` の追従は、tap 側の `sync-cask` ワークフロー（6 時間ごとの cron + `workflow_dispatch`）が koto-input の最新リリースを公開 API で照会し、tap 自身の `GITHUB_TOKEN` で commit する方式にする。次の選択肢と比較した。

1. koto-input の release ワークフローから tap へ push する — cross-repo 書き込み用の PAT が必要になり、秘密の管理対象が増える。
2. koto-input リポジトリ自体を tap として `brew tap` させる — ソース全体の clone を全ユーザーに強いる上、cask とソースのライフサイクルが混在する。
3. tap 側の polling 自動更新（採用）— 追加の秘密が不要で、tap が自身の責務（cask の鮮度）を自己完結で持つ。

GitHub Actions の SHA ピン留めは [ADR-0001](./0001-supply-chain-hardening.md) に従い、tap 側ワークフローも koto-input と同じ commit SHA の `actions/checkout` を使う。

## Consequences

- **Good**: 現行 Homebrew でインストールできる。cask の version / sha256 がリリースへ自動追従し、手動更新の停滞が構造的に再発しない。cross-repo PAT を持たない。
- **Bad**: リリースが cask に反映されるまで最長 6 時間の遅延がある（急ぐ場合は tap 側の `workflow_dispatch` を手動実行する）。管理対象リポジトリが 2 つになる。
- **Tradeoff**: release ワークフローからの即時 push（選択肢 1）を捨てた。リリース頻度が上がり遅延が実害になったら、`repository_dispatch` + fine-grained PAT での即時通知を新しい ADR で再検討する。

## References

- 関連リポジトリ: https://github.com/susumutomita/homebrew-tap
- 関連コード: `.github/workflows/release.yml`（リリース作成側）
- 関連 ADR: [ADR-0001](./0001-supply-chain-hardening.md)
- フォローアップ: `01KTX3RSR6FXJ5GFTGFBJS3T2G`（.claude/state/follow-ups.jsonl）
