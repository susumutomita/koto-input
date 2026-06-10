# Koto の Homebrew cask。
#
# 使い方（tap を作るまでの暫定）:
#   brew install --cask ./Casks/koto.rb
#
# リリースごとの更新手順:
#   1. version をリリースタグ（v なし）に合わせる
#   2. sha256 を GitHub Releases の Koto-v<version>.zip.sha256 の値にする
#
# 注意: 署名・公証済みのリリースが無い場合、Gatekeeper にブロックされる。
# その場合はソースから `make ime-install` でビルドする。
cask "koto" do
  version "0.1.0"
  sha256 :no_check # リリース添付の .sha256 の値に置き換える

  url "https://github.com/susumutomita/koto-input/releases/download/v#{version}/Koto-v#{version}.zip"
  name "Koto"
  desc "On-device AI Japanese input method powered by Apple Intelligence"
  homepage "https://github.com/susumutomita/koto-input"

  artifact "Koto.app", target: "~/Library/Input Methods/Koto.app"

  caveats <<~EOS
    インストール後の手順:
      1. 一度ログアウトして再ログインする（入力メソッドの再走査のため）
      2. システム設定 > キーボード > 入力ソース > 編集 > + ボタン
      3. 「日本語」から Koto を追加する

    必要環境: macOS 26 以降 / Apple Silicon / Apple Intelligence 有効
  EOS
end
