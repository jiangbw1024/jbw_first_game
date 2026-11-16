class_name KnifeView
extends Node3D
## 第一人称蝴蝶刀：程序化几何 + 拉刀/收刀/检视/轻击/重击
##
## 为什么单独一个视图，而不是塞进 WeaponView：
##   枪的动画是"后坐力 + 换弹下沉"，刀的动画是"绕枢轴翻转 + 手腕甩动"。
##   两套状态机硬塞进一个脚本，最后会变成一堆 if；分开后，
##   WeaponView 继续只管枪，KnifeView 只管刀，玩家只负责在两者之间切可见性。
##
## 坐标系：本节点挂在 Camera3D 下，所以 +X 右、+Y 上、-Z 前（屏幕里）。

const KnifeDefScript = preload("res://scripts/combat/knife_def.gd")

## 刀身沿 -Z，刀柄沿 +Z；Y 旋转把刀身甩向左上，同时把宽面转向相机。
const BASE_POS := Vector3(0.185, -0.150, -0.330)
const BASE_ROT := Vector3(0.28, 1.05, -0.18)
const VIEW_SCALE := 0.95

const DRAW_POS := BASE_POS + Vector3(0.10, -0.34, 0.12)
const DRAW_ROT := BASE_ROT + Vector3(-0.42, 0.58, -0.30)
const HOLSTER_POS := BASE_POS + Vector3(0.12, -0.36, 0.14)
const HOLSTER_ROT := BASE_ROT + Vector3(-0.50, 0.70, -0.34)

var move_speed := 0.0
var on_floor := true

var _rig: Node3D
var _blade_pivot: Node3D
var _handle_l: Node3D
var _handle_r: Node3D
var _meshes: Array[MeshInstance3D] = []
var _tex_cache: Dictionary = {}

var _state := "idle"
var _t := 0.0
var _duration := 0.0
var _sway := Vector2.ZERO
var _sway_target := Vector2.ZERO
var _bob_t := 0.0
var _idle_t := 0.0


func _ready() -> void:
	scale = Vector3.ONE * VIEW_SCALE
	visible = false
	_build()
	_apply_pose(Vector3.ZERO)


# ------------------------------------------------------------
# 外部事件
# ------------------------------------------------------------
func play_draw() -> void:
	_begin("draw", float(KnifeDefScript.get_def("butterfly").get("draw_duration", 0.45)))


func play_holster() -> void:
	_begin("holster", 0.30)


func play_inspect() -> void:
	_begin("inspect", float(KnifeDefScript.get_def("butterfly")["inspect_duration"]))


func play_attack(heavy: bool) -> void:
	if heavy:
		_begin("stab", float(KnifeDefScript.get_def("butterfly")["heavy_duration"]))
	else:
		_begin("slash", float(KnifeDefScript.get_def("butterfly")["light_duration"]))


func is_busy() -> bool:
	return _state != "idle"


### 鼠标移动时调用：刀会"跟不上"转身，产生重量感。
func add_sway(rel: Vector2) -> void:
	_sway_target.x = clampf(-rel.x * 0.00035, -0.02, 0.02)
	_sway_target.y = clampf(-rel.y * 0.00035, -0.02, 0.02)
	_sway += (_sway_target - _sway) * 0.35
	_sway_target = Vector2.ZERO


func _begin(state: String, duration: float) -> void:
	_state = state
	_t = 0.0
	_duration = maxf(0.05, duration)


# ------------------------------------------------------------
# 每帧
# ------------------------------------------------------------
func _process(delta: float) -> void:
	_idle_t += delta
	_sway = _sway.lerp(Vector2.ZERO, clampf(delta * 9.0, 0.0, 1.0))

	var bob := Vector3.ZERO
	if on_floor and move_speed > 0.4:
		_bob_t += delta * (6.0 + move_speed * 0.9)
		var amp: float = clampf(move_speed / 8.5, 0.0, 1.0) * 0.012
		bob.x = sin(_bob_t) * amp
		bob.y = absf(cos(_bob_t)) * amp * 0.8
	else:
		_bob_t = lerp(_bob_t, 0.0, delta * 4.0)

	if _state != "idle":
		_t += delta
		if _t >= _duration:
			_state = "idle"
			_t = 0.0

	_apply_pose(bob)


