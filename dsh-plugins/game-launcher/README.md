# 游戏启动器 · Game launcher

把「打开游戏」放进 **应用托管** 页面：打开左侧边栏的「应用托管」，页面顶部会有一张「游戏」卡片，点「打开游戏」即可启动本机的 Godot 沙盒游戏，不用再开终端敲 `./run.sh`。

The **Open game** action lives inside **App hosting**: a Game card at the top of that page launches the local Godot sandbox game.

## 怎么用 · Usage

1. 点左侧边栏的「应用托管」。
2. 页面顶部的「游戏」卡片显示当前状态（运行中 / 未运行，每 5 秒刷新）。
3. 卡片固定有两个按钮：**打开游戏**（运行中置灰）和 **停止游戏**（未运行置灰）。
4. 点「打开游戏」：按配置的模式启动（默认 `start`，即开始页，和终端 `./run.sh` 一致），不会重复开窗口。
5. 点「停止游戏」：需要再点一次「确认停止」；停止时先发 SIGTERM，4 秒内没退出再强制结束整个进程组。
6. 从终端或 `play.command` 启动的游戏也能识别（卡片显示「外部启动」），同样可以停止；编辑器窗口不算。
7. 启动/停止失败时，卡片底部会显示原因（例如找不到 `run.sh`、Godot 引擎缺失、停止接口不可用）。

Open **App hosting** from the left sidebar. The Game card always shows **Open game** and **Stop game**, disabling the one that does not apply. Open game starts the configured mode (start page by default, same as `./run.sh`) without opening a second window; Stop game needs a confirming second click, asks the game to quit, then force-terminates its process group if needed.

> 需要同时启用「应用托管」（`@local/app-host`）插件——卡片就渲染在它的页面里。如果停用它，本插件仍提供启动接口，但没有可见入口。
> The App hosting plugin (`@local/app-host`) must be enabled; the card renders inside its page. Without it the launch endpoint still exists but has no visible entry.

## 模式 · Modes

| 模式 | 行为 |
|---|---|
| `start` | 打开开始页，自己选单机 / 联机（**默认**，与 `./run.sh` 一致） |
| `solo` | 跳过开始页，直接单机打丧尸（本地存档，不需要账号） |
| `online` | 跳过开始页，走联机登录；登录后进房间菜单 |
| `host` | 直接当主机，跳过菜单（无账号、无云存档） |
| `join <IP>` | 直接连到某个 IP（默认 `127.0.0.1`） |
| `both` | 同机开两个窗口：一个主机 + 一个客户端 |
| `editor` | 打开 Godot 编辑器 |
| `menu` | 旧名字，现在等价于 `start`（S13 之后「房间菜单」在登录之后） |

卡片上的按钮使用默认模式；其它模式通过接口参数或修改配置使用：

```sh
# 需要 IP 时
curl -X POST "http://127.0.0.1:<当前 GUI 端口>/api/game-launcher/launch" \
  -H 'content-type: application/json' -d '{"mode":"join","ip":"192.168.1.10"}'
```

## 配置 · Configuration

在 DSH 配置 `cordis.patch.yml` 的 patch 行里修改（见本包的 `cordis.patch.yml` 示例）：

```yaml
- id: game-launcher
  name: '@local/game-launcher'
  config:
    gameDir: /Users/aaaa/PycharmProjects/jbw_first_game   # 游戏项目目录（里面要有 run.sh）
    mode: start                                          # 卡片按钮的默认模式
```

本包内的 `cordis.patch.yml` 已经写好同样的值，安装后改那里即可。

## 行为与安全 · Behavior and safety

- 游戏以 detached 进程启动，**退出 DSH 不会关闭游戏**；日志写在 `/tmp/dsh-game-launcher.log`。
- Host 端注册三个本机接口：`GET /api/game-launcher/state`、`POST /api/game-launcher/launch`、`POST /api/game-launcher/stop`。它们只接受同源请求，并校验 Host / Origin；不读取、不上传游戏数据。它们不是 DSH 的会话鉴权接口，因此默认只应在本机回环地址上使用本插件。
- 启动前会检查 `run.sh`、可执行权限和 `tools/Godot.app`，失败原因会直接显示在卡片里。
- 状态判断有两路：本插件自己启动的进程组，以及按项目路径（`tools/Godot.app` + `--path`）用 `ps` 扫描到的 Godot 进程。从终端 / `play.command` 启动的游戏也能识别并停止，并标出「外部启动」。
- 扫描会排除 `--editor` / `-e` 打开的编辑器窗口，避免一次停止关掉没保存的场景；用编辑器模式由本插件启动的进程仍按启动记录处理。
- 扫描到的外部游戏只结束 Godot 进程本身（SIGTERM，必要时 SIGKILL），不会向它所在的进程组发信号——避免误伤开游戏的终端。
- 停止会直接结束游戏进程，未保存的进度会丢失。
- 只认本项目 `tools/Godot.app` 里的引擎：导出成独立 `.app` 运行的游戏不会被扫描到。
- 重启 DSH 后，之前由插件启动的游戏会被当作外部进程重新扫描到，仍然可以停止。

## 限制 · Limitations

- 面向 macOS + 本机回环 Web（当前 `http://127.0.0.1:<port>`）；不适用于远端浏览器。
- 需要「应用托管」插件一起启用，入口才会显示。
- 如果游戏自己占用了端口或启动报错，错误来自游戏本身；插件只把日志尾巴一起返回。
- 重复点击保护只覆盖同一个 DSH 进程内、由本插件启动的进程；两次点击几乎同时发生时仍可能各开一个窗口。

## 实现 · Implementation

- Host：`index.js` 通过 `ctx.webServer` 注册同源接口，用 `run.sh` 启动 Godot（detached + unref，按进程组跟踪），并用 `ps` 按项目路径扫描外部启动的 Godot 进程；停止时向所有相关进程组发信号。
- Client：`client.js` 向「应用托管」页面声明的扩展槽 `main.app-host.extra` 注册「游戏」卡片，卡片调用上面的接口并轮询状态。
- 应用托管端（`@local/app-host`）在页面里声明并渲染这个扩展槽。
