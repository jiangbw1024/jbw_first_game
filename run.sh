#!/bin/zsh
# 沙盒 · 启动脚本
#
# 用法（在本目录下）：
#   ./run.sh                打开开始页，自己选「单机 / 联机」
#   ./run.sh solo           跳过开始页，直接单机（本地存档）
#   ./run.sh online         跳过开始页，直接走联机登录（有 token 会自动进）
#   ./run.sh host           直接当主机（不等菜单，无账号）
#   ./run.sh join 1.2.3.4   直接连到某个 IP（无账号）
#   ./run.sh both           同机开两个窗口，一个主机一个客户端（最适合测联机）
#   ./run.sh editor         打开 Godot 编辑器（看场景树、改属性）
#
# 为什么要有这个脚本：Godot 可执行文件在 tools/Godot.app/Contents/MacOS/ 里，
# 每次手敲那串路径既长又容易错。更重要的是 —— 路径里一旦有空格就会失败，
# 所以下面每处引用都加了引号。

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
GODOT="$DIR/tools/Godot.app/Contents/MacOS/Godot"
GAME="$DIR/game"

if [ ! -x "$GODOT" ]; then
  echo "找不到引擎：$GODOT"
  echo "（tools/Godot.app 可能被删掉了，重新下载解压即可）"
  exit 1
fi

cmd="${1:-start}"

case "$cmd" in
  solo)
    # 单机 = 本地开一个没人连的主机：网络代码全保留，开联机时只改这一个参数。
    # 不登录也能玩，进度写 user://local_save.json。
    exec "$GODOT" --path "$GAME" -- --solo
    ;;
  start|menu)
    # 不传任何参数 = 打开开始页（单机 / 联机二选一）。
    # menu 保留成别名，免得老习惯失效。
    exec "$GODOT" --path "$GAME"
    ;;
  online)
    # --online 只负责"跳过开始页"，登录还是照做
    exec "$GODOT" --path "$GAME" -- --online
    ;;
  host|server)
    exec "$GODOT" --path "$GAME" -- --server
    ;;
  join)
    ip="${2:-127.0.0.1}"
    exec "$GODOT" --path "$GAME" -- --join "$ip"
    ;;
  both)
    # 先起主机再起客户端：客户端启动时要立刻能连上，顺序反了会连接失败
    "$GODOT" --path "$GAME" -- --server > /tmp/sandbox_host.log 2>&1 &
    sleep 2
    "$GODOT" --path "$GAME" -- --join 127.0.0.1 > /tmp/sandbox_client.log 2>&1 &
    echo "两个窗口已启动（主机 + 客户端）"
    echo "日志：/tmp/sandbox_host.log  /tmp/sandbox_client.log"
    echo "看实时日志： tail -f /tmp/sandbox_host.log"
    ;;
  editor)
    exec "$GODOT" --editor --path "$GAME"
    ;;
  *)
    echo "用法： ./run.sh [start|solo|online|both|host|join <IP>|editor]"
    exit 1
    ;;
esac
