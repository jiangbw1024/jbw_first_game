class_name GameHud
extends CanvasLayer
## S4 · HUD：在线人数、RTT、聊天、断线提示
##
## S8 增补：交互提示（Prompt）与自动消失的 toast。
## 三种信息的生命周期不同，所以分三个通道，不共用一个 Label：
##   Hint   —— 常驻操作说明（左上）
##   Prompt —— 眼前这一下的交互提示（准心下方，随瞄准变化）
##   Notice —— 一次性消息（居中，几秒后自己消失）

const PING_INTERVAL := 1.0
const MAX_CHAT_LENGTH := 200

@onready var players_label: Label = $Status/Players
@onready var rtt_label: Label = $Status/Rtt
@onready var chat_log: RichTextLabel = $ChatLog
@onready var chat_input: LineEdit = $ChatInput
@onready var notice: Label = $Notice
@onready var prompt: Label = $Prompt
@onready var ammo_label: Label = $Ammo
@onready var ammo_hint: Label = $AmmoHint

var _ping_accum := 0.0
var _rtt_ms := -1

# ---- 战斗 UI（S10）----
var _hp_bg: ColorRect
var _hp_fill: ColorRect
var _hp_text: Label
var _vignette: ColorRect
var _vignette_mat: ShaderMaterial
var _vignette_intensity := 0.0
var _death_layer: Control
var _death_title: Label

# ---- 背包（S11）----
var _bag_root: Control
var _bag_title: Label
var _bag_cells: Array = []
var _bag_open := false


func _ready() -> void:
	chat_input.text_submitted.connect(_on_chat_submitted)
	_add_line("[color=#8fd6b4]系统[/color] 按 Enter 打开聊天，Esc 取消")
	GameState.prompt_changed.connect(_on_prompt_changed)
	GameState.notify.connect(func(t: String, secs: float) -> void: toast(t, secs))
	GameState.ammo_changed.connect(_on_ammo_changed)
	_on_prompt_changed("")
	_build_combat_ui()
	GameState.health_changed.connect(_on_health_changed)
	GameState.hurt.connect(_on_hurt)
	GameState.death_changed.connect(_on_death_changed)
	_on_health_changed(GameState.player_health, GameState.player_health_max)
	_build_bag_ui()
	GameState.inventory_changed.connect(_on_inventory_changed)


# ------------------------------------------------------------
# 背包面板（S11）
# ------------------------------------------------------------
### 为什么用 4×3 的固定网格，而不是"有东西就长一行的列表"：
##   固定网格让"还剩几格"这件事**一眼可见** —— 空格子是空的，玩家扫一眼就知道
##   自己还能装几样。列表只会告诉你"有 8 样东西"，不会告诉你"你还有多少余地"。
##   背包的压力必须能被看见，否则它只是一串数字。
const BAG_COLS := 4

