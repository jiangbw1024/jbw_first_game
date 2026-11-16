#!/bin/bash
# ============================================================
# 分片并发下载 Godot 引擎（幂等，可重复运行）
# ------------------------------------------------------------
# 为什么不用普通 curl？
#   实测本机网络对"单连接"限速在 30KB/s 左右，170MB 要爬一个多小时。
#   限速是按连接算的 —— 开 24 条连接后聚合到 850KB/s，快 28 倍。
#
# 为什么不用 xargs -P？
#   实测 xargs 在高并发下会把任务列表"提前丢掉"（82 个只发了 63 个），
#   所以改成显式的批次 + wait，调度完全可控。
#
# 为什么幂等？
#   中断后重跑不会从头再来，只补缺失的分片。
# ============================================================
set -uo pipefail

URL="https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_macos.universal.zip"
MIRROR="https://gh-proxy.com/$URL"
TOTAL=170622178
CHUNK=$((2 * 1024 * 1024))
PARALLEL=24

OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
PART_DIR="$OUT_DIR/.parts"
ZIP="$OUT_DIR/godot.zip"
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
    # 防御：若某次多写了字节（不该发生），截回正确长度，避免拼装时错位
    if [ "$have" -gt "$want" ]; then
      head -c "$want" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      have=$want
    fi
    attempt=$((attempt + 1))
    [ $attempt -gt 12 ] && break
    # 前 8 次走官方源，之后换镜像 —— 单源抖动时自动切换
    if [ $attempt -le 8 ]; then url="$URL"; else url="$MIRROR"; fi
    # 关键：从已有字节处续传，并用 >> 追加。
    # 本机连接平均 1MB 左右就被掐断，若每次都从头重写，进度永远归零。
    curl -sL --max-time 120 -r "$((start + have))-$end" "$url" >> "$f" 2>/dev/null
  done
  echo "!! 分片 $i 失败" >&2
  return 1
}

echo "共 $N 片，每片 $((CHUNK / 1024 / 1024))MB，并发 $PARALLEL"

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
  done_cnt=$(ls "$PART_DIR" | wc -l | tr -d ' ')
  echo "  批次完成，进度 $done_cnt/$N"
done

[ $fail -ne 0 ] && echo "有分片失败，重跑本脚本会自动补下"

# 逐片核对大小后再拼接：缺一片整个 zip 就废了
i=0
while [ $i -lt $N ]; do
  part_ok "$i" || { echo "缺少或不完整的分片 $i，请重跑"; exit 1; }
  i=$((i + 1))
done

: > "$ZIP"
i=0
while [ $i -lt $N ]; do
  cat "$(part_path "$i")" >> "$ZIP"
  i=$((i + 1))
done

GOT=$(wc -c < "$ZIP" | tr -d ' ')
echo "拼接完成：$GOT 字节（应为 $TOTAL）"
[ "$GOT" = "$TOTAL" ] || { echo "大小不符，请重跑"; exit 1; }

if unzip -tqq "$ZIP" >/dev/null 2>&1; then
  echo "✓ zip 完整性校验通过"
else
  echo "✗ zip 损坏，请重跑"
  exit 1
fi

rm -rf "$PART_DIR"
echo "✓ 下载完成：$ZIP"
