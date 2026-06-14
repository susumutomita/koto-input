#!/usr/bin/env bash
# mozc dictionary_oss（BSD-3-Clause）の全辞書と連接行列を取得し、koto-input が
# 同梱する 2 つのコンパクトバイナリ（dictionary.bin / connection.bin、raw DEFLATE
# 圧縮）へコンパイルする（ADR-0016）。同梱バイナリはリポジトリにコミット済みで、
# 通常の swift build では再生成不要。辞書を更新するときだけ本スクリプトを回す。
#
# 出力先: KotoInput/Packages/KotoCore/Sources/Resources/{dictionary,connection}.bin
# 帰属: リポジトリ直下 THIRD-PARTY-LICENSES。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$HERE/../../Packages/KotoCore/Sources/Resources" && pwd)"
BASE="https://raw.githubusercontent.com/google/mozc/master/src/data/dictionary_oss"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "mozc dictionary_oss を取得: $BASE"
: > "$WORK/dictionary-all.txt"
for n in 00 01 02 03 04 05 06 07 08 09; do
  echo "  dictionary${n}.txt"
  curl -fsSL "$BASE/dictionary${n}.txt" >> "$WORK/dictionary-all.txt"
done
echo "  connection_single_column.txt"
curl -fsSL "$BASE/connection_single_column.txt" > "$WORK/connection_single_column.txt"
echo "  id.def"
curl -fsSL "$BASE/id.def" > "$WORK/id.def"

echo "コンパイル -> $RES"
python3 "$HERE/build-dictionary.py" "$WORK" "$RES"

echo "完了。git status で dictionary.bin / connection.bin の差分を確認し、コミットする。"
