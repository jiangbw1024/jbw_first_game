extends Interactable
## 商店老板：站着不动，被瞄准时说一句话，交互时请求开面板
##
## 注意 `interact()` 里**只发信号**，不直接买、也不直接开 UI。
## 这样 NPC 既不知道面板存在，也不知道价格 —— 换一个 UI 或换一个购买流程都不用动它。

var npc_id := 1


func _ready() -> void:
	super()
	display_name = "商店老板"
	# 老板站在门内 2 米，玩家站在门口就是 3 米开外。
	# 默认的 3.5 米太紧，稍微偏一点提示就不见了 —— 放宽到 4.5，可以隔着门框交谈。
	interact_reach = 4.5


func prompt_text(_who: Node3D) -> String:
	return "与商店老板交易"


func interact(_who: Node3D) -> void:
	GameState.shop_requested.emit(npc_id)
