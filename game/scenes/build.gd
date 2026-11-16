extends Node3D
## S7.5 · 模块化建造（支持竖直分层）
##
## 上一版的限制：占位键只有 (格子x, 格子z) 两维 —— 一格只能有一块，
## 于是"往上叠"永远被判定为"已占用"。这不是 bug，是**数据结构少了维**。
##
## 这一版加了第三个坐标：**层（level）**。
##   level 0 = 站在地面上
##   level N = 站在第 N-1 层的顶面上
##
## 关键设计：客户端只上报"我想放在哪一格、第几层"，
## **高度仍然由服务器算**（`_floor_y`）—— 因为"这一层的地面在哪"取决于
## 下面那块东西的顶面，而只有服务器知道全部建筑。
## 让客户端报高度，等于允许它把地板放在半空。

const PIECE_SCENE := preload("res://scenes/build_piece.tscn")
const PIECE_SCRIPT := preload("res://scenes/build_piece.gd")

const GRID := 2.0              # 网格边长（米）。全工程只在这里定义一次
const MAX_DISTANCE := 8.0      # 手臂长度：水平超过这个距离不许放
const MAX_PIECES := 400        # 世界总量上限，防止有人刷爆所有人内存
const FOUNDATION_THICK := 0.4
const WALL_HEIGHT := 2.4

const REACH_UP := 2.6          # 手能举多高（相对角色中心，约一臂长）
const REACH_DOWN := 3.0        # 能往下够多深

const KIND_FOUNDATION := "foundation"
const KIND_WALL := "wall"

const HINT_WALK := "WASD 移动 · 空格跳跃 · Shift 冲刺 · Enter 聊天 · B 建造 · 鼠标转视角 · ESC 释放鼠标"
const HINT_BUILD := "建造模式：左键放置 · 右键拆除 · 1 地基 / 2 墙 · R 旋转 · 对着顶面放可叠高 · 城镇内禁止建造 · B 退出"

@onready var terrain: TerrainBase = $"../Terrain"
@onready var hint: Label = $"../UI/Hint"
## S9 起准心改成了 Reticle（一个自绘的 Control，要随扩散实时张开）。
## 旧的 `UI/Crosshair` 已经不存在了，这里不再持有它：建造模式不需要改准心可见性。
## 城镇：只用来问"这里禁不禁建"。用软引用而不是 $ 硬路径 ——
## 场景树调整（比如把 Town 挪进子节点）时不会直接崩，只是功能降级。
@onready var town: TownBuilder = get_node_or_null("../Town") as TownBuilder

# id → {kind, cell, level, yaw, base, top, node}
var _pieces: Dictionary = {}
# 占位键（含层）→ id
var _occupied: Dictionary = {}
# "x:层:z" → 该层最高顶面高度。用来回答"第 N 层的地板有多高"
var _tops: Dictionary = {}
var _next_id := 1

var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _build_mode := false
var _kind := KIND_FOUNDATION
var _yaw := 0
var _cell := Vector2i.ZERO
var _level := 0
var _base_y := 0.0
var _has_target := false
var _aim_ok := false


func _ready() -> void:
	_build_ghost()
	# 客户端连上后主动要一份快照。让需要数据的一方主动请求，顺序永远是对的。
	multiplayer.connected_to_server.connect(_on_connected_to_server)


func _on_connected_to_server() -> void:
	rpc_id(1, "_request_snapshot")


# ============================================================
# 输入
# ============================================================
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("build_toggle"):
		_set_build_mode(not _build_mode)
		get_viewport().set_input_as_handled()
		return

	# 聊天框打开时不响应建造键，否则打字会顺手盖房子
	if not _build_mode or GameState.ui_captures_input:
		return

	if event.is_action_pressed("build_rotate"):
		_yaw = (_yaw + 90) % 360
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_1:
			_kind = KIND_FOUNDATION
		elif event.keycode == KEY_2:
			_kind = KIND_WALL
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_place()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_try_remove()
			get_viewport().set_input_as_handled()


