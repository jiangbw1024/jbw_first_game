class_name FxRoot
extends Node3D
## 所有"打出去"的视觉：曳光、弹孔火花、血雾、弹壳、枪口补光
##
## 为什么要做对象池而不是每次 new：
##   一分钟能打出上百发。每发都 new 一个 GPUParticles3D + 一套材质，
##   会在十几秒内堆出几千个节点，然后卡到不能玩。
##   池化的思路是"节点一次建够，之后只改状态"，这是高频特效的标准做法。
##
## 为什么放在 World 下而不是挂在玩家身上：
##   弹壳落地、血迹留在原地，不该跟着玩家走。

const TRACER_COUNT := 24
const IMPACT_COUNT := 16
const SHELL_COUNT := 12
const TRACER_LIFE := 0.075
const SHELL_LIFE := 2.2

var _tracers: Array[MeshInstance3D] = []
var _tracer_life: Array[float] = []

var _impacts: Array[GPUParticles3D] = []
var _impact_mats: Array[ParticleProcessMaterial] = []

var _shells: Array[RigidBody3D] = []
var _shell_life: Array[float] = []

var _flash: OmniLight3D
var _flash_t := 0.0

var _tracer_mesh: BoxMesh


func _ready() -> void:
	add_to_group("fx")
	_tracer_mesh = BoxMesh.new()
	_tracer_mesh.size = Vector3.ONE

	var tracer_mat := StandardMaterial3D.new()
	tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer_mat.albedo_color = Color(1.0, 0.90, 0.68, 0.85)
	tracer_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tracer_mat.disable_receive_shadows = true

	for i in TRACER_COUNT:
		var mi := MeshInstance3D.new()
		mi.mesh = _tracer_mesh
		mi.material_override = tracer_mat
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_tracers.append(mi)
		_tracer_life.append(0.0)

	for i in IMPACT_COUNT:
		_impacts.append(_make_impact())
		_impact_mats.append(null)   # 实际材质在 _make_impact 里塞进 meta

	for i in SHELL_COUNT:
		_shells.append(_make_shell())
		_shell_life.append(0.0)

	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.78, 0.42)
	_flash.omni_range = 6.0
	_flash.light_energy = 0.0
	_flash.shadow_enabled = false
	add_child(_flash)


func _process(delta: float) -> void:
	for i in _tracers.size():
		if _tracer_life[i] > 0.0:
			_tracer_life[i] -= delta
			if _tracer_life[i] <= 0.0:
				_tracers[i].visible = false

	for i in _shells.size():
		if _shell_life[i] > 0.0:
			_shell_life[i] -= delta
			if _shell_life[i] <= 0.0:
				_shells[i].freeze = true
				_shells[i].visible = false

	if _flash_t > 0.0:
		_flash_t -= delta
		_flash.light_energy = maxf(0.0, _flash.light_energy - delta * 45.0)
		if _flash_t <= 0.0:
			_flash.light_energy = 0.0


# ------------------------------------------------------------
# 曳光
# ------------------------------------------------------------
func spawn_tracer(from: Vector3, to: Vector3) -> void:
	var d := to - from
	var length := d.length()
	if length < 0.05:
		return
	var i := _free_tracer()
	var mi := _tracers[i]
	mi.visible = true
	mi.global_position = from + d * 0.5
	# 让盒子的 -Z 指向终点；再沿 Z 拉长到实际距离
	mi.look_at(to, Vector3.UP)
	mi.scale = Vector3(0.009, 0.009, length)
	_tracer_life[i] = TRACER_LIFE


func _free_tracer() -> int:
	# 找一个已经熄灭的；全都在亮就抢最老的那个（视觉上分辨不出来）
	var oldest := 0
	var best := INF
	for i in _tracer_life.size():
		if _tracer_life[i] <= 0.0:
			return i
		if _tracer_life[i] < best:
			best = _tracer_life[i]
			oldest = i
	return oldest


