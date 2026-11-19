extends Control
## 账号入口：登录 / 注册 / 自动登录
##
## 启动顺序：
##   1. 命令行已指定启动方式（--server / --join / --solo / --selftest）：
##      这一页根本不该被走到，保险起见直接进主场景；
##   2. 从开始页点「联机模式」进来：读 user://auth_session.json，
##      用 token 验证并拉存档；
##   3. token 有效就自动进主场景，没有有效会话才显示表单。
##
## ★ 登录成功后**不再直接进世界**，而是进「房间菜单」：
##   登录证明"你是谁"，接下来还要选"创建房间还是加入房间"。
##   这两件事分开之后，账号与联机才不再互斥。
##
## 「记住账号」没有开关：需求要求登录成功后下次启动自动进入，
## 只有玩家在游戏内点「退出登录」或 token 被服务端拒绝时才会删除本地凭证。

const DIRECT_FLAGS := ["--server", "--join", "--selftest", "--solo"]
const START_SCENE := "res://scenes/start/start.tscn"
const COLOR_OK := Color(0.66, 0.78, 0.60)
const COLOR_ERROR := Color(0.88, 0.48, 0.42)
const COLOR_MUTED := Color(0.52, 0.50, 0.47)

const PATH := "Layout/HBox/Left/Dossier/Margin/VBox"

@onready var _auto_box: VBoxContainer = get_node(PATH + "/AutoBox")
@onready var _auto_title: Label = get_node(PATH + "/AutoBox/AutoTitle")
@onready var _auto_name: Label = get_node(PATH + "/AutoBox/AutoName")
@onready var _auto_hint: Label = get_node(PATH + "/AutoBox/AutoHint")

@onready var _form_box: VBoxContainer = get_node(PATH + "/FormBox")
@onready var _login_tab: Button = get_node(PATH + "/FormBox/Tabs/LoginTab")
@onready var _register_tab: Button = get_node(PATH + "/FormBox/Tabs/RegisterTab")
@onready var _username: LineEdit = get_node(PATH + "/FormBox/UsernameEdit")
@onready var _password: LineEdit = get_node(PATH + "/FormBox/PasswordEdit")
@onready var _confirm_label: Label = get_node(PATH + "/FormBox/ConfirmLabel")
@onready var _confirm: LineEdit = get_node(PATH + "/FormBox/ConfirmEdit")
@onready var _status: Label = get_node(PATH + "/FormBox/Status")
@onready var _primary: Button = get_node(PATH + "/FormBox/Primary")
@onready var _switch_hint: Label = get_node(PATH + "/FormBox/SwitchHint")
@onready var _back: Button = get_node(PATH + "/BackBtn")

var _mode := "login"
var _busy := false


func _ready() -> void:
	_login_tab.pressed.connect(func() -> void: _set_mode("login"))
	_register_tab.pressed.connect(func() -> void: _set_mode("register"))
	_username.text_submitted.connect(func(_text: String) -> void: _password.grab_focus())
	_password.text_submitted.connect(func(_text: String) -> void: _submit())
	_confirm.text_submitted.connect(func(_text: String) -> void: _submit())
	_primary.pressed.connect(_submit)
	_back.pressed.connect(_on_back_pressed)

	_auto_box.visible = true
	_form_box.visible = false
	call_deferred("_start")


func _start() -> void:
	if _is_direct_launch():
		_auto_title.text = "正在进入游戏"
		_auto_name.text = ""
		_auto_hint.text = "联机与自检模式无需账号档案"
		await get_tree().process_frame
		get_tree().change_scene_to_file(AccountSession.WORLD_SCENE)
		return

	var result: Dictionary = await Account.auto_login()
	if bool(result.get("ok", false)):
		_auto_title.text = "正在恢复云端档案"
		_auto_name.text = String(result.get("username", ""))
		_auto_hint.text = "验证登录并同步存档…"
		await get_tree().create_timer(0.22).timeout
		# ★ 先写启动意图，再切场景。顺序反了的话，world._ready() 会先读到
		#   Launch 的旧值，于是把玩家丢进房间菜单却以为自己该单机开局。
		Launch.configure_lobby()
		var err := AccountSession.enter_game()
		if err != OK:
			_show_panel()
			_set_status("无法进入主场景：%s" % error_string(err), COLOR_ERROR)
		return

	_show_panel()
	_set_mode("login")
	_username.grab_focus()
	var reason := String(result.get("reason", ""))
	if not reason.is_empty():
		_set_status(reason, COLOR_MUTED)


func _show_panel() -> void:
	_auto_box.visible = false
	_form_box.visible = true


func _set_mode(mode: String) -> void:
	if _busy:
		return
	_mode = mode
	var registering := _mode == "register"
	_confirm_label.visible = registering
	_confirm.visible = registering
	_login_tab.set_pressed_no_signal(not registering)
	_register_tab.set_pressed_no_signal(registering)
	_primary.text = "建立档案" if registering else "进入世界"
	_switch_hint.text = (
		"注册后立刻建立独立存档"
		if registering
		else "登录后自动继续云端存档"
	)
	_status.text = ""
	_password.text = ""
	_confirm.text = ""
	_username.grab_focus()


func _submit() -> void:
	if _busy:
		return
	if _mode == "register" and _confirm.text.is_empty():
		_set_status("请再输入一次密码", COLOR_ERROR)
		_confirm.grab_focus()
		return

	_set_busy(true)
	_set_status("正在验证…", COLOR_MUTED)
	await get_tree().process_frame

	var result: Dictionary
	if _mode == "login":
		result = await Account.login(_username.text, _password.text)
	else:
		result = await Account.register(_username.text, _password.text, _confirm.text)

	if not bool(result.get("ok", false)):
		_set_busy(false)
		_set_status(String(result.get("reason", "操作失败")), COLOR_ERROR)
		if _mode == "login":
			_password.grab_focus()
		return

	_set_status("档案已确认，正在载入…", COLOR_OK)
	await get_tree().process_frame
	Launch.configure_lobby()
	var err := AccountSession.enter_game()
	if err != OK:
		_set_busy(false)
		_set_status("无法进入主场景：%s" % error_string(err), COLOR_ERROR)


func _set_busy(busy: bool) -> void:
	_busy = busy
	_username.editable = not busy
	_password.editable = not busy
	_confirm.editable = not busy
	_primary.disabled = busy
	_login_tab.disabled = busy
	_register_tab.disabled = busy
	_primary.text = "请稍候…" if busy else ("建立档案" if _mode == "register" else "进入世界")


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


### 返回开始页：重新选「单机 / 联机」。
##  已经在登录页上说明玩家还没进过游戏，所以这里不需要保存任何东西，
##   只要把模式意图清回"未决定"即可 —— 由开始页自己重新设置。
func _on_back_pressed() -> void:
	# 清 direct 同理：不清的话开始页会"跳过"自己，把玩家又送回世界/登录页。
	Launch.end_intent()
	get_tree().change_scene_to_file(START_SCENE)


func _is_direct_launch() -> bool:
	# 判断收敛到 Launch 一处。这里保留一层包装，是为了让"跳过登录页"这个
	# 语义在登录页内部读起来仍然直观。
	#
	# ★ 必须排除"需要账号"的情况：`--online` 也是 direct（跳过开始页），
	#   但它恰恰**必须**登录。把两者混为一谈，联机入口就会直接越过登录。
	return Launch.direct and not Launch.account_required
