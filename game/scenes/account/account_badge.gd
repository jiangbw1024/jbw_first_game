extends CanvasLayer
## 主场景左上角的账号标记 + 退出登录
##
## ★ 为什么单独一个 CanvasLayer：
##   账号 UI 不改暂停菜单和 HUD。这个层放在世界节点下，排序盖过暂停菜单
##   （layer 120 > 100），玩家按 Esc 释放鼠标后仍然可以点到排行榜和退出登录。
##   它只调用 AccountSession，不碰游戏逻辑。
##
## process_mode = ALWAYS：暂停时按钮必须还能响应，否则暂停菜单一开
## 这个层就跟着冻结，退出登录会变成"看得见、点不动"。

@onready var _meta_label: Label = $Root/Panel/HBox/VBox/Meta
@onready var _account_label: Label = $Root/Panel/HBox/VBox/Account
@onready var _status_label: Label = $Root/Panel/HBox/VBox/Status
@onready var _leaderboard_button: Button = $Root/Panel/HBox/VBox/Leaderboard
@onready var _logout_button: Button = $Root/Panel/HBox/VBox/Logout


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_leaderboard_button.pressed.connect(_on_leaderboard_pressed)
	_logout_button.pressed.connect(_on_logout_pressed)


### cloud=false：这一局用的是本地档案（单机）。
##
### ★ 为什么按钮文案要跟着后端变：
##   单机里"退出登录"这个说法是假的 —— 没有账号可登出，实际行为是
##   "存盘并回开始页"。上一版文案骗人，玩家点完发现没退出，会以为坏了
##   （而实际上它确实什么都没做，见 AccountSession.logout_to_login 的注释）。
##   **按钮写什么，就必须真的做什么。**
func setup(username: String, cloud := true) -> void:
	_account_label.text = username
	_meta_label.text = "云端档案" if cloud else "本地档案"
	# 排行榜要 JWT。单机没有身份，点它只会静默失败，索性藏掉。
	_leaderboard_button.visible = cloud
	_logout_button.text = "退出登录" if cloud else "退出到开始页"


func set_sync_state(text: String) -> void:
	_status_label.text = text


func _on_leaderboard_pressed() -> void:
	AccountSession.open_leaderboard()


func _on_logout_pressed() -> void:
	_leaderboard_button.disabled = true
	_logout_button.disabled = true
	# 单机是"存盘后回开始页"，联机是"存盘后回登录页"，文案取共同部分。
	_status_label.text = "正在保存…"
	AccountSession.logout_to_login()
