extends Node
## 启动意图（Autoload，全局名 `Launch`）
##
## 这个文件存在的唯一理由：**"我这次是怎么进来的"只能有一个真相源。**
##
## ★ 上一版的问题（S13 要修的根）：
##   同一件事被三处代码各判断了一次，每处都按自己的局部合理性决定，
##   合起来的结论却是"账号与联机只能二选一"：
##
##     login.gd        看 DIRECT_FLAGS 决定要不要跳过登录
##     world.gd        看 argv 决定要不要 Net.host()
##     AccountSession  发现没人开房，就强行 _solo = true 并把菜单藏了
##
##   三个地方都没写错，但它们没有共同的"我这次要干什么"这个概念。
##
## ★ 现在的形状：
##   启动时（或开始页点按钮时）**写一次** Launch.mode，
##   之后 world / login / AccountSession 都只**读**它。
##   谁想改变启动方式，就去改这一个变量，而不是去 argv 里猜。
##
## ★ 为什么不干脆全用命令行参数：
##   玩家点「单机模式」的时候没有命令行。之前之所以能用 --solo 冒充，
##   是因为那时只有一个入口；现在有两个入口，就必须有一个内存里的意图。

enum Mode {
	SOLO,   ## 本地主机，不等别人连。可不登录，用本地存档
	HOST,   ## 直接创建房间等人连（命令行 ./run.sh host）
	JOIN,   ## 直接连某个 IP（命令行 ./run.sh join 1.2.3.4）
	LOBBY,  ## 显示房间菜单，等玩家自己点"创建/加入"
}

var mode := Mode.LOBBY
var join_ip := "127.0.0.1"

## 命令行已经完整指定了启动方式 → 跳过开始页。
## `--solo` / `--server` / `--join` / `--selftest` 都算。
## 这条保住了三件事：无头自检、`./run.sh both` 两个窗口、以及老习惯。
var direct := false

## 是否需要账号档案。只有「联机模式」为真：
## 联机要读别人的存档、要进排行榜，必须有身份；单机不该被登录页挡在门外。
var account_required := false


func _ready() -> void:
	_parse_cmdline()


func _parse_cmdline() -> void:
	var args := OS.get_cmdline_user_args()

	if args.has("--selftest"):
		direct = true

	if args.has("--online"):
		# 命令行直接走"联机"这条路：跳过开始页，但仍然要登录。
		# 这一条是给 ./run.sh online 用的 —— 少了它，脚本就得让玩家先点一下按钮。
		mode = Mode.LOBBY
		account_required = true
		direct = true
		return

	if args.has("--solo"):
		# 单机：本地开一个没人连的主机。网络代码全保留，
		# 只是不需要账号、也不需要问玩家"要联机吗"。
		mode = Mode.SOLO
		direct = true
	elif args.has("--server"):
		mode = Mode.HOST
		direct = true
	elif args.has("--join"):
		mode = Mode.JOIN
		direct = true
		var i := args.find("--join")
		if i >= 0 and i + 1 < args.size():
			join_ip = args[i + 1]


## 开始页点「单机模式」
func configure_solo() -> void:
	mode = Mode.SOLO
	account_required = false


## 开始页点「联机模式」（登录成功后由 login.gd 调用）
func configure_lobby() -> void:
	mode = Mode.LOBBY
	account_required = true


func is_selftest() -> bool:
	return OS.get_cmdline_user_args().has("--selftest")


### 这次启动意图已经用掉了：回到开始页时调用。
##
### ★ 为什么必须清 `direct`：
##   开始页看到 `direct` 为真就"一帧都不停留"地进世界。退出/返回时不清它，
##   玩家看到的是：点「退出」→ 画面闪一下 → 又回到游戏里，
##   像是退出功能坏了。本轮单机退出其实是**两层**原因叠在一起：
##   ① `logout_to_login` 在 `not is_logged_in()` 处直接 return（根本不切场景）；
##   ② 就算切到开始页，direct 还在，开始页立刻又把人送回来。
##   只修①的话，命令行启动（./run.sh solo）仍然会"退出无效"。
func end_intent() -> void:
	direct = false
	account_required = false


func mode_name() -> String:
	match mode:
		Mode.SOLO: return "单机"
		Mode.HOST: return "主机"
		Mode.JOIN: return "客户端"
		_: return "房间菜单"
