class_name Combat
extends Node
## 玩家身上的战斗组件：开火 / 换弹 / 推击 / 近战
##
## 为什么单独一个节点而不是塞进 player.gd：
##   player.gd 已经背着"移动 + 相机 + 联机身份"三件事。再塞进武器状态机，
##   它会变成一个谁也读不完的上帝对象。这里只做一件事：把"扣扳机"变成"伤害"。
##
## 权威模型（和建造、购买同一条规则）：
##   客户端只能说"我朝这个方向开了一枪"，打没打中、扣不扣弹由服务器算。
##   单机时服务器就是本地，所以看不出差别 —— 但形状必须已经是对的。

const KnifeDefScript = preload("res://scripts/combat/knife_def.gd")
const KnifeStateScript = preload("res://scripts/combat/knife_state.gd")

signal ammo_changed(mag: int, reserve: int, reloading: bool)
signal fired(recoil_v: float, recoil_h: float, strength: float)
signal hit_confirmed(headshot: bool)
## 当前武器槽变化。slot 用 Slot 枚举，label 是给 HUD 直接显示的名字。
signal slot_changed(slot: int, label: String)
## 开始切向某个槽位。视图层用它播放收刀/拉刀。
signal switch_started(target_slot: int)
## 刀挥出去了。heavy=true 是右键重击，false 是左键轻击。
signal knife_swung(heavy: bool)

@export var start_weapon := "ak47"

enum Slot { PRIMARY, KNIFE }
enum SwitchPhase { IDLE, HOLSTER, DRAW }

const SLOT_HOLSTER_TIME := 0.30
const SLOT_DRAW_TIME := 0.45
const KNIFE_MOVE_MULT := 1.12

const SHOVE_RANGE := 2.0
const SHOVE_ANGLE := 55.0        # 半角（度）
const SHOVE_COOLDOWN := 0.80
const SHOVE_FORCE := 7.5

const MELEE_RANGE := 2.4
const MELEE_ANGLE := 45.0
const MELEE_COOLDOWN := 0.62
const MELEE_DAMAGE := 55.0

## 备用弹上限 = 8 个弹匣。AK 弹匣 30 发，所以约 240 + 弹匣内 30。
## 这个数不是"平衡数值"，是"玩家能打完一场恶战、但撑不了三场"的量
const RESERVE_CAP := 240

var weapon: WeaponState
## KnifeState。用 preload 实例化，避免新脚本还没进全局类缓存时解析失败。
var knife

## 武器槽。current 是"手里真正生效的"，切换过程中先收旧武器、再拉新武器。
var current_slot := Slot.PRIMARY
## 上一次拿的槽位，Q 直接切回这里。初始设成刀，所以开局按 Q 就能拔刀。
var last_slot := Slot.KNIFE
var switch_phase := SwitchPhase.IDLE

var _trigger_down := false
var _shove_cd := 0.0
var _melee_cd := 0.0
var _was_reloading := false
var _switch_left := 0.0
var _switch_target := Slot.PRIMARY
var _knife_pending_heavy := false
var _knife_pending_origin := Vector3.ZERO
var _knife_pending_dir := Vector3.FORWARD
var _knife_buffer := 0.0
var _knife_heavy_buffer := 0.0

var _player: CharacterBody3D
var _fx: FxRoot


func _ready() -> void:
	_player = get_parent() as CharacterBody3D
	weapon = WeaponState.new(start_weapon)
	knife = KnifeStateScript.new(KnifeDefScript.default_id())
	_fx = get_tree().get_first_node_in_group("fx") as FxRoot
	_emit_ammo()
	_emit_slot()


