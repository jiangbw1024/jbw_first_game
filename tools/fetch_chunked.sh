#!/bin/bash
# ============================================================
# 分片并发下载（通用版，幂等，可重复运行）
# 用法： ./fetch_chunked.sh <URL> <总字节数> <输出文件路径>
#
# 为什么需要它：
#   本机对"单连接"限速约 30KB/s，但限速是按连接算的。
#   切成 2MB 分片、开 N 条连接，聚合能到 800KB/s 以上。
#
# 两个必须记住的实现细节（都是踩过的坑）：
#   1. 每片都要从"已下字节"处续传（-r start+have-end 且用 >> 追加）。
#      连接平均每 1MB 就被掐断，若每次从头重写，进度永远归零。
#   2. 用显式批次 + wait 调度，不要用 xargs -P ——
#      实测它在高并发下会提前丢掉任务（82 片只发了 63 片）。
# ============================================================
set -uo pipefail

URL="${1:?用法: fetch_chunked.sh <URL> <TOTAL> <OUT>}"
TOTAL="${2:?缺少总字节数}"
OUT="${3:?缺少输出路径}"
MIRROR="https://gh-proxy.com/$URL"
CHUNK=$((2 * 1024 * 1024))
PARALLEL=12

OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
PART_DIR="$OUT_DIR/.parts_$(basename "$OUT")"
N=$(((TOTAL + CHUNK - 1) / CHUNK))

mkdir -p "$PART_DIR"

part_path() { printf "%s/part_%03d" "$PART_DIR" "$1"; }
part_want() {
  local start=$(($1 * CHUNK)) end=$(($1 * CHUNK + CHUNK - 1))
  [ $end -ge $TOTAL ] && end=$((TOTAL - 1))
  echo $((end - start + 1))
}
part_ok() {
  local f; f="$(part_path "$1")"
  [ -f "$f" ] && [ "$(wc -c < "$f" | tr -d ' ')" = "$(part_want "$1")" ]
}

fetch_one() {
  local i=$1
  local start=$((i * CHUNK)) end=$((i * CHUNK + CHUNK - 1))
  [ $end -ge $TOTAL ] && end=$((TOTAL - 1))
  local f want have url attempt
  f="$(part_path "$i")"
  want="$(part_want "$i")"
  touch "$f"
  attempt=0
  while :; do
    have=$(wc -c < "$f" | tr -d ' ')
    [ "$have" = "$want" ] && return 0
    if [ "$have" -gt "$want" ]; then
      head -c "$want" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      have=$want
    fi
    attempt=$((attempt + 1))
    [ $attempt -gt 12 ] && break
    if [ $attempt -le 8 ]; then url="$URL"; else url="$MIRROR"; fi
    curl -sL --max-time 120 -r "$((start + have))-$end" "$url" >> "$f" 2>/dev/null
  done
  echo "!! 分片 $i 失败" >&2
  return 1
}

# ★ 注意 ${PARALLEL} 的花括号：中文标点是多字节的，紧跟在 $变量 后面时
#   bash 会把它当成变量名的一部分（$PARALLEL， → 找名为 "PARALLEL，总计" 的变量），
#   配合 set -u 直接报 unbound variable 退出。所有"变量后面紧跟中文"的地方都要加 {}
echo "共 ${N} 片，每片 $((CHUNK / 1024 / 1024))MB，并发 ${PARALLEL}，总计 $((TOTAL / 1024 / 1024))MB"

idx=0
fail=0
while [ $idx -lt $N ]; do
  pids=()
  k=0
  while [ $k -lt $PARALLEL ] && [ $idx -lt $N ]; do
    fetch_one "$idx" &
    pids+=($!)
    idx=$((idx + 1))
    k=$((k + 1))
  done
  for p in "${pids[@]}"; do
    wait "$p" || fail=1
  done
  echo "  批次完成，进度 $(ls "$PART_DIR" | wc -l | tr -d ' ')/$N"
done

[ $fail -ne 0 ] && echo "有分片失败，重跑本脚本会自动补下"

i=0
while [ $i -lt $N ]; do
  part_ok "$i" || { echo "缺少或不完整的分片 ${i}，请重跑"; exit 1; }
  i=$((i + 1))
done

: > "$OUT"
i=0
while [ $i -lt $N ]; do
  cat "$(part_path "$i")" >> "$OUT"
  i=$((i + 1))
done

GOT=$(wc -c < "$OUT" | tr -d ' ')
echo "拼接完成：$GOT 字节（应为 ${TOTAL}）"
[ "$GOT" = "$TOTAL" ] || { echo "大小不符，请重跑"; exit 1; }

if unzip -tqq "$OUT" >/dev/null 2>&1; then
  echo "✓ zip 完整性校验通过"
else
  echo "✗ zip 损坏，请重跑"
  exit 1
fi

rm -rf "$PART_DIR"
echo "✓ 下载完成：$OUT"