func _build_bag_ui() -> void:
	_bag_root = Control.new()
	_bag_root.anchor_right = 1.0
	_bag_root.anchor_bottom = 1.0
	_bag_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_root.visible = false
	add_child(_bag_root)

	# 背景整块压暗：打开背包时视线该收回来，不该还盯着远处的丧尸
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.03, 0.55)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_root.add_child(dim)

	# 面板本身
	var panel := ColorRect.new()
	panel.color = Color(0.055, 0.06, 0.065, 0.94)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -250.0
	panel.offset_right = 250.0
	panel.offset_top = -190.0
	panel.offset_bottom = 190.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_root.add_child(panel)

	var edge := ColorRect.new()
	edge.color = Color(0.42, 0.36, 0.22, 0.75)
	edge.anchor_left = 0.5
	edge.anchor_right = 0.5
	edge.anchor_top = 0.5
	edge.anchor_bottom = 0.5
	edge.offset_left = -250.0
	edge.offset_right = 250.0
	edge.offset_top = -190.0
	edge.offset_bottom = -186.0
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_root.add_child(edge)

	_bag_title = Label.new()
	_bag_title.text = "背包 0/12"
	_bag_title.anchor_left = 0.5
	_bag_title.anchor_right = 0.5
	_bag_title.anchor_top = 0.5
	_bag_title.anchor_bottom = 0.5
	_bag_title.offset_left = -250.0
	_bag_title.offset_right = 250.0
	_bag_title.offset_top = -178.0
	_bag_title.offset_bottom = -140.0
	_bag_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bag_title.add_theme_font_size_override("font_size", 24)
	_bag_title.add_theme_color_override("font_color", Color(0.88, 0.80, 0.58))
	_bag_root.add_child(_bag_title)

	var grid := GridContainer.new()
	grid.columns = BAG_COLS
	grid.anchor_left = 0.5
	grid.anchor_right = 0.5
	grid.anchor_top = 0.5
	grid.anchor_bottom = 0.5
	grid.offset_left = -226.0
	grid.offset_right = 226.0
	grid.offset_top = -128.0
	grid.offset_bottom = 150.0
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_root.add_child(grid)

	for i in Inventory.SLOTS:
		var cell := ColorRect.new()
		cell.color = Color(0.10, 0.11, 0.115, 0.95)
		cell.custom_minimum_size = Vector2(104, 74)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(cell)

		var nm := Label.new()
		nm.anchor_right = 1.0
		nm.offset_left = 6.0
		nm.offset_top = 6.0
		nm.offset_right = -6.0
		nm.offset_bottom = 40.0
		nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nm.add_theme_font_size_override("font_size", 15)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(nm)

		var ct := Label.new()
		ct.anchor_right = 1.0
		ct.anchor_bottom = 1.0
		ct.offset_left = 6.0
		ct.offset_top = 44.0
		ct.offset_right = -8.0
		ct.offset_bottom = -4.0
		ct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ct.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		ct.add_theme_font_size_override("font_size", 19)
		ct.add_theme_color_override("font_color", Color(0.95, 0.88, 0.66))
		ct.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(ct)

		_bag_cells.append({"bg": cell, "name": nm, "count": ct})

	var hint := Label.new()
	hint.text = "Tab 关闭　　H 使用急救包"
	hint.anchor_left = 0.5
	hint.anchor_right = 0.5
	hint.anchor_top = 0.5
	hint.anchor_bottom = 0.5
	hint.offset_left = -250.0
	hint.offset_right = 250.0
	hint.offset_top = 156.0
	hint.offset_bottom = 186.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.60, 0.60, 0.58))
	_bag_root.add_child(hint)


func _on_inventory_changed(inv) -> void:
	if _bag_cells.is_empty() or inv == null:
		return
	var used: int = inv.used_slots()
	_bag_title.text = "背包 %d/%d" % [used, Inventory.SLOTS]
	for i in _bag_cells.size():
		var cell: Dictionary = _bag_cells[i]
		var slot: Dictionary = inv.slots[i] if i < inv.slots.size() else {}
		var nm: Label = cell["name"]
		var ct: Label = cell["count"]
		var bg: ColorRect = cell["bg"]
		if slot.is_empty():
			nm.text = ""
			ct.text = ""
			bg.color = Color(0.085, 0.09, 0.095, 0.9)
			continue
		var id := String(slot["id"])
		var n := int(slot["count"])
		var col := ItemDef.color_of(id)
		nm.text = ItemDef.name_of(id)
		nm.add_theme_color_override("font_color", col.lightened(0.35))
		ct.text = "×%d" % n
		# 格子底色用物品色的极暗版本：一眼能分辨类别，又不刺眼
		bg.color = Color(col.r * 0.22 + 0.07, col.g * 0.22 + 0.075, col.b * 0.22 + 0.08, 0.95)


func _toggle_bag() -> void:
	_bag_open = not _bag_open
	_bag_root.visible = _bag_open
	if _bag_open:
		# 复用 UI 锁：开着背包时不该还能走路开枪。
		# 和聊天、商店、死亡共用同一套机制 —— 这就是 S8 那个设计的第三次还债
		GameState.claim_ui("bag")
		var inv = _find_local_inventory()
		if inv != null:
			_on_inventory_changed(inv)
	else:
		GameState.release_ui("bag")


