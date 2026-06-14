#!/usr/bin/env python3
"""mozc dictionary_oss の全辞書と連接行列を、koto-input が同梱する 2 つの
コンパクトバイナリ（raw DEFLATE 圧縮）へコンパイルする。

入力（同一ディレクトリに配置、build-dictionary.sh が取得）:
  - dictionary-all.txt : dictionary00-09 を連結したもの
      形式: reading \t left_id \t right_id \t cost \t surface
  - connection_single_column.txt : 1 行目 N、以降 N*N の連接コスト（row-major）
出力（--out で指定したディレクトリ、既定は KotoCore の Resources）:
  - connection.bin : DEFLATE( u32 N | (N*N) u16 cost )  ※index = rid*N + lid
  - dictionary.bin : DEFLATE( header | readingRecords | entries | readingBlob | surfaceBlob )

決定性: reading は code point 昇順（= hiragana の UTF-8 バイト順）で整列する。
同一 reading 内の entries は cost 昇順 → surface code point 順で整列する
（Swift 側 LatticeConverter が候補順序を一意化するのと揃える）。No Mock: 実 mozc
データのみを使う。スタブ・捏造エントリは作らない。
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.normpath(
    os.path.join(HERE, "..", "..", "Packages", "KotoCore", "Sources", "Resources")
)
MAGIC = 0x4B4F544F  # 'KOTO'


def raw_deflate(data: bytes) -> bytes:
    # wbits=-15 で raw DEFLATE（zlib/gzip ヘッダなし）。Swift の
    # NSData.decompressed(using: .zlib)（COMPRESSION_ZLIB = raw DEFLATE）と対称。
    comp = zlib.compressobj(level=9, wbits=-15)
    return comp.compress(data) + comp.flush()


def build_connection(src_path: str, out_path: str) -> int:
    with open(src_path, "r", encoding="utf-8") as f:
        n = int(f.readline().strip())
        costs = bytearray()
        count = 0
        for line in f:
            line = line.strip()
            if line == "":
                continue
            v = int(line)
            if v < 0 or v > 0xFFFF:
                raise ValueError(f"連接コストが u16 範囲外: {v}")
            costs += struct.pack("<H", v)
            count += 1
    if count != n * n:
        raise ValueError(f"連接コスト数 {count} != N*N {n * n}")
    payload = struct.pack("<I", n) + bytes(costs)
    with open(out_path, "wb") as f:
        f.write(raw_deflate(payload))
    return n


def build_dictionary(src_path: str, out_path: str, num_pos: int) -> tuple:
    # reading -> list[(cost, surface, lid, rid)]
    by_reading = {}
    total = 0
    with open(src_path, "r", encoding="utf-8") as f:
        for raw in f:
            parts = raw.rstrip("\n").split("\t")
            if len(parts) != 5:
                continue
            reading, lid_s, rid_s, cost_s, surface = parts
            if reading == "" or surface == "":
                continue
            try:
                lid = int(lid_s)
                rid = int(rid_s)
                cost = int(cost_s)
            except ValueError:
                continue
            if not (0 <= lid < num_pos and 0 <= rid < num_pos):
                continue
            if not (0 <= cost <= 0xFFFF):
                continue
            by_reading.setdefault(reading, []).append((cost, surface, lid, rid))
            total += 1

    readings = sorted(by_reading.keys())  # code point 昇順 = UTF-8 バイト順

    # 文字列プール（dedup）。
    reading_blob = bytearray()
    reading_off = {}

    def intern_reading(s: str) -> tuple:
        b = s.encode("utf-8")
        if s in reading_off:
            return reading_off[s], len(b)
        off = len(reading_blob)
        reading_blob.extend(b)
        reading_off[s] = off
        return off, len(b)

    surface_blob = bytearray()
    surface_off = {}

    def intern_surface(s: str) -> tuple:
        b = s.encode("utf-8")
        if s in surface_off:
            return surface_off[s], len(b)
        off = len(surface_blob)
        surface_blob.extend(b)
        surface_off[s] = off
        return off, len(b)

    reading_records = bytearray()  # u32 rOff | u16 rLen | u32 firstEntry | u16 entryCount
    entries = bytearray()  # u32 sOff | u16 sLen | u16 lid | u16 rid | u16 cost
    entry_index = 0

    for reading in readings:
        cand = by_reading[reading]
        # 同一 surface は最小 cost に畳む（別 POS 由来の重複を一意化）。
        best = {}
        meta = {}
        for cost, surface, lid, rid in cand:
            if surface not in best or cost < best[surface]:
                best[surface] = cost
                meta[surface] = (lid, rid)
        merged = [(best[s], s, meta[s][0], meta[s][1]) for s in best]
        # cost 昇順 → surface code point 順で決定的に整列。
        merged.sort(key=lambda e: (e[0], e[1]))

        r_off, r_len = intern_reading(reading)
        first = entry_index
        for cost, surface, lid, rid in merged:
            s_off, s_len = intern_surface(surface)
            entries += struct.pack("<IHHHH", s_off, s_len, lid, rid, cost)
            entry_index += 1
        reading_records += struct.pack(
            "<IHIH", r_off, r_len, first, len(merged)
        )

    header = struct.pack(
        "<IIIII",
        MAGIC,
        len(readings),
        entry_index,
        len(reading_blob),
        len(surface_blob),
    )
    payload = (
        header
        + bytes(reading_records)
        + bytes(entries)
        + bytes(reading_blob)
        + bytes(surface_blob)
    )
    with open(out_path, "wb") as f:
        f.write(raw_deflate(payload))
    return len(readings), entry_index, len(payload)


def main():
    data_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mozc-data"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT
    os.makedirs(out_dir, exist_ok=True)

    conn_src = os.path.join(data_dir, "connection_single_column.txt")
    dict_src = os.path.join(data_dir, "dictionary-all.txt")
    conn_out = os.path.join(out_dir, "connection.bin")
    dict_out = os.path.join(out_dir, "dictionary.bin")

    print(f"連接行列をコンパイル: {conn_src}", flush=True)
    n = build_connection(conn_src, conn_out)
    print(f"  N={n}  -> {conn_out} ({os.path.getsize(conn_out):,} bytes 圧縮後)")

    print(f"辞書をコンパイル: {dict_src}", flush=True)
    readings, entries, raw_len = build_dictionary(dict_src, dict_out, n)
    print(
        f"  readings={readings:,} entries={entries:,} 展開後={raw_len:,}B "
        f"-> {dict_out} ({os.path.getsize(dict_out):,} bytes 圧縮後)"
    )


if __name__ == "__main__":
    main()