func _apply_pose(bob: Vector3) -> void:
	if _rig == null or _handle_l == null or _handle_r == null:
		return

	var pos := BASE_POS + Vector3(_sway.x, _sway.y + bob.y, 0.0) + bob
	var rot := BASE_ROT + Vector3(0.0, _sway.x * 1.2, _sway.x * 0.6)
	var handle_l := 0.018 * sin(_idle_t * 1.7)
	var handle_r := -0.014 * sin(_idle_t * 1.9 + 0.7)

	# 呼吸：幅度很小，只负责让刀"活着"，不是待机翻转。
	pos.y += sin(_idle_t * 1.5) * 0.0018

	var p := 0.0
	var e := 0.0
	match _state:
		"draw":
			p = clampf(_t / _duration, 0.0, 1.0)
			e = _ease_out_cubic(p)
			pos = DRAW_POS.lerp(BASE_POS, e) + Vector3(_sway.x, _sway.y + bob.y, 0.0) + bob
			rot = DRAW_ROT.lerp(BASE_ROT, e)
			rot.y += sin(p * PI) * 0.55
			rot.z += sin(p * PI) * 0.20
			handle_l = lerpf(PI * 0.95, 0.0, e)
			handle_r = lerpf(PI * 1.10, 0.0, _ease_out_cubic(clampf(p * 1.18, 0.0, 1.0)))
		"holster":
			p = clampf(_t / _duration, 0.0, 1.0)
			e = _ease_in_cubic(p)
			pos = BASE_POS.lerp(HOLSTER_POS, e) + Vector3(_sway.x, _sway.y + bob.y, 0.0) + bob
			rot = BASE_ROT.lerp(HOLSTER_ROT, e)
			handle_l = lerpf(0.0, PI * 0.90, e)
			handle_r = lerpf(0.0, PI * 1.02, e)
		"inspect":
			p = clampf(_t / _duration, 0.0, 1.0)
			e = _smoothstep(p)
			rot.y += e * TAU
			rot.z += sin(p * PI) * 0.55
			rot.x += sin(p * PI) * 0.20
			pos.y += sin(p * PI) * 0.055
			handle_l = sin(p * PI) * 1.35
			handle_r = -sin(p * PI) * 0.75
		"slash":
			p = clampf(_t / _duration, 0.0, 1.0)
			var a := sin(p * PI)
			rot.y -= a * 1.15
			rot.z += a * 0.85
			rot.x += a * 0.15
			pos.x -= a * 0.075
			pos.z += a * 0.035
			handle_l = a * 0.20
			handle_r = a * 0.35
		"stab":
			p = clampf(_t / _duration, 0.0, 1.0)
			var wind := clampf(p / 0.70, 0.0, 1.0)
			var thrust := clampf((p - 0.70) / 0.30, 0.0, 1.0)
			pos.z += wind * 0.055 - thrust * 0.185
			pos.y -= wind * 0.020
			rot.x -= wind * 0.16 + thrust * 0.30
			rot.y += thrust * 0.18
			handle_l = wind * 0.10
			handle_r = wind * 0.16

	_rig.position = pos
	_rig.rotation = rot
	_handle_l.rotation.x = handle_l
	_handle_r.rotation.x = handle_r


