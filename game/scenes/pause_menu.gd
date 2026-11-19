class_name PauseMenu
extends CanvasLayer
## 游戏内菜单（Esc）：继续 / 操作指南 / 返回开始页 / 退出游戏
##
## ★ S13.2：把两个被混在一起的概念拆开 ——
##   「菜单能不能打开」和「打开后要不要冻结世界」。
##
##   旧实现把它们合成一个 `enabled`，而 world 只在"没有客人 + 我是主机"时置真。
##   后果是联机里按 Esc 完全没反应：菜单打不开，连「退出游戏」都点不到，
##   想退出只能去点徽章「退出登录」（还顺手把 token 删了），再从头登一次。
##   **一个没有出口的界面，比一个不好用的界面更像是 bug。**
##
##   现在的规则：
##     单机 / 没客人 / 我是主机 → 打开即暂停（get_tree().paused = true）
##     联机（有客人 或 我是客户端）→ 菜单照常打开，但**绝不暂停**
##       主机一暂停，服务端逻辑跟着停，所有客户端一起卡死。
##
## process_mode 必须是 ALWAYS，否则 paused = true 之后自己也被冻住，
## 按钮和 Esc 都不再响应。

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Center/Panel/VBox/Title
@onready var _subtitle: Label = $Root/Center/Panel/VBox/Subtitle
@onready var _main_view: Control = $Root/Center/Panel/VBox/Main
@onready var _guide_view: Control = $Root/Center/Panel/VBox/Guide
@onready var _guide_scroll: ScrollContainer = $Root/Center/Panel/VBox/Guide/Scroll
@onready var _resume_button: Button = $Root/Center/Panel/VBox/Main/Buttons/VBox/Resume
@onready var _guide_button: Button = $Root/Center/Panel/VBox/Main/Buttons/VBox/GuideButton
@onready var _leave_button: Button = $Root/Center/Panel/VBox/Main/Buttons/VBox/Leave
@onready var _quit_button: Button = $Root/Center/Panel/VBox/Main/Buttons/VBox/Quit
@onready var _back_button: Button = $Root/Center/Panel/VBox/Guide/Back
@onready var _footer: Label = $Root/Center/Panel/VBox/Main/Footer

## 能否打开菜单。由 world 在会话状态变化时设置。
var enabled := false
## 打开时是否真的冻结世界。只有"一个人玩、且本机是服务器"才允许。
var _can_freeze := false
## 「返回开始页」是否已经进入确认状态（3 秒内再点一次才真的走）
var _leave_armed := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root.visible = false
	_resume_button.pressed.connect(resume_game)
	_guide_button.pressed.connect(show_guide)
	_leave_button.pressed.connect(request_leave)
	_quit_button.pressed.connect(quit_game)
	_back_button.pressed.connect(show_main)


func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled and is_open():
		resume_game()


### 打开菜单时是否冻结世界。
##
### 联机里被改成 false 时，如果菜单正开着就顺手解冻 ——
### 否则会留下"世界已经冻住，但没有任何人有权限解冻"的瞬间。
func set_pausable(value: bool) -> void:
	_can_freeze = value
	if not _can_freeze and get_tree().paused:
		get_tree().paused = false
	_refresh_texts()


func is_open() -> bool:
	return _root.visible


func can_open() -> bool:
	return enabled and not GameState.ui_captures_input and not get_tree().paused


func open_pause() -> bool:
	if not can_open():
		return false
	_root.visible = true
	_leave_armed = false
	show_main()
	GameState.claim_ui("pause")
	# ★ 只有被允许时才冻结。联机里这一行不执行，世界照常跑。
	if _can_freeze:
		get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_texts()
	_resume_button.grab_focus()
	return true


func resume_game() -> void:
	if not is_open():
		return
	_root.visible = false
	_leave_armed = false
	_leave_button.text = "返回开始页"
	if get_tree().paused:
		get_tree().paused = false
	GameState.release_ui("pause")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func show_guide() -> void:
	if not is_open():
		return
	_main_view.visible = false
	_guide_view.visible = true
	_guide_scroll.scroll_vertical = 0
	_back_button.grab_focus()


func show_main() -> void:
	_main_view.visible = true
	_guide_view.visible = false
	_leave_button.text = "再点一次确认离开" if _leave_armed else "返回开始页"
	_resume_button.grab_focus()


### 返回开始页：结束这一局，回到「单机 / 联机」的选择。
##
### ★ 为什么要二次确认：
##   联机里点它等于把服务器关掉，别人会被踢出去，而且不可撤销。
##   一次点击就能干这事，迟早误触。用"3 秒内再点一次"实现，
##   不额外开对话框、不引入新场景，也就不用保存任何跨帧状态。
func request_leave() -> void:
	if _leave_armed:
		do_leave()
		return
	_leave_armed = true
	_leave_button.text = "再点一次确认离开"
	get_tree().create_timer(3.0).timeout.connect(_disarm_leave)


func _disarm_leave() -> void:
	# 场景可能已经换掉了（第二次点击生效后这个节点会被 free），先确认自己还在。
	if not is_inside_tree() or not _leave_armed:
		return
	_leave_armed = false
	_leave_button.text = "返回开始页"


### 真正的离开交给 AccountSession：它知道要先存盘、要关 peer、要清输入锁。
##  菜单只负责"问一句"，不重复实现那套流程。
func do_leave() -> void:
	_resume_button.disabled = true
	_guide_button.disabled = true
	_leave_button.disabled = true
	_quit_button.disabled = true
	_leave_button.text = "正在保存…"
	AccountSession.leave_to_start()


func quit_game() -> void:
	get_tree().paused = false
	GameState.release_ui("pause")
	get_tree().quit()


### 文案跟着"会不会真的冻结"变。
##
### 联机里还写「游戏暂停 · 世界已冻结」就是在骗人：
### 世界没停，你只是打开了菜单，站在那儿挨打。
func _refresh_texts() -> void:
	if _can_freeze:
		_title.text = "游戏暂停"
		_subtitle.text = "单机模式 · 世界、敌人与计时已冻结"
		_resume_button.text = "继续游戏"
		_footer.text = "按 Esc 也可以继续"
	else:
		_title.text = "游戏菜单"
		_subtitle.text = "联机中 · 世界仍在运行（本局不会暂停）"
		_resume_button.text = "回到游戏"
		_footer.text = "按 Esc 也可以回到游戏"


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return

	if is_open():
		if _guide_view.visible:
			show_main()
		else:
			resume_game()
		get_viewport().set_input_as_handled()
	elif can_open():
		open_pause()
		get_viewport().set_input_as_handled()
