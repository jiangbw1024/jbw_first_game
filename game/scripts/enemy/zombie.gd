class_name Zombie
extends CharacterBody3D
## S10 · 丧尸：会追、会咬、会倒
##
## ★ 契约和 S9 的靶子完全一致（take_hit / knockback），
##   所以枪、推击、近战的代码一行都不用改 —— 这就是当初把"可被击中"
##   抽成一个约定而不是写死在靶子里的价值。
##
## ★ AI 只在服务器上跑。客户端只负责把同步过来的位置画出来。
##   单机时服务器就是本地，看不出区别；开联机那天不用重写。
##
## 为什么不用导航网格（NavigationAgent3D）：
##   Terrain3D 生成的地形没有现成的 navmesh，要手动烘焙一大片，
##   而丧尸本来就该"直线冲过来"——绕不绕障碍不是它的性格。
##   这里用直线追击 + move_and_slide 自动贴墙滑行，够用且便宜。
##   真需要绕路时（比如穿门），再给关键点加路标。

signal died

const MAX_HP := 100.0
const SPEED := 2.4              # 玩家走路 5.0、冲刺 8.5 —— 丧尸必须追不上冲刺
const SPEED_CLOSE := 3.9        # 8 米内加速，制造"它贴上来了"的压迫感
const ACCEL := 14.0
const GRAVITY := 22.0
const ATTACK_RANGE := 1.95
const ATTACK_DAMAGE := 12.0
const ATTACK_INTERVAL := 1.15
## 抬手到真正咬中的延迟。没有这段前摇，玩家会觉得"莫名其妙掉血"
const ATTACK_WINDUP := 0.28
const DETECT_RANGE := 45.0
const STAGGER_TIME := 0.22
const SEPARATION := 1.15        # 丧尸之间互相排斥，避免叠成一个点

enum State { IDLE, CHASE, ATTACK, STAGGER, DEAD }

var hp := MAX_HP
var state := State.IDLE

var _target: Node3D
var _attack_cd := 0.0
var _stagger := 0.0
var _flash := 0.0
var _anim_t := 0.0
var _visual: Node3D
var _arms: Node3D
## [材质, 原色]。受击闪红时要整体一起闪
var _mats: Array = []


func _ready() -> void:
	collision_layer = Layers.ENEMY
	# 只和世界碰撞：不撞玩家、不撞其他丧尸。
	# 让丧尸撞玩家会导致两个 CharacterBody3D 互相推挤，把玩家顶穿墙
	collision_mask = Layers.WORLD
	add_to_group("zombies")
	hp = MAX_HP
	_build_body()


# ------------------------------------------------------------
# AI（只在服务器）
# ------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if not is_instance_valid(_visual):
		return
	_animate(delta)

	if not multiplayer.is_server() or state == State.DEAD:
		return

	_attack_cd = maxf(0.0, _attack_cd - delta)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	# 硬直：被打中后短暂失控。这段时间不能追、不能咬，
	# 玩家才有"压制住了"的反馈，否则丧尸就是一台没有反应的推进器
	if _stagger > 0.0:
		_stagger -= delta
		state = State.STAGGER
		velocity.x = move_toward(velocity.x, 0.0, 18.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 18.0 * delta)
		move_and_slide()
		return

	_target = _nearest_player()
	if _target == null:
		state = State.IDLE
		velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
		move_and_slide()
		return

	var to := _target.global_position - global_position
	to.y = 0.0
	var dist := to.length()
	if dist > DETECT_RANGE:
		state = State.IDLE
		move_and_slide()
		return

	_face(to, delta)

	if dist <= ATTACK_RANGE:
		state = State.ATTACK
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		if _attack_cd <= 0.0:
			_attack()
	else:
		state = State.CHASE
		_chase(to, dist, delta)

	move_and_slide()