func _process(delta: float) -> void:
	weapon.tick(delta)
	knife.tick(delta)
	_tick_switch(delta)
	_shove_cd = maxf(0.0, _shove_cd - delta)
	_melee_cd = maxf(0.0, _melee_cd - delta)
	_knife_buffer = maxf(0.0, _knife_buffer - delta)
	_knife_heavy_buffer = maxf(0.0, _knife_heavy_buffer - delta)

	# 重击前摇到点：只有服务器结算伤害。客户端本地只消费状态，动画由信号驱动。
	if current_slot == Slot.KNIFE and knife.consume_pending():
		if multiplayer.is_server() and _knife_pending_heavy:
			_apply_knife_damage(_knife_pending_origin, _knife_pending_dir, true)
		_knife_pending_heavy = false

	# 换弹结束时补一声"上膛"
	if _was_reloading and not weapon.reloading:
		Sfx.play_ui("reload_in", -4.0)
		_emit_ammo()
	_was_reloading = weapon.reloading

	if not _player.is_local() or GameState.ui_captures_input:
		_trigger_down = false
		return

	if Input.is_action_just_pressed("slot_primary"):
		switch_to(Slot.PRIMARY)
	elif Input.is_action_just_pressed("slot_knife"):
		switch_to(Slot.KNIFE)
	elif Input.is_action_just_pressed("last_weapon"):
		switch_to(last_slot)

	var down := Input.is_action_pressed("fire")
	var fire_pressed := Input.is_action_just_pressed("fire")
	var shove_pressed := Input.is_action_just_pressed("shove")

	# 刀的攻击缓冲：切枪最后阶段点一下，拉刀完成后还能补上一次输入。
	if current_slot == Slot.KNIFE or (is_switching() and _switch_target == Slot.KNIFE):
		if fire_pressed:
			_knife_buffer = WeaponState.BUFFER_TIME
		if shove_pressed:
			_knife_heavy_buffer = WeaponState.BUFFER_TIME

	# 半自动：按下那一刻先记一笔"我想开火"。
	# 有了这个缓冲，玩家点得比射速快时不会觉得"我明明按了却没反应"。
	if down and not _trigger_down:
		if current_slot == Slot.PRIMARY and weapon.ammo <= 0 and not weapon.reloading:
			# 空仓也要有反馈。没有这一声，玩家会以为"游戏没响应我的点击"
			Sfx.play_ui("dry_fire", -6.0)
		if current_slot == Slot.PRIMARY:
			weapon.remember_press()
	_trigger_down = down

	if down and current_slot == Slot.PRIMARY:
		if bool(weapon.def["auto"]):
			_try_fire()
		elif weapon.wants_buffered_shot():
			_try_fire()

	if current_slot == Slot.KNIFE:
		# 右键优先：重击一旦进入前摇，左键要等它结算，不能同帧抢掉。
		if _knife_heavy_buffer > 0.0:
			if _try_knife_heavy():
				_knife_heavy_buffer = 0.0
		elif down or _knife_buffer > 0.0:
			if _try_knife_light():
				_knife_buffer = 0.0

	if Input.is_action_just_pressed("reload") and current_slot == Slot.PRIMARY:
		reload()
	if shove_pressed and current_slot == Slot.PRIMARY:
		shove()
	if Input.is_action_just_pressed("melee"):
		melee()

	# 给准心用的实时扩散
	GameState.crosshair_spread = spread_deg() if current_slot == Slot.PRIMARY else 0.0


# ------------------------------------------------------------
# 武器槽：收旧武器 → 拉新武器
# ------------------------------------------------------------
### 请求切到某个槽位。返回是否真的开始了切换/取消。
##
### 切换过程中再按同一个槽位 = 取消，立刻回到当前武器；
### 按另一个槽位 = 改目标，从头收刀再拉新武器。
func switch_to(slot: int) -> bool:
	if slot != Slot.PRIMARY and slot != Slot.KNIFE:
		return false

	# 槽位是玩法状态，服务器必须知道；否则联机时服务器的 current_slot
	# 还停在 AK，刀的攻击会被权威端直接拒绝。
	if not multiplayer.is_server():
		rpc_id(1, "_request_slot", slot)

	knife.cancel_pending()
	_knife_pending_heavy = false

	if switch_phase != SwitchPhase.IDLE:
		if slot == current_slot:
			_cancel_switch()
			return true
		if slot == _switch_target:
			return false
		_switch_target = slot
		switch_phase = SwitchPhase.HOLSTER
		_switch_left = SLOT_HOLSTER_TIME
		switch_started.emit(slot)
		_emit_slot()
		return true

	if slot == current_slot:
		return false

	_switch_target = slot
	switch_phase = SwitchPhase.HOLSTER
	_switch_left = SLOT_HOLSTER_TIME
	_cancel_reload()
	switch_started.emit(slot)
	_emit_slot()
	return true