func _close_bag() -> void:
	if not _bag_open:
		return
	_bag_open = false
	_bag_root.visible = false
	GameState.release_ui("bag")


### HUD 不持有背包数据，只从本地玩家节点上取一份来画
func _find_local_inventory():
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var players := scene.get_node_or_null("Players")
	if players == null:
		return null
	for p in players.get_children():
		if p.has_method("is_local") and p.is_local() and "inventory" in p:
			return p.inventory
	return null


# ------------------------------------------------------------
# 战斗 UI：血条 / 受伤红边 / 死亡遮罩
# ------------------------------------------------------------
### 为什么用代码建而不是写在 .tscn 里：
## 红边需要一个内联 shader，血条的宽度要按比例改 anchor。
## 这两件事在场景文件里都是几行难读的文本，写成代码反而更清楚"它在干什么"。
func _build_combat_ui() -> void:
	# ---- 血条（左下角）----
	_hp_bg = ColorRect.new()
	_hp_bg.color = Color(0.03, 0.03, 0.03, 0.55)
	_hp_bg.anchor_top = 1.0
	_hp_bg.anchor_bottom = 1.0
	_hp_bg.offset_left = 40.0
	_hp_bg.offset_top = -78.0
	_hp_bg.offset_right = 300.0
	_hp_bg.offset_bottom = -42.0
	_hp_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hp_bg)

	_hp_fill = ColorRect.new()
	_hp_fill.color = Color(0.72, 0.16, 0.14)
	# ★ 用 anchor 控制宽度，而不是算像素：
	#   anchor_right = 0.5 就表示"占父容器一半"，缩放窗口时自动跟着变，
	#   不需要去查父节点此刻到底多宽
	_hp_fill.anchor_right = 1.0
	_hp_fill.anchor_bottom = 1.0
	_hp_fill.offset_left = 3.0
	_hp_fill.offset_top = 3.0
	_hp_fill.offset_right = -3.0
	_hp_fill.offset_bottom = -3.0
	_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_bg.add_child(_hp_fill)

	_hp_text = Label.new()
	_hp_text.anchor_left = 1.0
	_hp_text.anchor_right = 1.0
	_hp_text.anchor_bottom = 1.0
	_hp_text.offset_left = 10.0
	_hp_text.offset_right = 80.0
	_hp_text.offset_bottom = 0.0
	_hp_text.add_theme_font_size_override("font_size", 20)
	_hp_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_hp_text.add_theme_constant_override("outline_size", 6)
	_hp_bg.add_child(_hp_text)

	# ---- 受伤红边 ----
	# 用 shader 画"从边缘往中间渐隐的红"，比准备一张 1080p 的 PNG 便宜得多，
	# 而且强度可以每帧改
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform float intensity = 0.0;
uniform float dir_deg = 0.0;

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d * vec2(1.0, 1.26));
	// ★ 起始值不能太小。0.26 会让红色覆盖到大半个屏幕，像沙尘暴；
	//   0.42 起步只让真正的边缘泛红，视线中心保持干净
	float edge = smoothstep(0.36, 0.82, r);
	// 朝受击方向的一侧更红，给玩家"哪边挨打了"的直觉。
	// atan(d.x, -d.y)：正上方 = 0°，右侧 = +90°，和 GameState.hurt 的角度约定一致
	float ang = degrees(atan(d.x, -d.y));
	float bias = 0.55 + 0.45 * cos(radians(ang - dir_deg));
	COLOR = vec4(0.62, 0.03, 0.03, edge * intensity * bias);
}
"""
	_vignette_mat = ShaderMaterial.new()
	_vignette_mat.shader = sh

	_vignette = ColorRect.new()
	_vignette.material = _vignette_mat
	_vignette.color = Color(1, 1, 1, 1)
	_vignette.anchor_right = 1.0
	_vignette.anchor_bottom = 1.0
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)

	# ---- 死亡遮罩 ----
	_death_layer = Control.new()
	_death_layer.anchor_right = 1.0
	_death_layer.anchor_bottom = 1.0
	_death_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_layer.visible = false
	add_child(_death_layer)

	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.0, 0.0, 0.62)
	shade.anchor_right = 1.0
	shade.anchor_bottom = 1.0
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_layer.add_child(shade)

	_death_title = Label.new()
	_death_title.text = "你倒下了"
	_death_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_death_title.anchor_right = 1.0
	_death_title.anchor_bottom = 1.0
	_death_title.add_theme_font_size_override("font_size", 44)
	_death_title.add_theme_color_override("font_color", Color(0.85, 0.25, 0.22, 1))
	_death_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_death_title.add_theme_constant_override("outline_size", 8)
	_death_layer.add_child(_death_title)


func _on_health_changed(hp: float, max_hp: float) -> void:
	var ratio := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
	_hp_fill.anchor_right = ratio
	_hp_text.text = "%d" % int(ceil(hp))
	# 低血时改用亮红：数字本身也要参与"我很危险"的表达，
	# 只靠长度变化，玩家在交火中根本注意不到
	_hp_fill.color = Color(0.86, 0.14, 0.10) if ratio < 0.3 else Color(0.62, 0.20, 0.16)


func _on_hurt(dir_deg: float, amount: float) -> void:
	# 伤害越重红得越狠，但给一个下限，否则"被小怪摸一下"完全没有反馈
	_vignette_intensity = minf(1.0, _vignette_intensity + clampf(amount / 35.0, 0.30, 1.0))
	_vignette_mat.set_shader_parameter("intensity", _vignette_intensity)
	_vignette_mat.set_shader_parameter("dir_deg", dir_deg)


func _on_death_changed(is_dead: bool) -> void:
	_death_layer.visible = is_dead
	# 死了要收起背包：否则重生回来背包还开着，角色动不了，
	# 玩家会以为"复活失败"
	if is_dead:
		_close_bag()
		_death_title.text = "你倒下了\n3 秒后回到出生点"


# ------------------------------------------------------------
# 输入：聊天框的开关
# ------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("chat") and not chat_input.visible:
		_open_chat()
		# 把事件标记为"已处理"，后面的角色就不会再收到它
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("backpack") and not chat_input.visible:
		# 聊天框开着时不能开背包：Tab 在 LineEdit 里是"切换焦点"，
		# 两件事抢同一个键的结果一定是"打字打到一半背包弹出来"
		_toggle_bag()
		get_viewport().set_input_as_handled()
	elif chat_input.visible and event.is_action_pressed("ui_cancel"):
		_close_chat()
		get_viewport().set_input_as_handled()
	elif _bag_open and event.is_action_pressed("ui_cancel"):
		_close_bag()
		get_viewport().set_input_as_handled()


func _open_chat() -> void:
	chat_input.visible = true
	# ★ 关键一步：告诉角色"现在键盘归我"
	#   只靠 set_input_as_handled 是不够的 —— 角色读的是 Input 轮询状态，
	#   拦掉事件并不会让"W 正被按着"变成 False。必须显式上锁。
	GameState.claim_ui("chat")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	chat_input.grab_focus()


func _close_chat() -> void:
	chat_input.visible = false
	chat_input.text = ""
	chat_input.release_focus()
	# 只释放自己那一份。商店还开着的话，锁依然在。
	GameState.release_ui("chat")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ------------------------------------------------------------
# 状态显示 + RTT 测量
# ------------------------------------------------------------
func _process(delta: float) -> void:
	# 红边衰减。放在 _process 而不是 Tween 里，
	# 是因为连续挨打时它要能"叠加后继续衰减"，Tween 会被打断
	if _vignette_intensity > 0.0:
		_vignette_intensity = maxf(0.0, _vignette_intensity - delta * 1.7)
		_vignette_mat.set_shader_parameter("intensity", _vignette_intensity)

	# get_peers() 不包含自己，所以要 +1
	players_label.text = "在线：%d" % (multiplayer.get_peers().size() + 1)

	if multiplayer.is_server():
		rtt_label.text = "RTT：主机"
		return

	_ping_accum += delta
	if _ping_accum >= PING_INTERVAL:
		_ping_accum = 0.0
		# 用自己的本地时间戳发出去，对方原样回传 ——
		# 差值就是"一个来回"，不需要两台机器的时间同步。
		rpc_id(1, "_ping", Time.get_ticks_msec())
	rtt_label.text = "RTT：%s" % ("—" if _rtt_ms < 0 else "%d ms" % _rtt_ms)


@rpc("any_peer", "call_remote", "unreliable")
func _ping(stamp: int) -> void:
	if not multiplayer.is_server():
		return
	# 只回给发问的人
	_pong.rpc_id(multiplayer.get_remote_sender_id(), stamp)


@rpc("authority", "call_remote", "unreliable")
func _pong(stamp: int) -> void:
	_rtt_ms = Time.get_ticks_msec() - stamp


# ------------------------------------------------------------
# 聊天
# ------------------------------------------------------------
func _on_chat_submitted(text: String) -> void:
	var msg := text.strip_edges()
	_close_chat()
	if msg.is_empty():
		return

	if multiplayer.is_server():
		# 主机自己：直接走同一条广播路径，保证格式一致
		_post_chat.rpc(multiplayer.get_unique_id(), msg)
	else:
		rpc_id(1, "_request_chat", msg)


### 客户端 → 服务器：只请求"我要说话"
### 注意这里用 reliable：聊天丢一个字就变成另一句话了
@rpc("any_peer", "call_remote", "reliable")
func _request_chat(text: String) -> void:
	if not multiplayer.is_server():
		return
	# 服务端裁剪长度，防止有人发一个 10MB 的字符串把所有人卡死
	var safe := text.substr(0, MAX_CHAT_LENGTH)
	# ★ 为什么不让客户端直接广播？
	#   如果客户端能直接 rpc 给所有人，它就能**伪造成任何人的名字**发言。
	#   经服务器转发时，发言人身份由服务器用 get_remote_sender_id() 认定，
	#   客户端没有机会冒充。
	_post_chat.rpc(multiplayer.get_remote_sender_id(), safe)


### 服务器 → 所有人（call_local 让服务器自己也显示一遍）
@rpc("authority", "call_local", "reliable")
func _post_chat(sender_id: int, text: String) -> void:
	var who := "我" if sender_id == multiplayer.get_unique_id() else "玩家 %d" % sender_id
	_add_line("[color=#9fc6ff]%s[/color]：%s" % [who, text])


func _add_line(line: String) -> void:
	chat_log.append_text(line + "\n")


# ------------------------------------------------------------
# 断线提示
# ------------------------------------------------------------
func show_notice(text: String) -> void:
	notice.text = text
	notice.visible = not text.is_empty()


# ------------------------------------------------------------
# 交互提示（准心下方，随瞄准实时变化）
# ------------------------------------------------------------
func _on_prompt_changed(text: String) -> void:
	prompt.text = text
	prompt.visible = not text.is_empty()


# ------------------------------------------------------------
# 一次性消息（自动消失）
# ------------------------------------------------------------
### 为什么不用 Tween / Timer 节点？
## 这里只需要"几秒后如果没被新消息顶掉就清空"，await 计时器是最短的写法。
## 注意那个 `if notice.text == text` —— 它是防"旧消息的超时把新消息吃掉"。
func toast(text: String, secs := 2.0) -> void:
	notice.text = text
	notice.visible = true
	await get_tree().create_timer(secs).timeout
	if notice.text == text:
		notice.visible = false


# ------------------------------------------------------------
# 弹药
# ------------------------------------------------------------
### 余弹低于 1/4 时变红，空仓时提示换弹 —— 这两个提示都很小，
## 但少了它们玩家会在关键时刻"以为还有子弹"。
func _on_ammo_changed(mag: int, reserve: int, reloading: bool) -> void:
	ammo_label.text = "%d / %d" % [mag, reserve]
	ammo_label.modulate = Color(1.0, 0.55, 0.45) if mag <= 7 else Color(1, 1, 1)
	if reloading:
		ammo_hint.text = "换弹中…"
	elif mag == 0:
		ammo_hint.text = "按 R 换弹"
	else:
		ammo_hint.text = ""