func _set_build_mode(on: bool) -> void:
	_build_mode = on
	# 告诉其他系统"我在建造"：交互提示会让路，免得瞄墙放砖时弹出商店提示
	GameState.build_active = on
	if not on:
		_ghost.visible = false
	hint.text = HINT_BUILD if on else HINT_WALK
	print("[S7.5] 建造模式 %s" % ("开启" if on else "关闭"))


# ============================================================
# 瞄准：射线 → 命中面 → 决定格子与层
# ============================================================
func _process(_delta: float) -> void:
	if not _build_mode or GameState.ui_captures_input:
		_ghost.visible = false
		return
	_update_aim()


func _update_aim() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		_ghost.visible = false
		_has_target = false
		return

	var from := cam.global_position
	# 统一射线：与交互系统共用同一份实现，避免三处各写一遍再慢慢漂移
	var local := _local_player()
	var exclude: Array[RID] = []
	if local != null:
		exclude.append(local.get_rid())
	var hit := AimRay.cast(get_viewport(), exclude, MAX_DISTANCE * 3.0, Layers.AIM_MASK)
	if hit.is_empty():
		_ghost.visible = false
		_has_target = false
		return

	# 打到的是一块已造的棋子吗？
	var collider = hit.collider
	var hit_id := 0
	if collider != null and collider.has_meta("id"):
		hit_id = int(collider.get_meta("id"))

	if hit_id > 0 and _pieces.has(hit_id):
		# ★ 按命中面决定往哪放 —— 这是"能叠高"的关键
		var info: Dictionary = _pieces[hit_id]
		var n: Vector3 = hit.normal
		_cell = info["cell"]
		_level = int(info["level"])
		if n.y > 0.6:
			_level += 1                       # 顶面 → 叠到上一层
		elif n.y < -0.6:
			_ghost.visible = false            # 从下往上顶到地板底，不处理
			_has_target = false
			return
		else:
			# 侧面 → 同一层，贴着法线方向挪一格
			_cell += Vector2i(roundi(n.x), roundi(n.z))
	else:
		# 打到的是地形（没有 meta id）→ 第 0 层
		_cell = Vector2i(roundi(hit.position.x / GRID), roundi(hit.position.z / GRID))
		_level = 0

	var floor_y := _floor_y(_cell, _level)
	if is_nan(floor_y):
		# 这一层下面没有东西托着 —— 不给预览，避免"看起来能放其实不行"
		_ghost.visible = false
		_has_target = false
		return

	_base_y = floor_y
	_has_target = true

	var size := PIECE_SCRIPT.size_of(_kind)
	_ghost.mesh = _box(size)
	_ghost.rotation.y = deg_to_rad(float(_yaw))
	_ghost.position = Vector3(
		float(_cell.x) * GRID, _base_y + size.y * 0.5, float(_cell.y) * GRID)
	_ghost.visible = true

	var from_pos: Vector3 = local.global_position if local != null else from
	_aim_ok = _can_place(_kind, _cell, _level, _yaw, from_pos)
	_ghost_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.35) if _aim_ok else Color(1.0, 0.35, 0.3, 0.35)


# ============================================================
# 放置
# ============================================================
func _try_place() -> void:
	if not _has_target or not _aim_ok:
		return
	var local := _local_player()
	if local == null:
		return

	if multiplayer.is_server():
		_server_place(_kind, _cell, _level, _yaw, local.global_position)
	else:
		# 客户端只说"哪一格、第几层"。高度不由它决定。
		rpc_id(1, "_request_place", _kind, _cell, _level, _yaw)


