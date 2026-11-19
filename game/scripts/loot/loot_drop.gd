extends Interactable
## S11 · 地上的掉落物
##
## ★ 权威链路和商店/战斗完全一样（第三次复用，说明它是通用形状）：
##     客户端：interact() → rpc_id(1, "_request_pickup")
##     服务器：校验距离 → 改背包 → 广播"这堆还剩多少"
##   客户端**不能**自己把东西塞进背包 —— 否则把 RPC 里的 amount 改成 999
##   就是无限物资。所有"账本型"操作都必须有一个服务器盖章的地方。
##
## ★ 为什么不自动拾取：
##   自动拾取看起来很顺，但它会让玩家在战斗中"无意间"装满背包，
##   然后捡不到真正需要的东西。按 E 是一次**明确的决定**，
##   而拾荒游戏的核心乐趣恰恰就是"决定带什么"。这也和商店、搜箱统一。
##
## ★ 部分拾取：背包只剩 1 格时捡 20 个废金属，应该是"拿走 20，剩 4 留地上"，
##   而不是"背包满了，一个都不给"。后者的体验是"游戏在拒绝我"。

const FLOAT_AMP := 0.06
const FLOAT_SPEED := 2.2
const SPIN_SPEED := 0.9
## 名字标签只在这么近才显示。远处的掉落物不需要标签 ——
## 一起显示会让地面变成一片文字，反而看不见东西在哪
const LABEL_DISTANCE := 9.0

@export var item_id := ""
@export var amount := 1

var _float_t := 0.0
var _mesh: MeshInstance3D
var _label: Label3D
## 已经被人捡走了：留在原地等 queue_free，但拒绝再次交互。
## 不加这个判断的话，两个人同时按 E 会各拿一份（典型的"重放攻击"）
var _taken := false


