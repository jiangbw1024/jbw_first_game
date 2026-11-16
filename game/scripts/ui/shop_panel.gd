extends Control
## 商店面板
##
## 它只做三件事：列商品、把点击转成一个信号、管好输入锁。
## **它不知道服务器在哪、也不知道买成没成功** ——
## 那些都在 ShopService 里。UI 与权威逻辑分开，才能保证"点得再乱也改不了世界"。

var _npc_id := 0

@onready var items_box: VBoxContainer = $Panel/VBox/Items


func _ready() -> void:
	visible = false
	GameState.shop_requested.connect(_open)
	_build_rows()


func _build_rows() -> void:
	for it in Goods.LIST:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)

		var label := Label.new()
		label.text = "%s　¥%d" % [it["name"], int(it["price"])]
		label.add_theme_font_size_override("font_size", 18)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var btn := Button.new()
		btn.text = "购买"
		btn.custom_minimum_size = Vector2(96, 0)
		btn.pressed.connect(_on_buy.bind(int(it["id"])))

		row.add_child(label)
		row.add_child(btn)
		items_box.add_child(row)


func _open(npc_id: int) -> void:
	_npc_id = npc_id
	visible = true
	# 只 claim 自己那一份：聊天如果开着，锁不会因为我们开而丢失
	GameState.claim_ui("shop")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	if not visible:
		return
	visible = false
	GameState.release_ui("shop")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_buy(item_id: int) -> void:
	# 只表达意图。价格、距离、合法性全在服务器那一侧判定。
	GameState.buy_requested.emit(item_id)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	# 节点被强删（比如换场景）时也要把锁还回去，否则角色永远动不了
	GameState.release_ui("shop")
