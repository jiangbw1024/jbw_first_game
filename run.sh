#!/bin/zsh
# 沙盒 · 启动脚本
#
# 用法（在本目录下）：
#   ./run.sh            直接进单机（当前主玩法：打丧尸）
#   ./run.sh solo       同上
#   ./run.sh menu       弹出联机菜单（创建/加入房间）
#   ./run.sh both       同机开两个窗口，自动一个主机一个客户端（最适合测试联机）
#   ./run.sh host       直接当主机（跳过菜单）
#   ./run.sh join 1.2.3.4   直接连到某个 IP
#   ./run.sh editor     打开 Godot 编辑器（看场景树、改属性）
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

cmd="${1:-solo}"

case "$cmd" in
  solo)
    # 单机 = 本地开一个没人连的主机：网络代码全保留，开联机时只改这一个参数
    exec "$GODOT" --path "$GAME" -- --solo
    ;;
  menu)
    exec "$GODOT" --path "$GAME"
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
    echo "用法： ./run.sh [solo|menu|both|host|join <IP>|editor]"
    exit 1
    ;;
esac
