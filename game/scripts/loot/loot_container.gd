extends Interactable
## S11 · 可搜刮的容器（木箱 / 铁柜）
##
## ★ 容器和掉落物的区别只有一条：**内容物在打开那一刻才生成**。
##   如果容器在 _ready 里就把东西 roll 好，客户端只要看一眼内存就知道里面有什么
##   （改客户端的人甚至能提前看到"这个箱子里有急救包"，然后只搜那几个）。
##   开门抽奖 = 服务器在 rpc 处理里 roll，抽完立刻结算。
##
## ★ 一次性：搜完变空箱子。为什么不做"定时补充"：
##   补货会让玩家守在箱子旁边刷，而拾荒的张力来自"要不要往深处走"。
##   补给点应该是**冒险的奖赏**，不是蹲守的收益。
##
## ★ loot_seed：正常游玩时是 0（每次随机），自检时传一个固定值 ——
##   测试要能复现，"这次 roll 出什么"不能是运气。

@export var loot_seed := 0
## 注意不能写成 `@export var display_name := "木箱"` ——
## 父类 Interactable 已经有 display_name，子类重新声明同名成员会直接解析报错
@export var title := "木箱"

## chance 是**独立判定**（每个条目各自掷一次），不是权重。
## 这样"一个箱子里同时有布料和金属"很自然 —— 现实里也是这样。
const LOOT_TABLE := [
	{"id": ItemDef.CLOTH, "chance": 0.55, "min": 1, "max": 3},
	{"id": ItemDef.SCRAP, "chance": 0.62, "min": 2, "max": 5},
	{"id": ItemDef.WOOD, "chance": 0.45, "min": 2, "max": 4},
	{"id": ItemDef.MEDKIT, "chance": 0.28, "min": 1, "max": 1},
	{"id": ItemDef.AMMO, "chance": 0.40, "min": 12, "max": 24},
]

var looted := false

var _lid: Node3D
var _boards: Array = []
var _mats: Array = []


func _ready() -> void:
	super()
	# ★ 箱子额外占一层 WORLD：它是个实物，玩家应该撞得到。
	#   父类默认只给 INTERACT（那是给 NPC 和掉落物的 —— 人不能被"挡住"，
	#   小物件也不该绊脚）。一个 0.8 米的木箱如果可以穿过去，比穿模还出戏。
	#   加上 WORLD 之后：玩家会被挡（玩家 mask 含 WORLD），射线照样打得到。
	collision_layer = Layers.INTERACT | Layers.WORLD
	display_name = title
	interact_reach = 3.2
	_build()


func _build() -> void:
	var wood := _mat(Color(0.30, 0.21, 0.12))
	var band := _mat(Color(0.26, 0.27, 0.28))

	# 箱体四面 + 底
	_box(Vector3(0.78, 0.56, 0.05), Vector3(0, 0.28, -0.36), wood)   # 后
	_box(Vector3(0.78, 0.56, 0.05), Vector3(0, 0.28, 0.36), wood)    # 前
	_box(Vector3(0.05, 0.56, 0.72), Vector3(-0.36, 0.28, 0), wood)   # 左
	_box(Vector3(0.05, 0.56, 0.72), Vector3(0.36, 0.28, 0), wood)    # 右
	_box(Vector3(0.80, 0.05, 0.76), Vector3(0, 0.02, 0), wood)       # 底

	# 铁箍：两道竖箍，木箱的辨识度基本来自它
	_box(Vector3(0.82, 0.04, 0.06), Vector3(0, 0.20, -0.18), band)
	_box(Vector3(0.82, 0.04, 0.06), Vector3(0, 0.20, 0.18), band)

	# 盖子单独一个节点：打开时只转它，箱体不动
	_lid = Node3D.new()
	# 支点放在后沿，这样掀盖是"往后翻"而不是"原地转"
	_lid.position = Vector3(0, 0.55, -0.36)
	add_child(_lid)
	var lid_box := _box(Vector3(0.80, 0.07, 0.76), Vector3(0, 0.03, 0.36), wood, _lid)
	lid_box.name = "LidBoard"
	_box(Vector3(0.82, 0.05, 0.06), Vector3(0, 0.07, 0.18), band, _lid)


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.88
	# 木头几乎没有镜面反射（S9.7：留默认 0.5 会被环境反成灰白）
	m.metallic_specular = 0.08
	_mats.append({"mat": m, "base": color})
	return m


