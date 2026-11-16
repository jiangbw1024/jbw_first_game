# 游戏启动器 · Game launcher

把「打开游戏」放进 **应用托管** 页面：打开左侧边栏的「应用托管」，页面顶部会有一张「游戏」卡片，点「打开游戏」即可启动本机的 Godot 沙盒游戏，不用再开终端敲 `./run.sh`。

The **Open game** action lives inside **App hosting**: a Game card at the top of that page launches the local Godot sandbox game.

## 怎么用 · Usage

1. 点左侧边栏的「应用托管」。
2. 页面顶部的「游戏」卡片显示当前状态（运行中 / 未运行，每 5 秒刷新）。
3. 点「打开游戏」：按配置的模式启动（默认单机 `solo`）。
4. 游戏已经在运行时，按钮显示「运行中」并禁用，不会重复开窗口。
5. 启动失败时，卡片底部会显示失败原因（例如找不到 `run.sh` 或 Godot 引擎）。

Open **App hosting** from the left sidebar. The Game card shows the current state (refreshed every five seconds); click **Open game** to launch the configured mode (solo by default). While the game runs, the button reads Running and is disabled.

> 需要同时启用「应用托管」（`@local/app-host`）插件——卡片就渲染在它的页面里。如果停用它，本插件仍提供启动接口，但没有可见入口。
> The App hosting plugin (`@local/app-host`) must be enabled; the card renders inside its page. Without it the launch endpoint still exists but has no visible entry.

## 模式 · Modes

| 模式 | 行为 |
|---|---|
| `solo` | 单机，直接进入打丧尸（默认） |
| `menu` | 联机菜单（创建 / 加入房间） |
| `host` | 直接当主机，跳过菜单 |
| `join <IP>` | 直接连到某个 IP（默认 `127.0.0.1`） |
| `both` | 同机开两个窗口：一个主机 + 一个客户端 |
| `editor` | 打开 Godot 编辑器 |

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
    mode: solo                                           # 卡片按钮的默认模式
```

本包内的 `cordis.patch.yml` 已经写好同样的值，安装后改那里即可。

## 行为与安全 · Behavior and safety

- 游戏以 detached 进程启动，**退出 DSH 不会关闭游戏**；日志写在 `/tmp/dsh-game-launcher.log`。
- Host 端只注册两个本机接口：`GET /api/game-launcher/state`、`POST /api/game-launcher/launch`。它们只接受同源请求，并校验 Host / Origin；不读取、不上传游戏数据。它们不是 DSH 的会话鉴权接口，因此默认只应在本机回环地址上使用本插件。
- 启动前会检查 `run.sh`、可执行权限和 `tools/Godot.app`，失败原因会直接显示在卡片里。
- 运行状态只保存在 DSH 进程内存里：重启 DSH 后插件不再认识之前启动的游戏（此时再点会新开一个窗口）。

## 限制 · Limitations

- 面向 macOS + 本机回环 Web（当前 `http://127.0.0.1:<port>`）；不适用于远端浏览器。
- 需要「应用托管」插件一起启用，入口才会显示。
- 如果游戏自己占用了端口或启动报错，错误来自游戏本身；插件只把日志尾巴一起返回。
- 重复点击保护只覆盖同一个 DSH 进程内、由本插件启动的进程；两次点击几乎同时发生时仍可能各开一个窗口。

## 实现 · Implementation

- Host：`index.js` 通过 `ctx.webServer` 注册同源接口，用 `run.sh` 启动 Godot（detached + unref）。
- Client：`client.js` 向「应用托管」页面声明的扩展槽 `main.app-host.extra` 注册「游戏」卡片，卡片调用上面的接口并轮询状态。
- 应用托管端（`@local/app-host`）在页面里声明并渲染这个扩展槽。