@rpc("any_peer", "call_remote", "reliable")
func _request_slot(slot: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != int(String(_player.name)):
		return
	switch_to(slot)


func is_switching() -> bool:
	return switch_phase != SwitchPhase.IDLE


### 切枪期间不能开火/重击/换弹。移动不受影响。
func can_attack() -> bool:
	return switch_phase == SwitchPhase.IDLE


### 0..1。给视图模型做"刀从下面抬起来"的进度。
func switch_progress() -> float:
	if switch_phase == SwitchPhase.IDLE:
		return 1.0
	if switch_phase == SwitchPhase.HOLSTER:
		return 0.0
	return 1.0 - _switch_left / maxf(0.01, SLOT_DRAW_TIME)


func slot_label(slot := current_slot) -> String:
	return "蝴蝶刀" if slot == Slot.KNIFE else "AK47"


func _tick_switch(delta: float) -> void:
	if switch_phase == SwitchPhase.IDLE:
		return

	_switch_left -= delta
	if _switch_left > 0.0:
		return

	if switch_phase == SwitchPhase.HOLSTER:
		current_slot = _switch_target
		switch_phase = SwitchPhase.DRAW
		_switch_left = SLOT_DRAW_TIME
		_emit_slot()
	else:
		switch_phase = SwitchPhase.IDLE
		_switch_left = 0.0
		_emit_slot()


func _cancel_switch() -> void:
	switch_phase = SwitchPhase.IDLE
	_switch_left = 0.0
	_switch_target = current_slot
	_emit_slot()


func _cancel_reload() -> void:
	if not weapon.reloading:
		return
	weapon.cancel_reload()
	_was_reloading = false
	_emit_ammo()


func _emit_slot() -> void:
	# 只有两个槽，所以"上一把"永远是另一个。把它绑在当前槽上，
	# 就不怕取消切换后 last_slot 停在一个已经过期的值上。
	last_slot = Slot.KNIFE if current_slot == Slot.PRIMARY else Slot.PRIMARY
	slot_changed.emit(current_slot, slot_label())


# ------------------------------------------------------------
# 开火
# ------------------------------------------------------------
### 返回是否真的打出了一发（测试与缓动都依赖这个返回值）
func _try_fire() -> bool:
	if not can_attack() or current_slot != Slot.PRIMARY:
		return false
	if not weapon.can_fire():
		return false
	var cam := _view_camera()
	if cam == null:
		return false

	var origin := cam.global_position
	var dir := -cam.global_transform.basis.z

	if multiplayer.is_server():
		_server_fire(origin, dir)
	else:
		# 联机阶段：方向由客户端给（服务器不知道你的视角），
		# 但"扣了几发、打没打中"由服务器决定。
		rpc_id(1, "_request_fire", origin, dir)
	return true


func _view_camera() -> Camera3D:
	if _player.has_method("view_camera"):
		return _player.view_camera()
	return get_viewport().get_camera_3d()


### 服务器权威开火
func _server_fire(origin: Vector3, dir: Vector3) -> void:
	if not can_attack() or current_slot != Slot.PRIMARY:
		return
	if not weapon.can_fire():
		return

	var speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	var on_floor := _player.is_on_floor()
	var spread := deg_to_rad(weapon.spread_deg(speed, on_floor))

	weapon.consume()
	_emit_ammo()

	var pellets := int(weapon.def["pellets"])
	var dmg := float(weapon.def["damage"])
	var head_mult := float(weapon.def["head_mult"])
	var reach := float(weapon.def["range"])

	var space := _player.get_world_3d().direct_space_state
	var end_point := origin + dir * reach
	var any_flesh := false
	var any_head := false

	for i in pellets:
		var shot_dir := _spread_dir(dir, spread) if pellets > 1 or spread > 0.0001 else dir
		var q := PhysicsRayQueryParameters3D.create(origin, origin + shot_dir * reach)
		q.collision_mask = Layers.HURT_MASK
		q.exclude = [_player.get_rid()]
		var hit := space.intersect_ray(q)

		if hit.is_empty():
			if i == 0:
				end_point = origin + shot_dir * reach
			continue

		var pos: Vector3 = hit["position"]
		var nrm: Vector3 = hit["normal"]
		var col: Object = hit["collider"]
		if i == 0:
			end_point = pos

		var flesh := false
		var head := false
		if col != null and col.has_method("take_hit"):
			var res: Dictionary = col.take_hit(dmg, pos, shot_dir, int(hit["shape"]), head_mult)
			flesh = true
			head = bool(res.get("head", false))
			any_head = any_head or head
			any_flesh = true

		# 每个弹丸都有自己的命中特效（霰弹枪打上去是"一片"而不是"一个点"）
		_fx_remote.rpc(
			String(_player.name), origin, pos, nrm, flesh, head, weapon.id)

	if not any_flesh:
		# 一发都没打到活物时也要有一条弹道
		_fx_remote.rpc(String(_player.name), origin, end_point, Vector3.UP, false, false, weapon.id)

	# 后坐力只在开火者本机生效（视角是本地的东西）
	var rv := float(weapon.def["recoil_v"])
	var rh := float(weapon.def["recoil_h"]) * randf_range(-1.0, 1.0)
	fired.emit(rv, rh, float(weapon.def["muzzle_flash"]))

	if any_flesh:
		hit_confirmed.emit(any_head)


### 在一个圆锥内随机偏转方向
## 注意：是"方向扰动"，不是"随机落点"。
## 后者的错误做法是先算一个随机点再连过去 —— 那样远处和近处的散布形状不一样。
func _spread_dir(dir: Vector3, spread_rad: float) -> Vector3:
	if spread_rad <= 0.0:
		return dir
	var right := dir.cross(Vector3.UP)
	if right.length() < 0.001:
		right = dir.cross(Vector3.RIGHT)
	right = right.normalized()
	var up := right.cross(dir).normalized()

	var a := randf() * TAU
	# sqrt 让点在圆盘内均匀分布；不开方会全挤在中心
	var r := sqrt(randf()) * spread_rad
	return (dir + right * tan(r) * cos(a) + up * tan(r) * sin(a)).normalized()


@rpc("any_peer", "call_remote", "reliable")
func _request_fire(origin: Vector3, dir: Vector3) -> void:
	if not multiplayer.is_server():
		return
	# 闸门：只有这把枪的主人能开这把枪
	if multiplayer.get_remote_sender_id() != int(String(_player.name)):
		return
	# 闸门：方向必须是单位向量（否则客户端发一个长度 100 的向量穿墙）
	if dir.length() < 0.9 or dir.length() > 1.1:
		return
	_server_fire(origin, dir.normalized())


# ------------------------------------------------------------
# 命中特效广播
# ------------------------------------------------------------
### 为什么用 unreliable：曳光丢一条没人会发现，而 reliable 会让高射速武器
## 在网络抖动时把特效排队重传，最后"枪声和画面不同步"，比丢特效难受得多。
@rpc("authority", "call_local", "unreliable")
func _fx_remote(shooter_name: String, from: Vector3, to: Vector3,
		normal: Vector3, flesh: bool, head: bool, weapon_id: String) -> void:
	var fx := _fx
	if fx == null or not is_instance_valid(fx):
		fx = get_tree().get_first_node_in_group("fx") as FxRoot
	if fx == null:
		return

	# 弹道起点用枪口而不是相机：从眼睛出发会看起来像"眼睛里射出激光"
	var start := from
	var scene := get_tree().current_scene
	var shooter: Node = scene.get_node_or_null("Players/%s" % shooter_name) if scene != null else null
	if shooter != null and shooter.has_method("muzzle_position"):
		start = shooter.muzzle_position()

	fx.spawn_tracer(start, to)
	fx.spawn_impact(to, normal, flesh, head)
	fx.flash(start, 1.6 if flesh else 2.4)

	var d := WeaponDef.get_def(weapon_id)
	Sfx.play(String(d["sound"]), start, 0.0, 1.0, 0.05)

	# 弹壳只在自己这边抛（别人的弹壳抛在别人屏幕里）
	if shooter_name == str(multiplayer.get_unique_id()):
		var right := (to - start).cross(Vector3.UP)
		if right.length() < 0.001:
			right = Vector3.RIGHT
		fx.spawn_shell(start, right.normalized(), Vector3.UP)
		Sfx.play_ui("shell_drop", -18.0, 1.0)


# ------------------------------------------------------------
# 刀战
# ------------------------------------------------------------
### 左键轻击。按住左键会按冷却自动连挥。
func _try_knife_light() -> bool:
	if not can_attack() or current_slot != Slot.KNIFE:
		return false
	if not knife.can_light():
		return false
	var cam := _view_camera()
	if cam == null:
		return false

	var origin := _player.global_position + Vector3.UP
	var dir := -cam.global_transform.basis.z

	if multiplayer.is_server():
		return _server_knife_start(false, origin, dir)

	# 客户端本地先起冷却和动画；伤害仍由服务器按 RPC 结算。
	if not knife.begin_light():
		return false
	knife_swung.emit(false)
	rpc_id(1, "_request_knife", false, origin, dir)
	return true


### 右键重击。按下只进入前摇，0.35 秒后才由服务器结算。
func _try_knife_heavy() -> bool:
	if not can_attack() or current_slot != Slot.KNIFE:
		return false
	if not knife.can_heavy():
		return false
	var cam := _view_camera()
	if cam == null:
		return false

	var origin := _player.global_position + Vector3.UP
	var dir := -cam.global_transform.basis.z

	if multiplayer.is_server():
		return _server_knife_start(true, origin, dir)

	if not knife.begin_heavy():
		return false
	knife_swung.emit(true)
	rpc_id(1, "_request_knife", true, origin, dir)
	return true


### 服务器权威的刀攻击起点。重击只登记前摇，轻击立刻结算。
func _server_knife_start(heavy: bool, origin: Vector3, dir: Vector3) -> bool:
	if not can_attack() or current_slot != Slot.KNIFE:
		return false

	if heavy:
		if not knife.begin_heavy():
			return false
		_knife_pending_heavy = true
		_knife_pending_origin = origin
		_knife_pending_dir = dir.normalized()
		knife_swung.emit(true)
		return true

	if not knife.begin_light():
		return false
	knife_swung.emit(false)
	_apply_knife_damage(origin, dir, false)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _request_knife(heavy: bool, origin: Vector3, dir: Vector3) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != int(String(_player.name)):
		return
	# 客户端只能给方向，不能给"打中了谁"；方向必须是单位向量。
	if dir.length() < 0.9 or dir.length() > 1.1:
		return
	_server_knife_start(heavy, origin, dir.normalized())


### 真正结算一次刀伤。锥形范围里所有敌人都吃伤害，背刺按目标朝向单独判定。
func _apply_knife_damage(_origin: Vector3, dir: Vector3, heavy: bool) -> void:
	var forward := Vector3(dir.x, 0.0, dir.z)
	if forward.length() < 0.01:
		forward = -_player.global_transform.basis.z
	forward = forward.normalized()

	var hit_origin := _player.global_position + Vector3.UP
	var reach := float(knife.def["range"])
	var half_angle := float(knife.def["angle"])
	var base_damage := float(knife.def["heavy_damage"] if heavy else knife.def["light_damage"])
	var back_damage := float(knife.def["backstab_damage"])
	var any := false

	# 挥空也有风声；命中再叠肉体声，玩家能靠听觉分辨"擦边"和"砍中"。
	Sfx.play("shove", _player.global_position + Vector3.UP, -3.0, 1.30 if heavy else 1.55, 0.10)

	for body in _bodies_in_cone(hit_origin, forward, reach, half_angle):
		if body == null or not body.has_method("take_hit"):
			continue
		var backstab := _is_backstab(body, hit_origin)
		var dmg := back_damage if backstab else base_damage
		body.take_hit(dmg, body.global_position + Vector3.UP, forward, 0, 1.0)
		any = true

		var hit_pos: Vector3 = body.global_position + Vector3.UP * 1.1
		if _fx != null and is_instance_valid(_fx):
			_fx.spawn_impact(hit_pos, forward, true, backstab)
		Sfx.play("hit_flesh", hit_pos, -2.0, 1.15 if backstab else 1.0, 0.08)

	if any:
		hit_confirmed.emit(false)


### 背刺：目标面朝的方向，和"目标→玩家"的方向相反。
## 也就是玩家站在目标背后，而不是玩家自己背对目标。
func _is_backstab(body: Node3D, from: Vector3) -> bool:
	var target_forward := -body.global_transform.basis.z
	target_forward.y = 0.0
	var to_attacker := from - body.global_position
	to_attacker.y = 0.0
	if target_forward.length() < 0.01 or to_attacker.length() < 0.01:
		return false
	return target_forward.normalized().dot(to_attacker.normalized()) < float(knife.def["backstab_dot"])


# ------------------------------------------------------------
# 换弹 / 推击 / 近战
# ------------------------------------------------------------
func reload() -> void:
	if not can_attack() or current_slot != Slot.PRIMARY:
		return
	if weapon.begin_reload():
		_was_reloading = true
		Sfx.play_ui("reload_out", -6.0)
		_emit_ammo()


func shove() -> void:
	if not can_attack() or current_slot != Slot.PRIMARY:
		return
	if _shove_cd > 0.0:
		return
	_shove_cd = SHOVE_COOLDOWN
	Sfx.play("shove", _player.global_position + Vector3.UP, -2.0, 1.0, 0.12)
	if _player.has_method("weapon_view"):
		var v = _player.weapon_view()
		if v != null:
			v.kick(0.45)

	var forward := -_player.global_transform.basis.z
	var origin := _player.global_position + Vector3.UP * 1.0
	for body in _bodies_in_cone(origin, forward, SHOVE_RANGE, SHOVE_ANGLE):
		if body.has_method("knockback"):
			body.knockback(forward, SHOVE_FORCE)


func melee() -> void:
	if not can_attack():
		return
	if _melee_cd > 0.0:
		return
	_melee_cd = MELEE_COOLDOWN
	Sfx.play("shove", _player.global_position + Vector3.UP, -1.0, 0.8, 0.10)

	var forward := -_player.global_transform.basis.z
	var origin := _player.global_position + Vector3.UP * 1.0
	for body in _bodies_in_cone(origin, forward, MELEE_RANGE, MELEE_ANGLE):
		if body.has_method("take_hit"):
			body.take_hit(MELEE_DAMAGE, body.global_position, forward, 0, 1.0)


func _bodies_in_cone(origin: Vector3, forward: Vector3, reach: float, half_angle: float) -> Array:
	var out: Array = []
	var seen := {}
	var space := _player.get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = reach
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, origin)
	q.collision_mask = Layers.ENEMY
	# 不做可视检测：推击是"手感"动作，要能推到藏在门后的
	for r in space.intersect_shape(q, 16):
		var c: Object = r["collider"]
		if c == null or not (c is Node3D):
			continue
		# 一个 body 可能有两个碰撞形状（身体 + 头）。intersect_shape 会把
		# 同一个 body 返回两次；不去重的话，一刀会结算两遍伤害。
		var id := c.get_instance_id()
		if seen.has(id):
			continue
		var to := (c as Node3D).global_position - origin
		to.y = 0.0
		if to.length() < 0.01:
			out.append(c)
			seen[id] = true
			continue
		if rad_to_deg(forward.angle_to(to.normalized())) <= half_angle:
			out.append(c)
			seen[id] = true
	return out


