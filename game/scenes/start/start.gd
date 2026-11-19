extends Control
## 开始页：单机 / 联机二选一 + 退出游戏
##
## ★ 它只做一件事：**决定 Launch.mode，然后交给下一个场景。**
##   不做登录、不开端口、不建玩家 —— 那些分别是 login.gd 和 world.gd 的事。
##   一个页面只有一项职责，后面才不会又长出"三处各判断一次"的问题。
##
## ★ 为什么命令行启动要在这里直接穿过：
##   `./run.sh both` 会起两个窗口，等用户点按钮就破坏了自动化；
##   无头自检（--selftest）更是完全没有人点。
##   所以 Launch.direct 为真时，这里一帧都不停留。
##
## ★ 为什么这一屏要显示"档案读数"（S14）：
##   一个只有两个按钮的页面，换成任何游戏都成立 —— 它没有说明"我现在是什么状态"。
##   右侧那块卡读的是**真实数据**：本地档案有没有、上次什么时候存的、玩了多少分钟。
##   这些东西本来就在磁盘上，只是以前没有地方显示；显示出来，
##   玩家进游戏前就知道"进度还在不在"，也不会误以为换模式会丢档。
##   卡片只读不写：看一眼不能碰玩家的档案。

const WORLD_SCENE := "res://scenes/world.tscn"
const LOGIN_SCENE := "res://scenes/login/login.tscn"

@onready var _solo_btn: Button = $Layout/Row/Left/SoloBtn
@onready var _online_btn: Button = $Layout/Row/Left/OnlineBtn
@onready var _quit_btn: Button = $Layout/Row/Left/QuitBtn
@onready var _hint: Label = $Layout/Row/Left/Hint
@onready var _local_value: Label = $Layout/Row/Right/Card/Margin/VBox/LocalRow/LocalValue
@onready var _played_value: Label = $Layout/Row/Right/Card/Margin/VBox/PlayedRow/PlayedValue
@onready var _time_value: Label = $Layout/Row/Right/Card/Margin/VBox/TimeRow/TimeValue
@onready var _account_value: Label = $Layout/Row/Right/Card/Margin/VBox/AccountRow/AccountValue
@onready var _dot: ColorRect = $Layout/Row/Right/Card/Margin/VBox/Header/Dot


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false

	if Launch.direct:
		# 命令行已经把启动方式说清楚了，直接进世界。
		call_deferred("_skip_to_world")
		return

	_solo_btn.pressed.connect(_on_solo_pressed)
	_online_btn.pressed.connect(_on_online_pressed)
	_quit_btn.pressed.connect(_on_quit_pressed)
	_refresh_profile()
	_refresh_hint()
	_solo_btn.grab_focus()


func _skip_to_world() -> void:
	# 命令行已经指定了模式，但这不代表可以跳过登录：
	# 联机模式要求账号，所以直接送到登录页，由它做自动登录。
	if Launch.account_required:
		get_tree().change_scene_to_file(LOGIN_SCENE)
	else:
		get_tree().change_scene_to_file(WORLD_SCENE)


func _on_solo_pressed() -> void:
	# 单机不读账号、不要求登录。进度写 user://local_save.json。
	Launch.configure_solo()
	get_tree().change_scene_to_file(WORLD_SCENE)


func _on_online_pressed() -> void:
	# 联机一定要身份：存档要认人，排行榜要认人。
	# 登录页会做自动登录（有 token 就直接进），没有 token 才显示表单。
	Launch.configure_lobby()
	get_tree().change_scene_to_file(LOGIN_SCENE)


func _on_quit_pressed() -> void:
	# 开始页还没进世界，没有任何东西需要保存（`_save_loaded` 为假）。
	# 直接 quit 就够，不需要走 AccountSession 那套存盘流程。
	get_tree().quit()


# ------------------------------------------------------------
# 档案读数
# ------------------------------------------------------------
func _refresh_profile() -> void:
	var summary: Dictionary = AccountSession.local_save_summary()
	var has_save: bool = bool(summary.get("has", false))

	_local_value.text = "已有" if has_save else "暂无"
	_played_value.text = _format_clock(int(summary.get("modified", 0))) if has_save else "—"
	_time_value.text = _format_span(int(summary.get("play_seconds", 0))) if has_save else "—"

	# 小方点：有档案亮起（强调色），没有就退回中性灰。
	# 这是这一屏唯一的"活力"信号，不用动画 —— 一个会呼吸的点会让整页都在动。
	_dot.color = Color(0.78, 0.60, 0.28, 1.0) if has_save else Color(0.47, 0.45, 0.42, 1.0)

	if Account.is_logged_in():
		_account_value.text = Account.username()
	elif Account.has_session():
		# 有 token 但还没验证：登录页会自动登录，这里如实说"记住了谁"。
		_account_value.text = "已记住登录"
	else:
		_account_value.text = "未登录"


### 提示行只说"当前这次会发生什么"，不重复按钮上的词。
##
### 有 token 时改口"将自动进入"：否则玩家点了联机、看到登录页闪一下又跳走，
### 会以为是 bug。
func _refresh_hint() -> void:
	if not Account.has_session():
		_hint.text = "单人不需要账号 · 联机需要登录后创建或加入房间"
		return
	var name := Account.username()
	if name.is_empty():
		return
	_hint.text = "已记住 %s 的登录 · 选联机将自动进入" % name
	_hint.add_theme_color_override("font_color", Color(0.78, 0.60, 0.28, 1))


### 时间戳 → `11 月 17 日 22:58`。0 表示没有，交给调用方显示 "—"。
func _format_clock(unix_time: int) -> String:
	if unix_time <= 0:
		return "—"
	var t := Time.get_datetime_dict_from_unix_time(unix_time)
	return "%d 月 %d 日 %02d:%02d" % [int(t.month), int(t.day), int(t.hour), int(t.minute)]


### 秒 → `2 小时 14 分`。
##
### 不足一分钟不显示 "0 分钟"：那是"没有数据"的意思，
### 而玩家确实玩了几十秒，写成 0 会让人以为存档坏了。
func _format_span(seconds: int) -> String:
	if seconds <= 0:
		return "—"
	if seconds < 60:
		return "不到 1 分钟"
	if seconds < 3600:
		return "%d 分钟" % int(seconds / 60.0)
	var hours := int(seconds / 3600.0)
	var minutes := int((seconds - hours * 3600) / 60.0)
	return "%d 小时 %d 分" % [hours, minutes]
