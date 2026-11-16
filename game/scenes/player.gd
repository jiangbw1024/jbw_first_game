extends CharacterBody3D
## 第一人称玩家：视角本地即时，位移服务器权威
##
## ★ 这一版最重要的结构改动：**把"看"和"走"拆成两件事**
##
##   视角（yaw/pitch）永远在本地立刻生效 —— 如果连转视角都要等服务器回包，
##   操作会像隔着一层毛玻璃。所有第一人称射击都这么做。
##   位移必须由服务器算 —— 否则改客户端就能瞬移穿墙。
##
##   单机时两者都在本地，看不出区别。但代码里必须已经分开：
##   开联机时，"视角"要从权威同步里摘出来，"位移"原样保留。
##   如果现在图省事写成一份，那天就是重写。

const WALK_SPEED := 5.0
const SPRINT_SPEED := 8.5
const ACCELERATION := 45.0
const JUMP_VELOCITY := 6.5
const GRAVITY := 22.0
const MOUSE_SENSITIVITY := 0.0022
const PITCH_LIMIT := 1.52          # 上下看的上限（略小于 90°，避免翻转）
const STEP_HEIGHT := 0.35

const MAX_HP := 100.0
const RESPAWN_DELAY := 3.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var view: WeaponView = $Head/Camera3D/WeaponView
@onready var knife_view = $Head/Camera3D/KnifeView
@onready var flashlight: SpotLight3D = $Head/Camera3D/Flashlight
@onready var combat: Combat = $Combat
@onready var body_mesh: MeshInstance3D = $Body
@onready var nose: MeshInstance3D = $Nose
@onready var label: Label3D = $NameLabel
@onready var hand: Node3D = $HandItem

var _pitch := 0.0
## 后坐力造成的额外抬头（弧度）。它和 _pitch 分开存，才能"顶上去再自己落回来"
var _recoil := 0.0
## 震屏强度 0..1.2，每帧衰减
var _shake := 0.0

# ---- 生命值（S10） ----
var hp := MAX_HP
var dead := false
## 死亡视角的倾倒量 0..1。不用"画面冻结"，而是让头慢慢歪倒 ——
## 玩家一眼就知道"我死了"，而不是以为游戏卡住了
var _death_tilt := 0.0
## 重生点，由 world 在出生时写入
var _spawn_point := Vector3.ZERO

# ---- 背包（S11） ----
## ★ 背包是"数据"，挂在玩家节点上只是因为它属于这个玩家。
##   它不是节点、不进场景树、不同步位置 —— 换端时只传 to_array() 的结果。
var inventory := Inventory.new()

# 服务器为"每个玩家"保存的最新输入（每个实例一份，天然互不干扰）
var _input_dir := Vector2.ZERO
var _input_yaw := 0.0
var _input_sprint := false
var _jump_queued := false


func _ready() -> void:
	label.text = "玩家 %s" % name
	# 丧尸靠这个 group 找目标。用 group 而不是写死路径，
	# 节点层级一变（比如以后把玩家放进 Players 的子容器）也不会断
	add_to_group("players")
	# 只有"自己这一个"玩家让它的相机生效，否则多个相机互相抢画面
	camera.current = is_local()
	_spawn_point = global_position
	hp = MAX_HP

	if is_local():
		# 第一人称不画自己的身体：相机在头里，画出来就是满屏肉色
		body_mesh.visible = false
		nose.visible = false
		label.visible = false
		hand.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

		combat.fired.connect(_on_fired)
		combat.hit_confirmed.connect(_on_hit_confirmed)
		combat.ammo_changed.connect(_on_ammo_changed)
		combat.slot_changed.connect(_on_slot_changed)
		combat.switch_started.connect(_on_switch_started)
		combat.knife_swung.connect(_on_knife_swung)
		_on_ammo_changed(combat.weapon.ammo, combat.weapon.reserve, false)
		_on_slot_changed(combat.current_slot, combat.slot_label())
		GameState.player_health = hp
		GameState.player_health_max = MAX_HP
		GameState.health_changed.emit(hp, MAX_HP)


func peer_id() -> int:
	return int(name)


func is_local() -> bool:
	return peer_id() == multiplayer.get_unique_id()


# ------------------------------------------------------------
# 外部访问（Combat / FX 需要）
# ------------------------------------------------------------
func view_camera() -> Camera3D:
	return camera


func muzzle_position() -> Vector3:
	return view.muzzle_position() if view != null else camera.global_position


func weapon_view() -> WeaponView:
	return view


### 换手里的东西（第三视角给别人看的那个）。由 ShopService 广播后调用
func apply_hand_item(item_id: int) -> void:
	if hand != null and hand.has_method("apply"):
		hand.apply(item_id)


