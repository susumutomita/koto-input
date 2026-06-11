#!/usr/bin/env bash
# Koto.app を SwiftPM のビルド成果物から組み立てる（ADR-0003）。
# Xcode プロジェクトを持たないため、入力メソッドの .app バンドルをここで作る。
#
# 使い方:
#   scripts/build-koto-app.sh            # build/Koto.app を組み立てる
#   scripts/build-koto-app.sh --install  # ~/Library/Input Methods へ配置する
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "このスクリプトは macOS でのみ実行できます。" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="$ROOT/KotoInput"
APP_DIR="$ROOT/build/Koto.app"

echo "==> swift build (release)"
swift build -c release --package-path "$PACKAGE_PATH" --product KotoInputMethod
BIN_PATH="$(swift build -c release --package-path "$PACKAGE_PATH" --show-bin-path)"

echo "==> ${APP_DIR} を組み立て"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH/KotoInputMethod" "$APP_DIR/Contents/MacOS/KotoInputMethod"
cp "$PACKAGE_PATH/Apps/KotoInputMethod/Info.plist" "$APP_DIR/Contents/Info.plist"

# 署名。KOTO_CODESIGN_IDENTITY が設定されていれば Developer ID で
# hardened runtime 付き署名（配布用、release workflow が設定する）。
# 未設定なら ad-hoc 署名（Apple Silicon のローカル実行に必要）。
if [[ -n "${KOTO_CODESIGN_IDENTITY:-}" ]]; then
  echo "==> Developer ID 署名: $KOTO_CODESIGN_IDENTITY"
  codesign --force --deep --timestamp --options runtime \
    --sign "$KOTO_CODESIGN_IDENTITY" "$APP_DIR"
else
  echo "==> ad-hoc 署名"
  codesign --force --deep --sign - "$APP_DIR"
fi

if [[ "${1:-}" == "--install" ]]; then
  TARGET="$HOME/Library/Input Methods/Koto.app"
  echo "==> ${TARGET} へ配置"
  mkdir -p "$HOME/Library/Input Methods"
  ditto "$APP_DIR" "$TARGET"
  # 既存プロセスを止めて再読み込みさせる（未起動なら何もしない）。
  pkill -f "Koto.app/Contents/MacOS/KotoInputMethod" 2>/dev/null || true
  cat <<'GUIDE'

インストールしました。次の手順で有効化してください。
1. システム設定 > キーボード > 入力ソース > 編集 > + ボタン
2. 「日本語」から「Koto」を追加（一覧に出ない場合は一度ログアウト/ログイン）
3. メニューバーの入力ソースから Koto を選択
GUIDE
else
  # 変数の直後に全角文字を続けると bash が変数名の境界を誤判定して
  # unbound variable になる（v1.0.0 の release 失敗の原因）。必ず ${} で囲む。
  echo "完了: ${APP_DIR}（インストールするには --install を付けて再実行）"
fi