func _nearest_player() -> Node3D:
	var best: Node3D = null
	var best_d := DETECT_RANGE
	for n in get_tree().get_nodes_in_group("players"):
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		# 死了的人不该继续被追：丧尸应该转头找下一个活人
		if n.get("dead") == true:
			continue
		var d := global_position.distance_to((n as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = n as Node3D
	return best


func _chase(to: Vector3, dist: float, delta: float) -> void:
	var dir := to / maxf(dist, 0.001)
	var speed := SPEED_CLOSE if dist < 8.0 else SPEED
	var want := dir * speed
	velocity.x = move_toward(velocity.x, want.x, ACCEL * delta)
	velocity.z = move_toward(velocity.z, want.z, ACCEL * delta)

	# 相互排斥：不加这一条，五六只丧尸会精确叠在同一个坐标上，
	# 看起来像"一只丧尸"，玩家的子弹也只能打到最前面那只
	for other in get_tree().get_nodes_in_group("zombies"):
		if other == self or not (other is Node3D) or not is_instance_valid(other):
			continue
		var off := global_position - (other as Node3D).global_position
		off.y = 0.0
		var d := off.length()
		if d > 0.01 and d < SEPARATION:
			velocity += off / d * (SEPARATION - d) * 3.0


func _face(dir: Vector3, delta: float) -> void:
	# Node3D 的正面是 -Z，所以 yaw = atan2(-x, -z)
	var want_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, want_yaw, clampf(delta * 7.0, 0.0, 1.0))


func _attack() -> void:
	_attack_cd = ATTACK_INTERVAL
	Sfx.play("zombie_growl", global_position + Vector3.UP, -5.0, randf_range(1.05, 1.2))
	# 前摇：抬手 → 等 0.28 秒 → 真的判定。
	# 这 0.28 秒是玩家唯一的反应窗口，没有它近战就变成"贴上来就掉血"
	await get_tree().create_timer(ATTACK_WINDUP).timeout
	if not is_instance_valid(self) or state == State.DEAD:
		return
	if _target == null or not is_instance_valid(_target):
		return
	var d := _target.global_position - global_position
	d.y = 0.0
	# 容差 +0.5：抬手期间玩家可能后退半步，不能因此就完全打空
	if d.length() > ATTACK_RANGE + 0.5:
		return
	if _target.has_method("take_damage"):
		_target.take_damage(ATTACK_DAMAGE, global_position)


# ------------------------------------------------------------
# 受击契约（和 TargetDummy 一致）
# ------------------------------------------------------------
func take_hit(dmg: float, _pos: Vector3, dir: Vector3, shape_idx: int,
		head_mult := 1.0) -> Dictionary:
	if state == State.DEAD:
		return {"hit": true, "head": false, "killed": false}

	var is_head := shape_idx == 1
	var amount := dmg * (head_mult if is_head else 1.0)
	hp -= amount
	_flash = 1.0
	_stagger = STAGGER_TIME * (1.6 if is_head else 1.0)
	Sfx.play("zombie_hit", global_position + Vector3.UP * 1.2, -3.0, randf_range(0.9, 1.1))

	# 击退：只推水平分量。直接加整个 dir 会把丧尸顶到天上
	var push := Vector3(dir.x, 0.0, dir.z)
	if push.length() > 0.01:
		push = push.normalized() * (2.4 if is_head else 1.1)
		velocity += push

	var killed := hp <= 0.0
	if killed:
		_die()
	return {"hit": true, "head": is_head, "killed": killed}


func knockback(dir: Vector3, force: float) -> void:
	_stagger = STAGGER_TIME * 2.0
	var push := Vector3(dir.x, 0.0, dir.z)
	if push.length() > 0.01:
		velocity += push.normalized() * force * 0.6


func _die() -> void:
	state = State.DEAD
	died.emit()
	# 视觉表现要让所有端都看到，所以走 RPC；hp 只有服务器关心
	_die_rpc.rpc()


@rpc("authority", "call_local", "reliable")
func _die_rpc() -> void:
	state = State.DEAD
	collision_layer = 0          # 尸体不该再挡子弹
	Sfx.play("zombie_die", global_position + Vector3.UP, 0.0, randf_range(0.95, 1.1))

	var t := create_tween()
	# 先向前扑倒，再沉进地里消失。不直接 queue_free 是因为
	# "啪一下消失"会让人以为掉帧，倒地这两秒反而是击杀的奖励感
	t.tween_property(_visual, "rotation:x", deg_to_rad(-88.0), 0.45).set_trans(Tween.TRANS_QUAD)
	t.tween_interval(2.2)
	t.tween_property(self, "position:y", position.y - 1.4, 1.0)
	t.tween_callback(queue_free)


# ------------------------------------------------------------
# 程序化身体与动画
# ------------------------------------------------------------
func _build_body() -> void:
	var skin := _mat(Color(0.35, 0.37, 0.30))     # 发青的尸体肤色
	var cloth := _mat(Color(0.17, 0.165, 0.145))  # 破烂的脏衣服：比纯黑亮一档，才看得见剪影
	var blood := _mat(Color(0.30, 0.05, 0.04))

	_visual = Node3D.new()
	_visual.rotation.x = -0.12                    # 整体前倾：丧尸的标志性姿态
	add_child(_visual)

	# 躯干：比人类瘦，肩窄，看起来更"干瘪"
	_box(Vector3(0.56, 0.76, 0.36), Vector3(0, 1.06, 0), cloth)
	_box(Vector3(0.60, 0.28, 0.40), Vector3(0, 0.70, 0), cloth)          # 下摆
	_cyl(0.085, 0.14, Vector3(0, 1.52, 0), skin)                          # 脖子

	# 头：略向前伸、略歪 —— 正的头看起来像假人
	var head := _box(Vector3(0.21, 0.24, 0.23), Vector3(0, 1.67, -0.05), skin)
	head.rotation.z = 0.12
	_box(Vector3(0.17, 0.09, 0.05), Vector3(0, 1.60, -0.15), blood)       # 下颌的血迹

	# 手臂：前伸。单独一个节点，方便整体摆动和攻击前挥
	_arms = Node3D.new()
	_arms.position = Vector3(0, 1.36, -0.02)
	_visual.add_child(_arms)
	_arm(Vector3(-0.28, 0.02, -0.10), Vector3(-0.24, -0.13, -0.58), cloth)
	_arm(Vector3(0.28, 0.02, -0.10), Vector3(0.24, -0.16, -0.54), cloth)

	# 腿
	_cyl(0.085, 0.62, Vector3(-0.13, 0.36, 0), cloth)
	_cyl(0.085, 0.62, Vector3(0.13, 0.36, 0), cloth)
	_box(Vector3(0.15, 0.08, 0.26), Vector3(-0.13, 0.05, -0.04), cloth)
	_box(Vector3(0.15, 0.08, 0.26), Vector3(0.13, 0.05, -0.04), cloth)


func _arm(shoulder: Vector3, hand: Vector3, mat: Material) -> void:
	_limb(_arms, shoulder, hand, 0.062, 0.050, mat)


func _animate(delta: float) -> void:
	if state == State.DEAD:
		return

	# 受击闪红
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 5.0)
		var k := 1.0 - _flash
		for e in _mats:
			e.mat.albedo_color = Color(1.0, 0.30, 0.25).lerp(e.base, k)

	var speed := Vector2(velocity.x, velocity.z).length()
	if speed > 0.25:
		# ★ 丧尸的"走路感"不靠腿，靠**左右摇晃**。
		#   没有骨骼做不了交替步态，但重心不稳的摇摆一眼就能读成"蹒跚"
		_anim_t += delta * (4.2 + speed * 0.8)
		_visual.rotation.z = sin(_anim_t) * 0.085
		_visual.position.y = absf(sin(_anim_t)) * 0.045
		_arms.rotation.x = sin(_anim_t) * 0.10
	elif state == State.ATTACK:
		# 攻击时手臂往上抬，配合前摇
		_arms.rotation.x = lerp(_arms.rotation.x, -0.55, delta * 9.0)
	else:
		_visual.rotation.z = lerp(_visual.rotation.z, sin(_anim_t * 0.35) * 0.02, delta * 3.0)
		_arms.rotation.x = lerp(_arms.rotation.x, sin(_anim_t * 0.9) * 0.05, delta * 3.0)


# ------------------------------------------------------------
# 几何辅助（和靶子、枪用的是同一套思路）
# ------------------------------------------------------------
func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.86
	# 布料/皮肤几乎没有镜面反射。留默认 0.5 会被环境光反成灰白，
	# 深色衣服就不再是深色（S9.7 踩过）
	m.metallic_specular = 0.06
	_mats.append({"mat": m, "base": color})
	return m


func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	_visual.add_child(mi)
	return mi


func _cyl(radius: float, height: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = 8
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	_visual.add_child(mi)
	return mi


### a、b 之间放一根锥形圆柱（和 WeaponView._limb 同一套公式）
func _limb(parent: Node3D, a: Vector3, b: Vector3, r_a: float, r_b: float,
		mat: Material) -> void:
	var dir := b - a
	var length := dir.length()
	if length < 0.001:
		return
	var y_axis := dir / length
	var ref := Vector3.FORWARD if absf(y_axis.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x_axis := y_axis.cross(ref).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()

	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = r_b
	m.bottom_radius = r_a
	m.height = length
	m.radial_segments = 8
	mi.mesh = m
	mi.material_override = mat
	mi.transform = Transform3D(Basis(x_axis, y_axis, z_axis), (a + b) * 0.5)
	parent.add_child(mi)