# ------------------------------------------------------------
# 视角（本地、即时）
# ------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not is_local():
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# 水平转的是"身体"，垂直转的是"头"。
		# 为什么要分开：移动方向由身体朝向决定，如果 pitch 也写进身体，
		# 走路会跟着抬头低头一起往前上方飘。
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		view.add_sway(event.relative)
		if knife_view != null and knife_view.has_method("add_sway"):
			knife_view.call("add_sway", event.relative)
	elif event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("use_med"):
		if multiplayer.is_server():
			use_medkit()
		else:
			rpc_id(1, "_request_use_medkit")
	elif event.is_action_pressed("flashlight"):
		flashlight.visible = not flashlight.visible
		Sfx.play_ui("reload_out", -22.0, 1.6)
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()


# ------------------------------------------------------------
# 每帧：后坐力回落、震屏、武器视图状态
# ------------------------------------------------------------
func _process(delta: float) -> void:
	if not is_local():
		return

	# 后坐力回落。注意这里用的是"度/秒"而不是乘法衰减 ——
	# 乘法衰减在 144Hz 和 60Hz 下的实际速度不同，手感会随帧率变化。
	var recover := 12.0
	if combat != null and combat.weapon != null:
		recover = float(combat.weapon.def["recoil_recover"])
	_recoil = move_toward(_recoil, 0.0, deg_to_rad(recover) * delta)

	var want := _pitch + _recoil
	# 顶到天花板时把多余的量吃掉，否则松手后会"卡"在极限位置慢慢往下滑
	if want > PITCH_LIMIT:
		_recoil -= want - PITCH_LIMIT
		want = PITCH_LIMIT
	head.rotation.x = want

	# 死亡视角：头歪向一侧、相机往下沉。
	# 为什么不用"画面变黑"：那样玩家只会以为游戏卡住了；
	# 一个缓慢倾倒的视角是所有人都有直觉的信号 —— "我倒了"。
	# 用 move_toward 而不是 tween，是因为重生要能中途打断它。
	_death_tilt = move_toward(_death_tilt, 1.0 if dead else 0.0, delta * (2.2 if dead else 5.0))
	head.rotation.z = _death_tilt * 0.55

	# 震屏：每帧换一个随机偏移，肉眼看就是"抖"，而不是"飘"
	var shake_off := Vector3.ZERO
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 7.0)
		shake_off = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.012
	camera.position = shake_off + Vector3(0.0, -_death_tilt * 0.85, 0.0)

	# 把"我现在走多快、在不在换弹"告诉武器视图，它负责摇晃和下沉
	view.move_speed = Vector2(velocity.x, velocity.z).length()
	view.on_floor = is_on_floor()
	view.reloading = combat.weapon.reloading
	view.reload_ratio = combat.weapon.reload_ratio()
	if knife_view != null:
		knife_view.set("move_speed", view.move_speed)
		knife_view.set("on_floor", view.on_floor)

	if (Input.is_action_just_pressed("inspect")
			and not dead
			and not GameState.ui_captures_input
			and knife_view != null
			and knife_view.has_method("play_inspect")
			and combat.current_slot == Combat.Slot.KNIFE
			and not combat.is_switching()):
		knife_view.call("play_inspect")


func _on_fired(recoil_v: float, recoil_h: float, strength: float) -> void:
	_recoil += deg_to_rad(recoil_v)
	# 水平后坐力直接转身体：这是"真的把枪口带偏了"，需要玩家自己拉回来
	rotate_y(deg_to_rad(recoil_h))
	_shake = minf(_shake + 0.30 * strength, 1.1)
	view.kick(strength)


func _on_hit_confirmed(headshot: bool) -> void:
	GameState.hit_confirmed.emit(headshot)
	Sfx.play_ui("hit_head" if headshot else "hit_flesh", -7.0)


func _on_ammo_changed(mag: int, reserve: int, reloading: bool) -> void:
	GameState.ammo_changed.emit(mag, reserve, reloading)


func _on_slot_changed(slot: int, label: String) -> void:
	GameState.weapon_changed.emit(slot, label)
	if view != null:
		view.visible = slot == Combat.Slot.PRIMARY
	if knife_view != null:
		knife_view.visible = slot == Combat.Slot.KNIFE
		if slot == Combat.Slot.KNIFE and knife_view.has_method("play_draw"):
			knife_view.call("play_draw")


func _on_switch_started(target_slot: int) -> void:
	# 收刀阶段先把刀压低；拉刀阶段由 slot_changed 在 0.30s 后触发。
	if (target_slot == Combat.Slot.PRIMARY
			and knife_view != null
			and knife_view.visible
			and knife_view.has_method("play_holster")):
		knife_view.call("play_holster")


func _on_knife_swung(heavy: bool) -> void:
	if knife_view != null and knife_view.has_method("play_attack"):
		knife_view.call("play_attack", heavy)


