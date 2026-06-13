#!/bin/zsh
# mozc dictionary_oss から、かな漢字変換 MVP 用の高頻度サブセットを生成する。
#
# 出典: https://github.com/google/mozc (src/data/dictionary_oss/, BSD-3-Clause)
# 生データ形式（TSV）: reading \t left_id \t right_id \t cost \t surface
#   - reading: 読み（ひらがな等）
#   - left_id / right_id: 連接 ID（POS は id.def で引ける）
#   - cost: 単語生起コスト。小さいほど高頻度・優先。
#   - surface: 表記。
#
# 生成物: dictionary-subset.tsv（reading \t surface \t cost、reading 昇順→cost 昇順）
#   SwiftPM リソースとして KotoCore に同梱し、DictionaryConverter が読む。
#
# サブセットのフィルタ基準（silent な打ち切りにしない・実装内に明記）:
#   1. POS（left_id）が内容語のみ:
#        1851 名詞,一般 / 1841 名詞,サ変接続 / 1909 名詞,副詞可能 /
#        1931 名詞,形容動詞語幹 / 12 副詞,一般
#      固有名詞・助詞・助動詞・活用語尾などは MVP では除外する。
#      （単一最良パスの最長一致変換に最も効く content word に絞る。）
#   2. 読みがひらがな（U+3041-309F）と長音符（ー, U+30FC）のみ。
#      カタカナ読み・記号混じりは除外する。
#   3. cost <= COST_THRESHOLD（既定 4500）。高頻度語に限定して配布サイズを抑える。
#   4. surface != reading（かなと同じ表記の no-op エントリは捨てる）。
#   5. 読み長 >= 2 文字（単一かなの低コストノイズを除く）。
#   6. 1 読みあたりの代替表記は最大 MAX_ALTERNATIVES（既定 8）件まで
#      （cost 昇順で上位のみ。候補プールの肥大を防ぐ）。
#
# 決定性: reading 昇順、同 reading 内は cost 昇順 → surface のコード順で安定ソート。
set -euo pipefail

COST_THRESHOLD="${COST_THRESHOLD:-4500}"
MAX_ALTERNATIVES="${MAX_ALTERNATIVES:-8}"
SCRIPT_DIR="${0:A:h}"
OUT="${SCRIPT_DIR}/../../Packages/KotoCore/Sources/Resources/dictionary-subset.tsv"
WORK="$(mktemp -d)"
BASE_URL="https://raw.githubusercontent.com/google/mozc/master/src/data/dictionary_oss"

echo "[build-subset] downloading mozc dictionary_oss (dictionary00-09) ..."
for i in 00 01 02 03 04 05 06 07 08 09; do
  curl -fsSL "${BASE_URL}/dictionary${i}.txt" -o "${WORK}/dictionary${i}.txt"
done
cat "${WORK}"/dictionary0*.txt > "${WORK}/all.txt"
TOTAL=$(wc -l < "${WORK}/all.txt" | tr -d ' ')
echo "[build-subset] total raw entries: ${TOTAL}"

# 1) POS フィルタ + cost 閾値 + surface!=reading（POS / コスト / no-op を一括判定）。
awk -F'\t' -v t="${COST_THRESHOLD}" '
  ($2==1851 || $2==1841 || $2==1909 || $2==1931 || $2==12) && $4 <= t && $5 != $1 {
    print $1 "\t" $5 "\t" $4
  }
' "${WORK}/all.txt" > "${WORK}/pos_cost.txt"

# 2) 読みがひらがな + 長音符のみ、かつ読み長 >= 2。Perl で Unicode 安全に。
perl -CSD -ne '
  my @f = split /\t/;
  my $r = $f[0];
  next unless $r =~ /^[\x{3041}-\x{309F}\x{30FC}]+$/;
  next if length($r) < 2;
  print;
' "${WORK}/pos_cost.txt" > "${WORK}/kana.txt"

# 3a) (reading, surface) の重複を除去し、最小 cost を残す。生データは複数の
#     dictionary ファイルにまたがって同じ (reading, surface) を持つことがある。
LC_ALL=C sort -t$'\t' -k1,1 -k2,2 -k3,3n "${WORK}/kana.txt" \
  | awk -F'\t' '{ key=$1 "\t" $2; if (key != prev) { print; prev=key } }' \
  > "${WORK}/dedup.txt"

# 3b) 安定ソート: reading 昇順 → cost 昇順 → surface 順。
LC_ALL=C sort -t$'\t' -k1,1 -k3,3n -k2,2 "${WORK}/dedup.txt" > "${WORK}/sorted.txt"

# 4) 1 読みあたり最大 MAX_ALTERNATIVES 件（cost 昇順で上位）。
awk -F'\t' -v maxn="${MAX_ALTERNATIVES}" '
  { if ($1 != prev) { prev=$1; n=0 } n++; if (n <= maxn) print }
' "${WORK}/sorted.txt" > "${OUT}"

ENTRIES=$(wc -l < "${OUT}" | tr -d ' ')
READINGS=$(cut -f1 "${OUT}" | uniq | wc -l | tr -d ' ')
BYTES=$(wc -c < "${OUT}" | tr -d ' ')
echo "[build-subset] wrote ${OUT}"
echo "[build-subset] entries=${ENTRIES} unique_readings=${READINGS} bytes=${BYTES}"
echo "[build-subset] filter: POS in {1851,1841,1909,1931,12}, cost<=${COST_THRESHOLD}, hiragana-only reading (len>=2), surface!=reading, <=${MAX_ALTERNATIVES} alts/reading"