### 服务器唯一入口：校验 → 计算 → 广播
func _server_place(kind: String, cell: Vector2i, level: int, yaw: int, from_pos: Vector3) -> bool:
	if not multiplayer.is_server():
		return false
	if not _can_place(kind, cell, level, yaw, from_pos):
		return false

	var id := _next_id
	_next_id += 1
	var base_y := _floor_y(cell, level)
	_apply_place.rpc(id, kind, cell, level, yaw, base_y)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _request_place(kind: String, cell: Vector2i, level: int, yaw: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return

	# ★ 反作弊闸门：距离由服务器用它自己看到的玩家位置来量。
	#   如果信任客户端上报的位置，改一行坐标就能在别人房顶上盖墙。
	var p := _player_node(sender)
	if p == null:
		return
	if not _server_place(kind, cell, level, yaw, p.global_position):
		pass  # 静默拒绝：不告诉作弊者"为什么不行"，减少试探信息


@rpc("authority", "call_local", "reliable")
func _apply_place(id: int, kind: String, cell: Vector2i, level: int, yaw: int, base_y: float) -> void:
	if _pieces.has(id):
		return
	var piece := PIECE_SCENE.instantiate()
	piece.name = "p%d" % id
	piece.set_meta("id", id)
	piece.setup(kind, yaw)
	piece.position = Vector3(float(cell.x) * GRID, base_y, float(cell.y) * GRID)
	add_child(piece)

	var size := PIECE_SCRIPT.size_of(kind)
	var top := base_y + size.y
	_pieces[id] = {
		"kind": kind, "cell": cell, "level": level, "yaw": yaw,
		"base": base_y, "top": top, "node": piece,
	}
	_occupied[_key(kind, cell, level, yaw)] = id
	var sk := _support_key(cell, level)
	_tops[sk] = maxf(float(_tops.get(sk, -INF)), top)
	print("[S7.5] 放置 %s id=%d 格=%s 层=%d（本机共 %d 块）" % [kind, id, cell, level, _pieces.size()])


# ============================================================
# 拆除
# ============================================================
func _try_remove() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var from := cam.global_position
	# 统一射线：与交互系统共用同一份实现，避免三处各写一遍再慢慢漂移
	var local := _local_player()
	var exclude: Array[RID] = []
	if local != null:
		exclude.append(local.get_rid())
	var hit := AimRay.cast(get_viewport(), exclude, MAX_DISTANCE * 3.0, Layers.AIM_MASK)
	if hit.is_empty():
		return

	var collider = hit.collider
	if collider == null or not collider.has_meta("id"):
		return
	var id := int(collider.get_meta("id"))
	if id <= 0:
		return

	if multiplayer.is_server():
		_apply_remove.rpc(id)
	else:
		rpc_id(1, "_request_remove", id)


@rpc("any_peer", "call_remote", "reliable")
func _request_remove(id: int) -> void:
	if not multiplayer.is_server() or not _pieces.has(id):
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var p := _player_node(sender)
	var info: Dictionary = _pieces[id]
	var center := Vector3(
		float(info["cell"].x) * GRID, float(info["base"]), float(info["cell"].y) * GRID)
	if p == null or p.global_position.distance_to(center) > MAX_DISTANCE + GRID:
		return
	_apply_remove.rpc(id)


@rpc("authority", "call_local", "reliable")
func _apply_remove(id: int) -> void:
	if not _pieces.has(id):
		return
	var info: Dictionary = _pieces[id]
	var cell: Vector2i = info["cell"]
	var level := int(info["level"])

	info["node"].queue_free()
	_occupied.erase(_key(info["kind"], cell, level, int(info["yaw"])))
	_pieces.erase(id)
	_refresh_tops(cell, level)
	print("[S7.5] 拆除 id=%d（本机共 %d 块）" % [id, _pieces.size()])

	# ★ 连锁拆除：抽掉下面那层，上面所有东西都会失去支撑。
	#   不做这一步，拆掉地基后上面的墙会停在半空 —— 看起来像 bug，其实只是
	#   "世界不承认重力"。所有端都会跑同一段确定性代码，所以结果天然一致，
	#   不需要为连锁再发一次网络消息。
	for other_id in _pieces.keys():
		if not _pieces.has(other_id):
			continue
		var o: Dictionary = _pieces[other_id]
		if o["cell"] == cell and int(o["level"]) > level:
			_apply_remove(other_id)


### 拆掉一块后重算这一层的顶面高度。
## 如果这一层已经没有东西了，就把支撑记录删掉 —— 否则上面的楼层会"浮空仍可放置"。
func _refresh_tops(cell: Vector2i, level: int) -> void:
	var best := -INF
	for info in _pieces.values():
		if info["cell"] == cell and int(info["level"]) == level:
			best = maxf(best, float(info["top"]))
	var sk := _support_key(cell, level)
	if best == -INF:
		_tops.erase(sk)
	else:
		_tops[sk] = best


# ============================================================
# 加入快照
# ============================================================
@rpc("any_peer", "call_remote", "reliable")
func _request_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var list := []
	for id in _pieces:
		var i: Dictionary = _pieces[id]
		list.append([id, i["kind"], i["cell"], int(i["level"]), int(i["yaw"]), float(i["base"])])
	_apply_snapshot.rpc_id(sender, list)


@rpc("authority", "call_remote", "reliable")
func _apply_snapshot(list: Array) -> void:
	# 先清空：快照代表"完整状态"，不是"增量"。混着用会出现重复块
	for id in _pieces.keys():
		var info: Dictionary = _pieces[id]
		info["node"].queue_free()
	_pieces.clear()
	_occupied.clear()
	_tops.clear()
	for entry in list:
		_apply_place(int(entry[0]), String(entry[1]), entry[2], int(entry[3]), int(entry[4]), float(entry[5]))
	print("[S7.5] 收到世界快照：%d 块建筑" % _pieces.size())


# ============================================================
# 工具
# ============================================================
### 第 level 层的"地板"高度。没有支撑则返回 NAN。
func _floor_y(cell: Vector2i, level: int) -> float:
	if level <= 0:
		return terrain.height_at(float(cell.x) * GRID, float(cell.y) * GRID)
	var sk := _support_key(cell, level - 1)
	if not _tops.has(sk):
		return NAN
	return float(_tops[sk])


### 合法性判断。客户端用它上色，服务器用它裁决 —— 同一份规则，两处用途。
func _can_place(kind: String, cell: Vector2i, level: int, yaw: int, from_pos: Vector3) -> bool:
	if _pieces.size() >= MAX_PIECES:
		return false
	if _occupied.has(_key(kind, cell, level, yaw)):
		return false

	var floor_y := _floor_y(cell, level)
	if is_nan(floor_y):
		return false

	var size := PIECE_SCRIPT.size_of(kind)
	var top := floor_y + size.y
	# 够得着的判断：不能凭空在头顶盖，也不能往脚下三米外塞
	if top > from_pos.y + REACH_UP:
		return false
	if floor_y < from_pos.y - REACH_DOWN:
		return false

	var center := Vector3(float(cell.x) * GRID, floor_y, float(cell.y) * GRID)
	# ★ 城镇禁建区：判断权在 TownBuilder（"哪里不能建"是城镇的知识，不是建造的知识）。
	#   因为 _can_place 同时服务客户端预览上色与服务器裁决，
	#   这一行加完两端自动一致，不需要额外发网络消息。
	if town != null and town.is_build_blocked(center):
		return false
	if from_pos.distance_to(center) > MAX_DISTANCE + GRID * 0.75:
		return false
	return true


### 占位键。地基占整格，墙按朝向占 —— 现在都带上了"层"。
func _key(kind: String, cell: Vector2i, level: int, yaw: int) -> String:
	if kind == KIND_FOUNDATION:
		return "f:%d:%d:%d" % [cell.x, level, cell.y]
	return "w:%d:%d:%d:%d" % [cell.x, level, cell.y, yaw % 180]


func _support_key(cell: Vector2i, level: int) -> String:
	return "s:%d:%d:%d" % [cell.x, level, cell.y]


func _player_node(id: int) -> Node3D:
	var players := get_node_or_null("../Players")
	if players == null:
		return null
	return players.get_node_or_null(str(id)) as Node3D


func _local_player() -> Node3D:
	var id := multiplayer.get_unique_id()
	if id <= 0:
		return null
	return _player_node(id)


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _build_ghost() -> void:
	_ghost = MeshInstance3D.new()
	_ghost.name = "Ghost"
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.35)
	_ghost.material_override = _ghost_mat
	_ghost.visible = false
	add_child(_ghost)