# ------------------------------------------------------------
# 模型
# ------------------------------------------------------------
func _build() -> void:
	_rig = Node3D.new()
	_rig.position = BASE_POS
	_rig.rotation = BASE_ROT
	add_child(_rig)

	var blade_mat := _mat(Color(0.46, 0.48, 0.53), 0.82, 0.30, _grain(0.16, 0.20, 31))
	var edge_mat := _mat(Color(0.70, 0.73, 0.78), 0.92, 0.16, _grain(0.30, 0.14, 32))
	var handle_l_mat := _mat(Color(0.060, 0.063, 0.070), 0.45, 0.38, _grain(0.34, 0.18, 33))
	var handle_r_mat := _mat(Color(0.092, 0.095, 0.103), 0.48, 0.35, _grain(0.30, 0.17, 39))
	var inlay_mat := _mat(Color(0.30, 0.31, 0.33), 0.70, 0.26, _grain(0.22, 0.20, 34))
	var pin_mat := _mat(Color(0.62, 0.64, 0.68), 0.90, 0.18, _grain(0.40, 0.12, 35))
	var glove := _mat(Color(0.095, 0.092, 0.082), 0.0, 0.72, _grain(0.55, 0.20, 36), 0.08)
	var pad := _mat(Color(0.17, 0.165, 0.15), 0.0, 0.52, _grain(0.75, 0.16, 37), 0.12)
	var sleeve := _mat(Color(0.070, 0.074, 0.064), 0.0, 0.92, _grain(0.85, 0.14, 38), 0.04)

	_blade_pivot = Node3D.new()
	_rig.add_child(_blade_pivot)

	# 刀身：自定义多边形，不是方盒。刀尖和斜削的假刃全靠这个轮廓。
	_blade_mesh(_blade_pivot, blade_mat)
	# 刃口高光：一条很薄的亮边，让刀在暗处也有"锋利"的读数
	_cyl(_blade_pivot, 0.0022, 0.30, Vector3(0, -0.020, -0.165), edge_mat,
		Vector3(PI * 0.5, 0, 0), 6)
	# 血槽：一条暗线，纯色刀面会显得像塑料片
	_cyl(_blade_pivot, 0.0018, 0.20, Vector3(0, 0.004, -0.120), handle_l_mat,
		Vector3(PI * 0.5, 0, 0), 6)

	# 两个刀柄各自绕枢轴转，蝴蝶刀的识别度全在这里。
	_handle_l = Node3D.new()
	_handle_l.position = Vector3(-0.012, 0.006, 0.0)
	_handle_l.rotation.z = 0.040
	_rig.add_child(_handle_l)
	_handle_r = Node3D.new()
	_handle_r.position = Vector3(0.012, -0.006, 0.0)
	_handle_r.rotation.z = -0.040
	_rig.add_child(_handle_r)
	_handle(_handle_l, -1.0, handle_l_mat, inlay_mat)
	_handle(_handle_r, 1.0, handle_r_mat, inlay_mat)

	# 枢轴销：穿过两个刀柄的轴心
	_cyl(_rig, 0.0085, 0.030, Vector3.ZERO, pin_mat, Vector3(0, 0, PI * 0.5), 12)
	_cyl(_rig, 0.0040, 0.034, Vector3.ZERO, edge_mat, Vector3(0, 0, PI * 0.5), 10)

	_build_hand(glove, pad, sleeve)


### 刀身轮廓（Y-Z 平面，X 是厚度）。点顺序决定三角面，不能乱。
func _blade_mesh(parent: Node3D, mat: Material) -> void:
	var pts: Array[Vector2] = [
		Vector2(0.000, -0.021),    # 根部下缘
		Vector2(-0.245, -0.021),   # 直刃
		Vector2(-0.338, 0.000),    # 刀尖
		Vector2(-0.245, 0.022),    # 刀背
		Vector2(0.000, 0.022),     # 根部上缘
	]
	var th := 0.0032
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 两侧大面。法线由 generate_normals 生成，材质关闭背面剔除，
	# 所以从哪边看都能看到完整刀面。
	for tri in [[0, 1, 2], [0, 2, 3], [0, 3, 4]]:
		for idx in tri:
			st.add_vertex(Vector3(th, pts[idx].y, pts[idx].x))
	for tri in [[0, 2, 1], [0, 3, 2], [0, 4, 3]]:
		for idx in tri:
			st.add_vertex(Vector3(-th, pts[idx].y, pts[idx].x))

	# 刃口/刀背的侧壁
	for i in pts.size():
		var j := (i + 1) % pts.size()
		var a := pts[i]
		var b := pts[j]
		for v in [
			Vector3(th, a.y, a.x), Vector3(-th, a.y, a.x), Vector3(th, b.y, b.x),
			Vector3(th, b.y, b.x), Vector3(-th, a.y, a.x), Vector3(-th, b.y, b.x),
		]:
			st.add_vertex(v)

	st.generate_normals()
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_meshes.append(mi)


func _handle(parent: Node3D, side: float, handle_mat: Material, inlay_mat: Material) -> void:
	# 主柄：长条。末端略宽，像蝴蝶刀的柄尾。
	_box(parent, Vector3(0.010, 0.031, 0.285), Vector3(0, 0, 0.150), handle_mat)
	_box(parent, Vector3(0.012, 0.035, 0.020), Vector3(0, 0, 0.292), handle_mat)
	# 外侧镶嵌：给深色柄一个能被眼睛抓住的明暗分层
	_box(parent, Vector3(0.0022, 0.018, 0.205), Vector3(side * 0.0062, 0, 0.150), inlay_mat)
	_box(parent, Vector3(0.0022, 0.006, 0.230), Vector3(side * 0.0065, 0.012, 0.145), inlay_mat)
	# 内侧开槽的暗线：没有它，两个柄会糊成一块黑板
	_box(parent, Vector3(0.0020, 0.004, 0.240), Vector3(side * -0.0052, 0, 0.150), inlay_mat)