func _box(size: Vector3, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	(parent if parent != null else self).add_child(mi)
	_boards.append(mi)
	return mi


# ------------------------------------------------------------
# 交互
# ------------------------------------------------------------
func prompt_text(_who: Node3D) -> String:
	if looted:
		return "「%s」已经搜过了" % display_name
	return "按 E 搜刮「%s」" % display_name


func can_interact(_who: Node3D) -> bool:
	# 搜过的箱子仍然允许交互 —— 让提示还在，只是说"已经搜过了"。
	# 直接返回 false 会让提示消失，玩家会以为箱子坏了或者自己站错位置
	return true


func interact(who: Node3D) -> void:
	if looted:
		Sfx.play_ui("dry_fire", -16.0, 0.6)
		return
	if multiplayer.is_server():
		_server_open(who)
	else:
		rpc_id(1, "_request_open")


@rpc("any_peer", "call_remote", "reliable")
func _request_open() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var p := _player_by_id(sender)
	if p != null:
		_server_open(p)


func _server_open(p: Node3D) -> void:
	if looted:
		return
	if p.global_position.distance_to(global_position) > interact_reach + 1.5:
		return
	if not p.has_method("add_item"):
		return

	looted = true
	var items := _roll()
	var got_text: Array[String] = []
	var full := false
	for e in items:
		var id := String(e[0])
		var n := int(e[1])
		var got: int = p.add_item(id, n)
		if got > 0:
			got_text.append("%s ×%d" % [ItemDef.name_of(id), got])
		if got < n:
			full = true

	# 先把"箱子开了"广播出去：视觉状态是所有人共享的
	_opened.rpc()

	if p.is_local():
		Sfx.play_ui("loot_open", -4.0)
		if got_text.is_empty():
			GameState.notify.emit("「%s」是空的" % display_name, 2.0)
		else:
			GameState.notify.emit("搜到：" + "、".join(got_text), 3.0)
			if full:
				# 部分装不下时要说清楚，否则玩家会以为"东西少了是 bug"
				GameState.notify.emit("背包已满，部分物资留在了箱子里", 2.6)


### 独立掷骰，每个条目一次。
## 至少保证有一件东西：完全空的箱子（约 5% 概率）会让玩家怀疑"是不是没搜到"，
## 而"搜到一件破布"至少证明了机制在工作 —— 这是体验问题，不是真实性问题。
func _roll() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = loot_seed if loot_seed != 0 else randi()
	var out: Array = []
	for entry in LOOT_TABLE:
		if rng.randf() < float(entry["chance"]):
			out.append([String(entry["id"]), rng.randi_range(int(entry["min"]), int(entry["max"]))])
	if out.is_empty():
		out.append([ItemDef.CLOTH, 1])
	return out


@rpc("authority", "call_local", "reliable")
func _opened() -> void:
	looted = true
	# 掀盖：绕后沿转 105°，0.35 秒。
	# 这个动作本身没有游戏作用，但"盖子开了"是玩家确认"我搜到了"的视觉证据
	var t := create_tween()
	t.tween_property(_lid, "rotation:x", deg_to_rad(-105.0), 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 内壁变暗：空箱子应该有"被翻过"的样子
	for e in _mats:
		var m: StandardMaterial3D = e["mat"]
		m.albedo_color = (e["base"] as Color).darkened(0.35)


func _player_by_id(id: int) -> Node3D:
	var players := get_tree().current_scene.get_node_or_null("Players")
	if players == null:
		return null
	return players.get_node_or_null(str(id)) as Node3D