# ------------------------------------------------------------
# 位移（服务器权威，逻辑与 S3 完全一致）
# ------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		# ★ 主机是"双重身份"：既是服务器，又是玩家本人。
		#   所以必须先自己读一次输入，否则主机的角色永远收不到输入 ——
		#   服务器在等一份永远不会通过网络到达的输入包。
		if is_local():
			_apply_local_input()
		_simulate(delta)
	elif is_local():
		_send_input()


func _apply_local_input() -> void:
	if GameState.ui_captures_input:
		# 必须显式清零，而不是"停止发送"：
		# 服务器保存的是"最后一次收到的输入"，不发就会一直按上次的输入推着你走。
		_input_dir = Vector2.ZERO
		_input_sprint = false
		_jump_queued = false
		_input_yaw = rotation.y
		return
	_input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back").limit_length(1.0)
	_input_yaw = rotation.y
	_input_sprint = Input.is_action_pressed("sprint")
	if Input.is_action_just_pressed("jump"):
		_jump_queued = true


func _send_input() -> void:
	if GameState.ui_captures_input:
		rpc_id(1, "_receive_input", Vector2.ZERO, rotation.y, false, false)
		return
	var dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var jump := Input.is_action_just_pressed("jump")
	var sprint := Input.is_action_pressed("sprint")
	rpc_id(1, "_receive_input", dir, rotation.y, sprint, jump)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_input(dir: Vector2, yaw: float, sprint: bool, jump: bool) -> void:
	if not multiplayer.is_server():
		return
	# ★ 反作弊第一道闸门：只接受这个玩家节点真正的主人发来的输入
	if multiplayer.get_remote_sender_id() != peer_id():
		return
	# ★ 第二道闸门：不信任客户端数值，做上限钳制
	_input_dir = dir.limit_length(1.0)
	_input_yaw = yaw
	_input_sprint = sprint
	if jump:
		_jump_queued = true


