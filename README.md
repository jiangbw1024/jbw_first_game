# 联机沙盒 · 末日拾荒

一个用 Godot 4 写的 3D 末日生存沙盒，也是**一套可运行的联机架构教学工程**：
单机拾荒、联机开房、自建基地、打丧尸，每一层都配了中文注释与原理笔记。

![开始页](screenshots/s14_start.png)

> 它不是"做完的游戏"，而是一个**读得懂、跑得起来、改得动**的工程。
> 每个阶段都有可复现的自检命令，`NOTES.md` 里写的是"为什么这样做"，不是 API 手册。

---

## 目录

- [能玩到什么](#能玩到什么)
- [技术栈](#技术栈)
- [快速开始](#快速开始)
- [启动方式](#启动方式)
- [操作键位](#操作键位)
- [自检](#自检)
- [联机与内网穿透](#联机与内网穿透)
- [后端（可选）](#后端可选)
- [目录结构](#目录结构)
- [学习路线](#学习路线)
- [已知边界](#已知边界)
- [文档](#文档)
- [致谢](#致谢)

---

## 能玩到什么

| 系统 | 已经有的东西 |
| --- | --- |
| 世界 | Terrain3D 地形（2048 m 见方 / 2 m 每顶点）、程序化城镇（10 栋建筑、3 处聚落）、树木与拾荒容器 |
| 角色 | 第一人称移动、冲刺、跳跃、血量与死亡重生、第一人称手臂与武器视图 |
| 战斗 | AK47（全自动 / 换弹 / 推击 / 后坐力）、蝴蝶刀（轻击 / 重击 / 背刺 / 检视动画）、丧尸状态机（追击、前摇、互相排斥） |
| 拾荒 | 12 格背包、部分拾取、弹药直入枪不占格、搜刮容器与掉落物 |
| 建造 | 地基 / 墙 / 门框，材料校验与 50% 拆除返还，建造模式图鉴 |
| 存档 | 单机写本机 `user://local_save.json`，联机写服务器；**两种后端共用同一份 JSON 格式** |
| 入口 | 开始页（单人 / 联机 / 退出）→ 单机直达世界，联机先登录再进房间菜单 |
| 联机 | 房间菜单创建 / 加入房间，服务器权威，最多 8 人 |
| 账号 | 注册 / 登录 / JWT / BCrypt，排行榜与云存档 |

截图在 [`screenshots/`](screenshots/)，包含世界、丧尸、背包、建造、持枪姿态、暂停菜单与大堂。

---

## 技术栈

| 层 | 选型 |
| --- | --- |
| 引擎 | Godot **4.7.2**（Forward+，引擎已内置在 `tools/Godot.app`，免安装） |
| 语言 | GDScript（游戏） |
| 地形 | Terrain3D 插件（`game/addons`） |
| 联机 | ENet（UDP 7777）+ `MultiplayerSpawner` / `MultiplayerSynchronizer` / `@rpc` |
| 后端 | Spring Boot 4.1.2 · JDK 21 · MyBatis-Plus 3.5.18.1（可选） |
| 数据库 | MySQL 8（库名 `jbw_game`，三张表：`game_user` / `player_save` / `leaderboard`） |
| 认证 | JJWT 0.13.0 + BCrypt |

---

## 快速开始

### 只需要能玩

```sh
cd /path/to/jbw_first_game
./run.sh
```

第一次启动会打开**开始页**：单人 / 联机二选一，左下角可以退出游戏。
单机不需要账号、不需要后端、不联网。

> macOS 首次运行若提示"无法验证开发者"，右键 `tools/Godot.app` → 打开。
> 也可以在访达里双击 `play.command`，效果等同 `./run.sh`。

### 想跑联机 + 云存档

需要额外启动后端，见 [后端（可选）](#后端可选)。

---

## 启动方式

`run.sh` 是唯一入口，参数不同就走不同的链路：

| 命令 | 会发生什么 |
| --- | --- |
| `./run.sh` | **默认**：打开开始页，自己选「单人进入 / 联机进入」 |
| `./run.sh solo` | 跳过开始页，直接单机（本地存档） |
| `./run.sh online` | 跳过开始页，走联机登录；登录后进房间菜单 |
| `./run.sh host` | 直接当主机等人连（无账号、无云存档） |
| `./run.sh join 1.2.3.4` | 直接连到某个 IP（无账号、无云存档） |
| `./run.sh both` | 同机开两个窗口：一个主机 + 一个客户端（测联机最方便） |
| `./run.sh editor` | 打开 Godot 编辑器 |

启动意图只有一个真相源：Autoload `Launch`（`mode` / `direct` / `account_required`）。
不再从 `argv` 各处猜 —— 这是 S13 专门拆掉的一处结构性 bug，详见 `NOTES.md`。

---

## 操作键位

常用几个：

| 键位 | 功能 |
| --- | --- |
| `W A S D` / `Shift` / `Space` | 移动 / 冲刺 / 跳跃 |
| `1` / `3` / `Q` | AK47 / 蝴蝶刀 / 切回上一把 |
| 鼠标左键 / 右键 | 开火·轻击 / 推击·重击 |
| `R` / `V` / `F` | 换弹 / 通用近战 / 检视刀具 |
| `E` | 拾取、搜刮、交易 |
| `Tab` / `Enter` | 背包 / 聊天 |
| `B` | 建造模式（`T` 旋转，左键放置，右键拆除） |
| `Esc` | 游戏内菜单（单机暂停 / 联机只开菜单，不暂停世界） |

完整键位见 [`game/CONTROLS.md`](game/CONTROLS.md)。

---

## 自检

这个工程没法靠"看"验收，所以每个阶段都留了探针。
命令统一是 `tools/Godot.app/Contents/MacOS/Godot`，输出以 `[TEST]` 开头，失败时非零退出码。

### 无头用例（`--headless`，可写进 CI）

```sh
tools/Godot.app/Contents/MacOS/Godot --headless --path game -- --solo --selftest <用例>
```

| 用例 | 验证什么 |
| --- | --- |
| `input` | 输入锁时序（多个 UI 同时开）、键位映射 |
| `pause` | 单机暂停真的冻结 / 联机只开菜单不冻结 / 退出确认 / 输入锁清理 |
| `slots` `knife` | 武器切换顺序、拉刀锁、换弹打断、刀伤判定 |
| `layout` `town` `spawn` `porch` | 城镇生成确定性、碰撞盒、出生点合法、门廊可通行 |
| `shoot` `combat` `sfx` | 射线命中、丧尸状态机与伤害、音效触发 |
| `loot` `build` | 拾荒与背包、建造校验与拆除返还 |
| `launch` `profile` `logout` `logoutlive` | 启动模式解析、存档归属、玩家查找、单机退出真的切场景 |
| `startui` | 开始页按钮文案、`pressed` 是否真的接线、主次层级 |
| `lobby` | 登录后进房间菜单（需后端在 8080 且有有效 token） |

> 另有 `shop` / `hostbuy` / `equipjoin` 等联机用例，需要两个进程配合跑，见 `game/NOTES.md`。

### 需要渲染的用例（**不能加 `--headless`**，否则截出空图）

```sh
tools/Godot.app/Contents/MacOS/Godot --path game -- --solo --selftest shot        # 世界
tools/Godot.app/Contents/MacOS/Godot --path game -- --solo --selftest startshot   # 开始页
tools/Godot.app/Contents/MacOS/Godot --path game -- --solo --selftest pauseshot   # 暂停菜单
```

截图落到 `/tmp/*.png`。

> 自检里有一条铁律：**测试永远不碰真实存档**。
> 存档往返测试写的是 `user://__selftest_save.json`，跑完就删。

---

## 联机与内网穿透

联机只要求两条链路，协议不同，别搞混：

| 链路 | 协议 / 端口 | 什么时候需要 |
| --- | --- | --- |
| 主机 ↔ 好友 | **UDP 7777**（ENet） | 必需 |
| 两端 → 后端 | **TCP 8080**（HTTP） | 只有"要账号登录 / 云存档"时 |

**推荐做法：虚拟局域网**（Tailscale / ZeroTier / 蒲公英）。
两台机器各拿一个虚拟 IP，UDP 直接通，不用公网 IP、不用云服务器：

```sh
# 你的机器
./run.sh host                      # 或 ./run.sh，然后选「联机进入」
tailscale ip -4                    # 得到 100.x.y.z

# 好友的机器
./run.sh join 100.x.y.z
```

想带账号和云存档，后端地址也要指过去（默认是 `127.0.0.1:8080`，好友一定连不上）：

```sh
JBW_API_BASE=http://100.x.y.z:8080 ./run.sh online
```

> ⚠️ **ngrok 免费版只转发 TCP，这个游戏一定连不上。**
> 症状很典型：登录能过，一进房间就"连不上服务器"。
> 端口转发也要显式配 `udp`，不是 `tcp`。
> macOS 防火墙第一次会问"是否允许接受传入网络连接"，点拒绝的话同样是这个症状。

---

## 后端（可选）

不联机、不云存档的话完全不需要。

```sh
cd backend
mysql -u root -p < sql/schema.sql      # 建库 + 三张表
mysql -u root -p < sql/dev-user.sql    # 本地开发账号（jbw_app）
mvn spring-boot:run                    # 默认 8080
```

数据库连接可用环境变量覆盖：`DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USERNAME` / `DB_PASSWORD`；
游戏侧的后端地址用 `JBW_API_BASE` 覆盖。

接口、分层的详细说明在 [`backend/README.md`](backend/README.md)，
登录与 JWT 的流程图在 [`docs/login-system-diagrams.md`](docs/login-system-diagrams.md)。

---

## 目录结构

```text
jbw_first_game/
├── run.sh                     # 唯一启动入口
├── play.command               # 双击启动（等价 ./run.sh）
├── game/                      # Godot 工程
│   ├── project.godot          # 主场景 = scenes/start/start.tscn
│   ├── scenes/                # 场景与场景脚本（world / player / start / login / 大厅…）
│   ├── scripts/               # Autoload 与系统（net / launch / game_state / account / loot / build…）
│   ├── shaders/               # 后处理与材质
│   ├── addons/                # Terrain3D
│   ├── NOTES.md               # ★ 概念笔记：每个阶段"为什么这样做"
│   └── CONTROLS.md            # 完整键位与界面说明
├── backend/                   # Spring Boot 后端（独立于游戏，不改 game/ 任何代码）
├── docs/                      # 登录系统流程图（mermaid + png）
├── screenshots/               # 各阶段验收截图
├── dsh-plugins/game-launcher/ # 可选：在 DSH「应用托管」里一键启动游戏
├── openspec/                  # 需求变更记录（spec-driven）
└── tools/Godot.app            # 内置引擎 4.7.2
```

---

## 学习路线

`game/NOTES.md` 按阶段记录，从"网络骨架"一路写到"界面工艺"。挑几条最有代表性的：

| 阶段 | 主题 | 一句话 |
| --- | --- | --- |
| S0–S8 | 骨架 → 世界 → 城镇 → 商店 | 先把"谁说了算"（服务器权威）钉死 |
| S9.5–S9.7 | 画面与持枪姿态 | "模型粗糙"其实是光照、FXAA 与材质高光的问题 |
| S10 | 战斗闭环 | 从"打靶"到"会死"，状态机与死亡重生 |
| S11 | 拾荒与背包 | 部分拾取、弹药不占格、死亡材料减半 |
| S12 | 建造闭环 | 先把料扣了再放砖，拆除按 50% 返还 |
| S13 | 拆掉"账号与联机互斥" | 启动意图收拢到一个变量，peer_id ≠ 账号 |
| S13.1 / S13.2 | 两个"退出无效" | 没登录 ≠ 没会话可退；菜单能开 ≠ 世界要暂停 |
| S14 | 开始页重做 | 把"好看吗"换成问题清单，再换成可断言的规则 |

---

## 已知边界

- **联机存档仍以房主为准**：客户端读档后递交一次，之后不再从云端同步
- **主机能改自己的存档**：存档由客户端带 JWT 直接写后端，陌生人房间需要服务器权威存档
- **单机进度不会自动上云**：需要手动的"上传本地进度"
- **没有房间列表**：加入房间靠手填 IP
- **没有跨局重连**：断线后玩家节点销毁，靠 3 秒自动存档兜底
- **端口写死**：`Net.PORT = 7777`，穿透服务给别的端口时需要改代码
- **无 iOS / Android 导出**，只在 macOS 上验证过

---

## 文档

| 文件 | 内容 |
| --- | --- |
| [`game/NOTES.md`](game/NOTES.md) | 概念笔记：每个阶段的问题、方案与踩过的坑 |
| [`game/CONTROLS.md`](game/CONTROLS.md) | 键位、界面、退出与联机说明 |
| [`backend/README.md`](backend/README.md) | 后端分层、接口、数据库设计 |
| [`docs/login-system-diagrams.md`](docs/login-system-diagrams.md) | 注册 / 登录 / JWT / 存档同步 / 排行榜流程图 |
| [`dsh-plugins/game-launcher/README.md`](dsh-plugins/game-launcher/README.md) | 可选插件：在 DSH 里一键启动游戏 |

---

## 致谢

- [Terrain3D](https://github.com/TokisanGames/Terrain3D) —— 地形插件
- [Godot Engine](https://godotengine.org/) 4.7.2
- 开始页的界面工艺参考了 **unslop**（by [@heydamir](https://x.com/heydamir)，CC BY 4.0），
  方向、审计清单与"一个强调色"的做法来自它，代码与取舍仍是本项目的