func _build_hand(glove: Material, pad: Material, sleeve: Material) -> void:
	# 右手握在枢轴后方。手掌、手背护片、手指、拇指各一层，
	# 深色手套只负责贡献轮廓，不追求指节细节。
	_box(_rig, Vector3(0.038, 0.048, 0.068), Vector3(0.0, -0.026, 0.100), glove,
		Vector3(0.18, 0.0, 0.05))
	_box(_rig, Vector3(0.028, 0.008, 0.044), Vector3(0.019, -0.016, 0.100), pad,
		Vector3(0.18, 0.0, 0.05))

	for i in 3:
		var y := -0.043 - i * 0.010
		_box(_rig, Vector3(0.032, 0.009, 0.014), Vector3(0.0, y, 0.068 + i * 0.016), glove,
			Vector3(0.0, 0.0, 0.10))
	# 拇指从掌根扣到柄上
	_box(_rig, Vector3(0.014, 0.012, 0.042), Vector3(0.017, -0.010, 0.096), glove,
		Vector3(0.0, 0.35, -0.20))

	# 护腕：把"手"和"袖子"断开，否则深色块会连成一根柱子
	_limb(Vector3(0.0, -0.064, 0.148), Vector3(0.012, -0.092, 0.184),
		0.030, 0.028, pad, 10)

	# 前臂：从画面右下伸进来。方向必须朝外，不能朝相机缩，
	# 否则透视会把胳膊放大成一根糊在屏幕上的柱子。
	_limb(Vector3(0.0, -0.078, 0.165), Vector3(0.064, -0.225, 0.350),
		0.026, 0.036, sleeve, 10)
	_limb(Vector3(0.058, -0.212, 0.342), Vector3(0.175, -0.470, 0.560),
		0.034, 0.044, sleeve, 10)


# ------------------------------------------------------------
# 几何工具
# ------------------------------------------------------------
func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material,
		rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_meshes.append(mi)
	return mi


func _cyl(parent: Node3D, radius: float, length: float, pos: Vector3,
		mat: Material, rot := Vector3.ZERO, segs := 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = segs
	mesh.rings = 1
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_meshes.append(mi)
	return mi


func _limb(a: Vector3, b: Vector3, r_a: float, r_b: float, mat: Material,
		segs := 8) -> MeshInstance3D:
	var dir := b - a
	var length := dir.length()
	if length < 0.001:
		return null
	var y_axis := dir / length
	var ref := Vector3.FORWARD if absf(y_axis.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x_axis := y_axis.cross(ref).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()

	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = r_b
	mesh.bottom_radius = r_a
	mesh.height = length
	mesh.radial_segments = segs
	mesh.rings = 2
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(Basis(x_axis, y_axis, z_axis), (a + b) * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(mi)
	_meshes.append(mi)
	return mi


func _grain(freq: float, contrast: float, seed_v: int) -> NoiseTexture2D:
	var key := "%.2f_%.2f_%d" % [freq, contrast, seed_v]
	if _tex_cache.has(key):
		return _tex_cache[key]

	var n := FastNoiseLite.new()
	n.seed = seed_v
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = freq
	n.fractal_octaves = 4

	var nt := NoiseTexture2D.new()
	nt.noise = n
	nt.width = 64
	nt.height = 64
	nt.generate_mipmaps = true

	var g := Gradient.new()
	var lo := 1.0 - contrast
	g.set_color(0, Color(lo, lo, lo))
	g.set_color(1, Color(1, 1, 1))
	nt.color_ramp = g
	_tex_cache[key] = nt
	return nt


func _mat(base: Color, metallic: float, roughness: float, tex: Texture2D,
		specular := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = base
	m.albedo_texture = tex
	m.metallic = metallic
	m.roughness = roughness
	m.metallic_specular = specular
	# 刀是薄片，必须双面可见，否则从背面看会直接消失
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _ease_out_cubic(p: float) -> float:
	return 1.0 - pow(1.0 - p, 3.0)


func _ease_in_cubic(p: float) -> float:
	return p * p * p


func _smoothstep(p: float) -> float:
	return p * p * (3.0 - 2.0 * p)