# ------------------------------------------------------------
# 命中特效
# ------------------------------------------------------------
### flesh=true 打的是活物（血雾偏红、慢、有重力）
## head=true 爆头（血更多、更快）
func spawn_impact(pos: Vector3, normal: Vector3, flesh: bool, head: bool) -> void:
	var i := _free_impact()
	var p := _impacts[i]
	var m: ParticleProcessMaterial = p.get_meta("pm")

	p.global_position = pos + normal * 0.02
	p.emitting = false

	# 方向沿法线反弹，加一个锥形扩散
	m.direction = normal
	m.spread = 55.0
	if flesh:
		m.initial_velocity_min = 1.8
		m.initial_velocity_max = 4.2 if not head else 5.6
		m.gravity = Vector3(0, -7.0, 0)
		m.scale_min = 0.9
		m.scale_max = 2.2 if not head else 3.2
	else:
		m.initial_velocity_min = 2.0
		m.initial_velocity_max = 6.0
		m.gravity = Vector3(0, -12.0, 0)
		m.scale_min = 0.4
		m.scale_max = 1.0

	var mesh: QuadMesh = p.draw_pass_1
	var mat: StandardMaterial3D = mesh.material
	if flesh:
		# 血用 MIX 而不是 ADD：加法混合会让血发亮，像"荧光番茄酱"
		mat.albedo_color = Color(0.55, 0.03, 0.03, 1.0)
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	else:
		mat.albedo_color = Color(1.0, 0.72, 0.30, 1.0)
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD

	p.restart()
	p.emitting = true


func _free_impact() -> int:
	# 命中特效很短（0.45 秒），直接轮转即可，不需要精确找空闲
	if not has_meta("impact_cursor"):
		set_meta("impact_cursor", 0)
	var i: int = get_meta("impact_cursor")
	set_meta("impact_cursor", (i + 1) % _impacts.size())
	return i


func _make_impact() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 14
	p.lifetime = 0.45
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# ★ 必须有：local_coords=false 时粒子会飞出节点原点，但引擎仍按节点自身的
	#   包围盒做视锥裁剪 —— 盒子太小就会被整批剔掉，表现是"偶尔喷一下、大部分时候没有"。
	p.visibility_aabb = AABB(Vector3(-2.5, -2.5, -2.5), Vector3(5, 5, 5))

	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.05
	m.spread = 55.0
	m.initial_velocity_min = 2.0
	m.initial_velocity_max = 6.0
	m.gravity = Vector3(0, -12.0, 0)
	m.scale_min = 0.4
	m.scale_max = 1.0
	m.damping_min = 1.0
	m.damping_max = 4.0
	p.process_material = m
	p.set_meta("pm", m)

	var quad := QuadMesh.new()
	quad.size = Vector2(0.15, 0.15)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# ★ BILLBOARD_PARTICLES 而不是 BILLBOARD_ENABLED：
	#   后者按"节点原点"计算朝向，所有粒子共享同一个朝向，
	#   侧看时就变成一条条细线，只剩零星几个点。
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_texture = FxTex.radial()
	mat.albedo_color = Color(1.0, 0.72, 0.30, 1.0)
	mat.disable_receive_shadows = true
	quad.material = mat
	p.draw_pass_1 = quad

	add_child(p)
	return p


# ------------------------------------------------------------
# 弹壳
# ------------------------------------------------------------
func spawn_shell(pos: Vector3, right: Vector3, up: Vector3) -> void:
	if not has_meta("shell_cursor"):
		set_meta("shell_cursor", 0)
	var i: int = get_meta("shell_cursor")
	set_meta("shell_cursor", (i + 1) % _shells.size())
	var b := _shells[i]

	b.freeze = true
	b.visible = true
	b.global_position = pos
	b.linear_velocity = Vector3.ZERO
	b.angular_velocity = Vector3.ZERO
	b.freeze = false
	# 往右上方抛出，带一点随机，否则每发都一模一样
	var jitter := Vector3(randf_range(-0.4, 0.4), randf_range(0.0, 0.5), randf_range(-0.4, 0.4))
	b.apply_central_impulse((right * 1.6 + up * 1.9 + jitter) * 0.02)
	b.apply_torque_impulse(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.004)
	_shell_life[i] = SHELL_LIFE


func _make_shell() -> RigidBody3D:
	var b := RigidBody3D.new()
	b.freeze = true
	b.collision_layer = 0
	b.collision_mask = Layers.WORLD
	b.mass = 0.02

	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.012, 0.012, 0.03)
	cs.shape = shape
	b.add_child(cs)

	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.012, 0.012, 0.03)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.60, 0.30)
	mat.metallic = 0.9
	mat.roughness = 0.35
	mi.material_override = mat
	b.add_child(mi)

	add_child(b)
	return b


# ------------------------------------------------------------
# 枪口补光
# ------------------------------------------------------------
### 一瞬间的点光。它的作用不是"照亮"，是让枪口在暗处"闪一下"——
## 少了这一步，夜里的枪会像玩具。
func flash(pos: Vector3, energy := 3.0) -> void:
	_flash.global_position = pos
	_flash.light_energy = energy
	_flash_t = 0.06