# ------------------------------------------------------------
# 给界面用
# ------------------------------------------------------------
func spread_deg() -> float:
	if weapon == null:
		return 0.0
	var speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	return weapon.spread_deg(speed, _player.is_on_floor())


func _emit_ammo() -> void:
	ammo_changed.emit(weapon.ammo, weapon.reserve, weapon.reloading)


# ------------------------------------------------------------
# 补给（S11 拾荒）
# ------------------------------------------------------------
### 往备用弹里加 n 发，返回实际加进去多少（装不下就少加）。
##
## ★ 为什么加个上限：没有上限的话，玩家捡一小时后备用弹是 4000 发，
##   "省着打"的紧张感就彻底消失了 —— 而这是本作压力的主要来源之一。
##   上限的意义不是限制，是让"弹药是一种需要管理的资源"这句话成立。
##
## ★ 为什么返回数量而不是 bool：掉落物要按实际拿到的量减少，
##   多出来的部分应该留在地上（和背包的部分拾取同一个道理）。
func add_reserve(n: int) -> int:
	if n <= 0:
		return 0
	var room := RESERVE_CAP - weapon.reserve
	if room <= 0:
		return 0
	var got := mini(room, n)
	weapon.reserve += got
	_emit_ammo()
	return got


func reserve_room() -> int:
	return maxi(0, RESERVE_CAP - weapon.reserve)