func _simulate(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if _jump_queued:
		if is_on_floor():
			velocity.y = JUMP_VELOCITY
		_jump_queued = false

	rotation.y = _input_yaw

	var direction := (transform.basis * Vector3(_input_dir.x, 0.0, _input_dir.y)).normalized()
	var speed := SPRINT_SPEED if _input_sprint else WALK_SPEED
	# 持刀只加走路速度，冲刺不变：刀是"更快到位"，不是"跑得比枪还快"。
	if not _input_sprint and combat != null and combat.current_slot == Combat.Slot.KNIFE:
		speed *= Combat.KNIFE_MOVE_MULT
	var target := direction * speed

	velocity.x = move_toward(velocity.x, target.x, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, target.z, ACCELERATION * delta)

	move_and_slide()
	StepAssist.try_step(self, STEP_HEIGHT)


# ------------------------------------------------------------
# 生命值（服务器权威）
# ------------------------------------------------------------
### 由 world 在出生时调用：记住"死后回到哪"
func set_spawn_point(p: Vector3) -> void:
	_spawn_point = p


### 服务器权威：只有服务器能扣血。
##
## 和开火、建造、购买同一条规则：客户端永远没有"改自己血量"的能力。
## 丧尸的攻击判定跑在服务器上，所以调用点也在服务器。
func take_damage(amount: float, from_pos: Vector3) -> void:
	if not multiplayer.is_server() or dead or amount <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	_damage_rpc.rpc(hp, amount, from_pos)
	if hp <= 0.0:
		_begin_death()


@rpc("authority", "call_local", "reliable")
func _damage_rpc(hp_now: float, amount: float, from_pos: Vector3) -> void:
	GameState.player_health = hp_now
	GameState.health_changed.emit(hp_now, MAX_HP)
	if not is_local():
		return

	# 把"攻击者位置"换算成相对朝向的角度，HUD 用它决定红边从哪一侧亮起。
	# 0 = 正前方，+90 = 右侧，±180 = 背后。
	# ★ amount == 0 表示"血量被外部改写"（回血、重生），不是挨打。
	#   早期版本没区分，于是重生和用急救包都会闪一下红边 ——
	#   玩家会以为"我回血的时候又被打了一下"。
	if amount > 0.0:
		var to := from_pos - global_position
		var local := global_transform.basis.inverse() * to
		var deg := rad_to_deg(atan2(local.x, -local.z))
		GameState.hurt.emit(deg, amount)

	if not dead:
		_shake = minf(_shake + 0.45, 1.2)
		Sfx.play_ui("player_hurt", -3.0)


func _begin_death() -> void:
	dead = true
	_death_rpc.rpc(true)
	if not multiplayer.is_server():
		return
	# 服务器负责计时重生。用 await 计时器而不是 Timer 节点：
	# 这个流程只需要"等一会儿"，多一个节点反而要额外管它的生命周期
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	if is_instance_valid(self) and dead:
		_respawn()


@rpc("authority", "call_local", "reliable")
func _death_rpc(is_dead: bool) -> void:
	dead = is_dead
	GameState.death_changed.emit(is_dead)
	if not is_local():
		return
	if is_dead:
		# ★ 复用 UI 锁：死亡期间聊天、商店、开火、建造自动全部失效，
		#   不需要在五个地方各写一遍 `if dead: return`
		GameState.claim_ui("dead")
		Sfx.play_ui("player_die", 0.0)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		GameState.release_ui("dead")
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _respawn() -> void:
	hp = MAX_HP
	dead = false
	velocity = Vector3.ZERO
	global_position = _spawn_point
	_lose_on_death()
	_damage_rpc.rpc(hp, 0.0, global_position)
	_death_rpc.rpc(false)


# ------------------------------------------------------------
# 背包（S11，服务器权威）
# ------------------------------------------------------------
### 服务器唯一入口：加东西。返回**实际加进去的数量**。
##
## ★ 弹药走的是另一条通道（直接进枪的备用弹），不进背包格。
##   这不是偷懒，是设计：弹药是"一直在消耗"的东西，
##   让它占格等于惩罚玩家带弹 —— 结果就是所有人都只带一个弹匣下场。
##   背包的压力应该来自"要囤哪些材料"，而不是"要不要带子弹"。
func add_item(item_id: String, count: int) -> int:
	if not multiplayer.is_server() or count <= 0:
		return 0
	if not ItemDef.has(item_id):
		return 0

	var got := 0
	if ItemDef.kind_of(item_id) == "ammo":
		got = combat.add_reserve(count)
	else:
		got = inventory.add(item_id, count)

	if got > 0:
		_push_inventory()
	return got


### 把背包状态推给"这个玩家的客户端"。
##
### ★ 为什么只推给本人、不广播：
##   背包是私有信息。广播会让所有人（包括改客户端的人）看到你身上有什么，
##   联机时这就是"知道谁身上有急救包"的情报漏洞。别人只需要看到你的模型。
func _push_inventory() -> void:
	var data := inventory.to_array()
	if peer_id() == multiplayer.get_unique_id():
		# 自己就是服务器（单机/主机），不必过网络，直接写状态
		_apply_inv(data)
	else:
		_inv_rpc.rpc_id(peer_id(), data)


@rpc("authority", "call_remote", "reliable")
func _inv_rpc(data: Array) -> void:
	_apply_inv(data)


func _apply_inv(data: Array) -> void:
	inventory.load_state(data)
	if is_local():
		GameState.inventory_changed.emit(inventory)


### 按 H 用一个急救包。服务器权威（"能不能回血"不能由客户端说了算）
func use_medkit() -> bool:
	if not multiplayer.is_server() or dead:
		return false
	if hp >= MAX_HP:
		if is_local():
			GameState.notify.emit("血量是满的", 1.6)
		return false
	if inventory.count_of(ItemDef.MEDKIT) <= 0:
		if is_local():
			GameState.notify.emit("没有急救包", 1.6)
		return false

	inventory.take(ItemDef.MEDKIT, 1)
	var def := ItemDef.get_def(ItemDef.MEDKIT)
	hp = minf(MAX_HP, hp + float(def.get("heal", 40.0)))
	_damage_rpc.rpc(hp, 0.0, global_position)
	_push_inventory()
	if is_local():
		Sfx.play_ui("reload_in", -6.0, 0.85)
		GameState.notify.emit("使用急救包，回复 %d" % int(def.get("heal", 40.0)), 2.0)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _request_use_medkit() -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != peer_id():
		return
	use_medkit()


### 死亡的代价：材料损失一半。
##
### ★ 为什么不是清空背包：
##   清空会让一次失误抹掉半小时的成果，那是惩罚玩家而不是制造张力。
##   ★ 为什么不是完全无损：
##   无损的话"往深处走"就没有任何风险，玩家会一路莽到底。
##   一半材料 = 疼，但不至于让人想关游戏 —— 而且它惩罚的正是"贪心"：
##   材料带得越多，一次死亡丢得越多。这个曲线是刻意设计的。
func _lose_on_death() -> void:
	var lost: Array[String] = []
	for id in [ItemDef.SCRAP, ItemDef.WOOD, ItemDef.CLOTH]:
		var have := inventory.count_of(id)
		if have <= 0:
			continue
		var n := int(floor(have / 2.0))
		if n <= 0:
			continue
		inventory.take(id, n)
		lost.append("%s ×%d" % [ItemDef.name_of(id), n])
	_push_inventory()
	if is_local() and not lost.is_empty():
		GameState.notify.emit("阵亡损失：" + "、".join(lost), 3.0)