func _ready() -> void:
	super()
	display_name = ItemDef.name_of(item_id)
	interact_reach = 3.0
	_float_t = randf() * TAU

	var col := ItemDef.color_of(item_id)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.55
	mat.metallic_specular = 0.20
	# ★ 自发光：末日题材室外偏灰暗，纯漫反射的小方块在草地里根本找不着。
	#   给一点 emission 相当于"游戏在告诉你这里有东西"，
	#   比加一盏 OmniLight 便宜得多（灯是有实时光照成本的）
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 0.55

	_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = _shape_size()
	_mesh.mesh = bm
	_mesh.material_override = mat
	_mesh.position.y = 0.16
	# 小物件不投影：一枚弹匣在草地上拖一道影子，看起来像 bug
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

	# 掉在箱子顶上的东西会浮在半空，稍微抬高一点点让它"贴"在地面上
	# 标签抬到 0.55：几个掉落物挨在一起时，0.42 会让文字和隔壁的方块叠上，
	# 读起来是一团糊。抬高一点之后，即使重叠也能各自读清楚
	_label = Label3D.new()
	_label.position = Vector3(0, 0.55, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 44
	_label.pixel_size = 0.0035
	_label.outline_size = 8
	_label.modulate = Color(1.0, 0.94, 0.78)
	_label.text = ""
	add_child(_label)
	_refresh_label()


func _shape_size() -> Vector3:
	match ItemDef.kind_of(item_id):
		"ammo":
			return Vector3(0.20, 0.12, 0.26)
		"consumable":
			return Vector3(0.24, 0.15, 0.18)
		_:
			return Vector3(0.21, 0.14, 0.21)


func _process(delta: float) -> void:
	if _taken:
		return
	# 浮动 + 自转。不用物理刚体：一个"会晃的小方块"已经足够表达"可以捡"，
	# 而物理体会让它们互相碰撞、滚进墙缝，玩家反而找不到
	_float_t += delta * FLOAT_SPEED
	# ★ 浮动只改**子网格**的 y，绝不改节点自己的 position。
	#   第一版我写的是 `position.y = _base_y + sin(...)`，
	#   而 _base_y 是在 _ready 里记的 —— 那时节点还没被摆到正确高度，
	#   于是每帧都把整个掉落物拉回 y≈0，全部沉到地形以下（截图里一个都看不见）。
	#   教训：动画不该拥有节点的位置，位置属于"谁创建了它"。
	if _mesh != null:
		_mesh.position.y = 0.16 + sin(_float_t) * FLOAT_AMP
		_mesh.rotation.y += delta * SPIN_SPEED

	# 标签按相机距离显隐。用相机而不是玩家节点：
	# 相机永远存在且就是"玩家当前看到的东西"
	if _label != null:
		var cam := get_viewport().get_camera_3d()
		var near := cam != null and cam.global_position.distance_to(global_position) < LABEL_DISTANCE
		_label.visible = near


func _refresh_label() -> void:
	if _label == null:
		return
	_label.text = "%s ×%d" % [ItemDef.name_of(item_id), amount]


# ------------------------------------------------------------
# 交互
# ------------------------------------------------------------
func can_interact(_who: Node3D) -> bool:
	return not _taken and amount > 0


func prompt_text(_who: Node3D) -> String:
	return "拾取「%s」×%d" % [ItemDef.name_of(item_id), amount]


func interact(who: Node3D) -> void:
	if _taken:
		return
	# 单机和主机都是"我就是服务器"，直接走同一条处理路径，
	# 保证两条路只有一份实现（否则单机调好了、联机时才炸）
	if multiplayer.is_server():
		_server_pickup(who)
	else:
		rpc_id(1, "_request_pickup")


@rpc("any_peer", "call_remote", "reliable")
func _request_pickup() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		# 单人游戏里自己调用自己时 sender 是 0，兜底用本机 id
		sender = multiplayer.get_unique_id()
	var p := _player_by_id(sender)
	if p == null:
		return
	_server_pickup(p)


### ★ 服务器权威的唯一入口。
## 距离用**服务器看到的玩家位置**量，不信客户端上报的坐标 ——
## 这和商店的距离校验是同一件事，只是换个场景。
func _server_pickup(p: Node3D) -> void:
	if _taken or amount <= 0:
		return
	# 容差 1.2：玩家按 E 的那一刻可能正在移动，严格相等会频繁"点了没反应"
	if p.global_position.distance_to(global_position) > interact_reach + 1.2:
		return
	if not p.has_method("add_item"):
		return

	var got: int = p.add_item(item_id, amount)
	if got <= 0:
		if p.is_local():
			GameState.notify.emit("背包已满", 1.8)
		return

	amount -= got
	if amount <= 0:
		_taken = true
		# 广播：所有端都把这个节点删掉。
		# 不直接 queue_free()，因为客户端上的这个节点是**另一份副本**，
		# 服务器删自己那份不会影响它
		_consumed.rpc()
	else:
		_sync_amount.rpc(amount)

	if p.is_local():
		Sfx.play_ui("pickup", -6.0, randf_range(0.95, 1.05))
		GameState.notify.emit("拾取 %s ×%d" % [ItemDef.name_of(item_id), got], 1.8)


@rpc("authority", "call_local", "reliable")
func _sync_amount(n: int) -> void:
	amount = n
	_refresh_label()


@rpc("authority", "call_local", "reliable")
func _consumed() -> void:
	_taken = true
	# 留一帧再删：正在显示提示的那个 Label 还在走，
	# 同一个物理帧里删节点会让"刚捡起来的东西闪一下"
	queue_free()


func _player_by_id(id: int) -> Node3D:
	# 掉落物挂在 `Loot` 节点下，它的父节点是容器而不是世界 ——
	# 所以必须从 current_scene 顺着 Players 找，不能 get_parent()
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var players := scene.get_node_or_null("Players")
	if players == null:
		return null
	return players.get_node_or_null(str(id)) as Node3D
