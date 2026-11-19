class_name WeaponView
extends Node3D
## 第一人称手持武器：程序化几何 + 后坐力动画 + 摇晃 + 呼吸 + 枪口火光
##
## 这一层是"手感"最容易被忽略、却最影响体感的部分。
## 枪不是钉在屏幕上的 —— 它会因为后坐力往后顶、因为你转身而滞后、因为走路而晃。
## 少了这些，再好的音效也像在"放视频"。
##
## 坐标系：本节点挂在 Camera3D 下，所以 +X 右、+Y 上、-Z 前（屏幕里）。

## 第一人称姿态。参考的是经典 FPS 的"斜跨胸前"构图：
## 枪托落在画面右下角之外，护木横在中间，枪口指向准心左上方。
##
## 三个参数的关系：
##   BASE_POS   —— 整把枪挂在相机前的哪个位置。z 越接近 0 越大（透视放大）
##   BASE_ROT   —— yaw 为正时枪口向左偏。**这点偏转是刻意的**：
##                 真实持枪时枪身并不在眼睛正下方，而是斜跨身体，
##                 所以枪管方向天然和视线有一个小夹角
##   VIEW_SCALE —— 统一缩放。0.62 时枪像挂在 80cm 外，0.74 才像"贴在肩上"
const BASE_POS := Vector3(0.148, -0.118, -0.306)
const VIEW_SCALE := 0.75
const BASE_ROT := Vector3(0.0, 0.015, 0.0)
const HOLSTER_POS := BASE_POS + Vector3(0.080, -0.380, 0.140)
const HOLSTER_ROT := BASE_ROT + Vector3(-0.55, 0.45, -0.38)
const EQUIP_LOW_POS := BASE_POS + Vector3(0.070, -0.360, 0.160)
const EQUIP_LOW_ROT := BASE_ROT + Vector3(-0.48, 0.38, -0.28)
const BOLT_PULL_DISTANCE := 0.055

signal bolt_racked

var weapon_id := "ak47"
var muzzle: Node3D

var _meshes: Array[MeshInstance3D] = []
var _tex_cache: Dictionary = {}
var _flash: MeshInstance3D
var _flash_light: OmniLight3D
var _flash_t := 0.0

# 动画状态
var _kick_z := 0.0          # 后坐力：往后顶
var _kick_rot := 0.0        # 后坐力：枪口上跳
var _sway := Vector2.ZERO   # 转身滞后
var _sway_target := Vector2.ZERO
var _bob_t := 0.0
var _reload_t := 0.0

# 切枪过渡：收枪和抬枪都从"当前这一帧的真实姿态"开始，
# 这样换弹到一半切刀时，枪不会先瞬移回普通待机姿势。
var _transition := "idle"       # idle / holster / equip / stowed / return
var _transition_t := 0.0
var _transition_duration := 0.0
var _transition_from_pos := BASE_POS
var _transition_from_rot := BASE_ROT
var _bolt_handle: MeshInstance3D
var _bolt_rest_pos := Vector3(0.040, 0.026, -0.10)
var _bolt_racked_sent := false

# 由玩家每帧写入
var move_speed := 0.0
var on_floor := true
var reloading := false
var reload_ratio := 0.0


func _ready() -> void:
	scale = Vector3.ONE * VIEW_SCALE
	position = BASE_POS
	rotation = BASE_ROT
	_build(weapon_id)


# ------------------------------------------------------------
# 武器外观
# ------------------------------------------------------------
func set_weapon(id: String) -> void:
	if id == weapon_id and not _meshes.is_empty():
		return
	weapon_id = id
	_build(id)


func _build(id: String) -> void:
	for m in _meshes:
		if is_instance_valid(m):
			m.queue_free()
	_meshes.clear()
	_bolt_handle = null
	if muzzle != null:
		muzzle.queue_free()
		muzzle = null

	# 四种材质，靠"金属度 / 粗糙度 / 纹理"把它们区分开。
	# 之前的版本四种颜色共用一个 metallic=0.55，所以哪一块看起来都像同一种塑料。
	var blued := _mat(Color(0.135, 0.140, 0.155), 0.62, 0.26, _grain(0.10, 0.34, 11))   # 发黑钢：机匣
	var steel := _mat(Color(0.330, 0.340, 0.360), 0.75, 0.36, _grain(0.16, 0.28, 12))   # 磨光钢：枪管
	var wood := _mat(Color(0.255, 0.150, 0.082), 0.0, 0.52, _grain(0.07, 0.45, 13))     # 木：护木/枪托
	var poly := _mat(Color(0.080, 0.082, 0.090), 0.0, 0.62, _grain(0.30, 0.22, 14))     # 聚合物：握把/托底板

	match id:
		_:
			# AK47 的辨识度来自四件事：长枪管、木质护木、香蕉弹匣、圆弧防尘盖。
			# 前三个靠轮廓，第四个靠"机匣上方不该是方角"—— 这一条最容易被忽略，
			# 但它正是"盒子堆出来的枪"和"枪"的分界线。
			# 坐标沿用原版：muzzle 必须仍在 (0, 0.020, -0.67)，
			# 因为曳光起点、火光位置都读它。
			_box(Vector3(0.056, 0.074, 0.40), Vector3(0, -0.002, -0.08), blued)     # 机匣
			# 防尘盖：半埋在机匣上方的圆柱。AK 的机匣顶部是拱形，
			# 用圆柱一盖，方盒子的硬棱就消失了，剪影立刻从"砖头"变成"枪"
			_cyl(0.042, 0.34, Vector3(0, 0.010, -0.10), blued, 14)
			_bolt_handle = _box(Vector3(0.030, 0.010, 0.012),
				_bolt_rest_pos, steel) # 拉机柄

			# 护木是圆柱而不是盒子 —— AK 的护木本来就是圆的，
			# 而且圆面能接到环境光的连续渐变，边缘不会有硬阶梯
			_cyl(0.034, 0.25, Vector3(0, -0.006, -0.300), wood, 14)                 # 下护木
			_cyl(0.021, 0.21, Vector3(0, 0.042, -0.300), wood, 12)                  # 上护木
			# 护木上的两道束带：没有它，那块木头看起来像一根光溜溜的擀面杖
			_cyl(0.036, 0.010, Vector3(0, -0.006, -0.212), steel, 14)
			_cyl(0.036, 0.010, Vector3(0, -0.006, -0.390), steel, 14)
			_cyl(0.011, 0.30, Vector3(0, 0.020, -0.520), steel, 10)                 # 枪管
			_cyl(0.009, 0.24, Vector3(0, 0.054, -0.340), steel, 8)                  # 导气管
			_cyl(0.016, 0.055, Vector3(0, 0.020, -0.665), blued, 10)                # 枪口制退器

			_box(Vector3(0.020, 0.032, 0.045), Vector3(0, 0.074, -0.600), steel)     # 准星座
			_box(Vector3(0.004, 0.026, 0.030), Vector3(-0.011, 0.081, -0.600), steel) # 准星左护翼
			_box(Vector3(0.004, 0.026, 0.030), Vector3(0.011, 0.081, -0.600), steel)  # 准星右护翼
			_box(Vector3(0.046, 0.014, 0.10), Vector3(0, 0.056, 0.020), steel)       # 表尺座

			# 枪托：三段逐级收窄，形成 AK 那种下斜的托身
			# ★ 枪托必须向外偏（+X），不能和机匣同轴。
			#   同轴时枪托正好在握把和相机之间，把右手整个挡住 ——
			#   真实持枪是"枪托抵右肩"，本来就在身体右侧，所以外偏既正确又解决问题
			_box(Vector3(0.050, 0.090, 0.11), Vector3(0.010, -0.028, 0.145), wood, Vector3(0, -0.22, 0))
			_box(Vector3(0.046, 0.078, 0.11), Vector3(0.036, -0.046, 0.232), wood, Vector3(0, -0.22, 0))
			_box(Vector3(0.050, 0.086, 0.018), Vector3(0.054, -0.054, 0.284), poly, Vector3(0, -0.22, 0))  # 托底板
			_box(Vector3(0.044, 0.100, 0.052), Vector3(0, -0.106, 0.056), poly, Vector3(0.30, 0, 0))  # 握把

			# 扳机护圈：三段细盒折成一个"圈"，比一整块盒子更像枪
			_box(Vector3(0.008, 0.006, 0.048), Vector3(0, -0.062, -0.020), blued)
			_box(Vector3(0.008, 0.020, 0.006), Vector3(0, -0.052, -0.042), blued)
			_box(Vector3(0.008, 0.020, 0.006), Vector3(0, -0.052, 0.002), blued)
			_box(Vector3(0.007, 0.024, 0.008), Vector3(0, -0.046, -0.028), steel)     # 扳机

			# 香蕉弹匣：**沿切线逐段前进**生成，而不是手填 6 组坐标。
			# 每段的朝向 = 当前累积角度，位置 = 沿这个角度走一步。
			# 好处是改弯度（0.155）和长度（0.048）就够了，弧线自动保持平滑。
			var mz := -0.104
			var my := -0.076
			var ang := 0.05
			for i in 6:
				ang += 0.155
				_box(Vector3(0.048, 0.050, 0.052), Vector3(0, my, mz), blued, Vector3(ang, 0, 0))
				my -= 0.048 * cos(ang)
				mz += 0.028 * sin(ang)
			_muzzle(Vector3(0, 0.020, -0.67))

	_build_arms()

	_flash = _make_flash()
	add_child(_flash)
	_flash.visible = false

	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.80, 0.45)
	_flash_light.omni_range = 4.5
	_flash_light.light_energy = 0.0
	_flash_light.shadow_enabled = false
	add_child(_flash_light)


func _box(size: Vector3, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	# 手持模型不投影：否则会在脚下投出一大块枪影，很怪
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_meshes.append(mi)
	return mi


### 圆柱件（枪管、护木、导气管）。盒子的截面永远是个方角，
### 只有圆的零件在转动视角时会连续地接过环境光，才不会闪出一圈硬边。
func _cyl(radius: float, length: float, pos: Vector3, mat: Material, segs := 12) -> MeshInstance3D:
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
	# CylinderMesh 沿 Y 轴生长，枪管要沿 Z 轴，所以绕 X 转 90°
	mi.rotation = Vector3(PI * 0.5, 0, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_meshes.append(mi)
	return mi


# ------------------------------------------------------------
# 手与手臂
# ------------------------------------------------------------
### 第一人称的"真实感"，一半来自手。
##
## 只有一把悬空的枪 = 观众立刻读成"游戏里的模型"；
## 有手、有前臂从画面外伸进来托着 = 读成"我在拿这把枪"。
##
## ★ 为什么是"战术手套 + 长袖"，而不是露皮肤：
##   程序化几何做不出指节、指甲、皮下血色和手腕的骨点过渡。
##   一旦露肉，观众会立刻盯着那块不自然的肉色——**问题被放大了**。
##   换成深色手套之后，手只负责贡献"轮廓"和"遮挡关系"，
##   而这两件事正是程序化几何能做好的部分。
##
##   材质分层是关键，否则深色的手和深色的枪会糊成一团：
##     glove  粗糙度 0.58 —— 尼龙手套有微光，和枪的金属光泽区分开
##     pad    亮一档     —— 手背护片，提供能被眼睛抓住的明暗分界
##     sleeve 最粗糙     —— 布料吸光，把手臂压成"暗色背景"
func _build_arms() -> void:
	var glove := _mat(Color(0.175, 0.168, 0.150), 0.0, 0.66, _grain(0.55, 0.20, 21), 0.10)
	var pad := _mat(Color(0.300, 0.292, 0.268), 0.0, 0.46, _grain(0.85, 0.16, 23), 0.18)
	var sleeve := _mat(Color(0.062, 0.066, 0.054), 0.0, 0.95, _grain(0.9, 0.14, 22), 0.04)

	# ★ 手臂必须朝**画面左右两侧**延伸出去，绝对不能朝相机方向（+Z）缩。
	#   相机就在 z = +0.31 处，前臂末端一旦靠近这个平面，透视会把胳膊
	#   放大成一根糊在屏幕中央的粗柱子 —— 我第一次写就踩了这个坑。
	#
	# ---- 右手：握住握把，前臂从右下角伸出画面 ----
	_hand_grip(glove, pad)
	_limb(Vector3(0.044, -0.118, 0.086), Vector3(0.086, -0.146, 0.108), 0.047, 0.049, sleeve, 10)  # 护腕
	_limb(Vector3(0.078, -0.140, 0.102), Vector3(0.235, -0.400, 0.290), 0.041, 0.051, sleeve)
	_limb(Vector3(0.228, -0.386, 0.284), Vector3(0.360, -0.610, 0.380), 0.049, 0.058, sleeve)

	# ---- 左手：托住护木，前臂从左下角横着伸过来 ----
	_hand_guard(glove, pad)
	_limb(Vector3(-0.020, -0.078, -0.288), Vector3(-0.056, -0.096, -0.272), 0.046, 0.048, sleeve, 10)  # 护腕
	_limb(Vector3(0.010, -0.092, -0.284), Vector3(-0.175, -0.440, -0.150), 0.038, 0.052, sleeve)
	_limb(Vector3(-0.168, -0.412, -0.158), Vector3(-0.290, -0.625, -0.070), 0.049, 0.058, sleeve)


### 右手：掌心贴在握把右侧，四指绕到前面，拇指从上方扣住
func _hand_grip(glove: Material, pad: Material) -> void:
	_box(Vector3(0.052, 0.078, 0.062), Vector3(0.030, -0.102, 0.058), glove, Vector3(0.30, 0.0, 0.08))
	# 手背护片：一块略亮的平板贴在手套外侧。
	# 它不是为了"好看"，而是给纯深色的手一个明暗分界 ——
	# 否则手在阴影里就是一团看不清轮廓的黑。
	_box(Vector3(0.038, 0.010, 0.050), Vector3(0.041, -0.088, 0.062), pad, Vector3(0.30, 0.0, 0.08))
	for i in 4:
		var y := -0.074 - i * 0.029
		_limb(Vector3(0.052, y, 0.100), Vector3(0.004, y - 0.008, 0.030), 0.0125, 0.0115, glove, 6)
	# 拇指：从掌根往上、往内扣
	_limb(Vector3(0.054, -0.068, 0.048), Vector3(0.012, -0.052, 0.086), 0.0155, 0.0135, glove, 6)


### 左手：掌在护木下方，四指绕过护木底部翻到右侧
func _hand_guard(glove: Material, pad: Material) -> void:
	# ★ 第一人称看自己的左手，看到的是**手背**：掌心朝上贴着护木，
	#   手背朝相机，四指从护木左侧绕下去。
	#   把掌心摆在护木正下方（我上一版的做法），从相机看就只剩一个方块。
	# 手托在护木下方。这个位置从相机看会被护木挡住一部分 ——
	# 我试过把手挪到护木前端（C-clamp）、挪到右侧、抬到上方，
	# 结果不是穿模就是挡住准心。当前这个位置是"不穿模、不出戏"的最优解：
	# 画面上能读出"有只手在托枪"，但读不出手指的细节。
	_box(Vector3(0.070, 0.046, 0.090), Vector3(0.024, -0.064, -0.294), glove, Vector3(0.10, 0.0, 0.06))
	# 手背护片：明暗分界全靠它，否则纯深色的手在阴影里就是一团黑
	_box(Vector3(0.056, 0.012, 0.070), Vector3(0.025, -0.040, -0.294), pad, Vector3(0.10, 0.0, 0.06))
	for i in 4:
		var z := -0.260 - i * 0.030
		# 指根在手背右缘，四指绕过护木下方翻到左侧
		_limb(Vector3(0.052, -0.070, z), Vector3(-0.030, -0.044, z + 0.004), 0.0145, 0.0130, glove, 6)
	# 拇指：从手背右上往护木上方扣
	_limb(Vector3(0.048, -0.046, -0.248), Vector3(0.014, -0.010, -0.262), 0.0160, 0.0140, glove, 6)


### 在 a、b 两点之间放一根（可锥形的）圆柱。
##
## 为什么不用 `look_at`：`look_at` 要求节点已经在树里，而且会把节点的
## 整个朝向重置，对"一根肢体"来说太重了。直接算一个 Basis 更干净：
##   局部 +Y 轴 = 从 a 指向 b 的单位向量（因为 CylinderMesh 沿 Y 生长）
##   另外两个轴随便取一组和它正交的，只要保证 x × y = z（右手系，否则会被镜像）
func _limb(a: Vector3, b: Vector3, r_a: float, r_b: float, mat: Material, segs := 8) -> void:
	var dir := b - a
	var length := dir.length()
	if length < 0.001:
		return
	var y_axis := dir / length
	# 参考向量不能和 y_axis 平行，否则叉积为零
	var ref := Vector3.FORWARD if absf(y_axis.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x_axis := y_axis.cross(ref).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()

	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = r_b        # +Y 端是 b
	m.bottom_radius = r_a     # -Y 端是 a
	m.height = length
	m.radial_segments = segs
	m.rings = 2
	mi.mesh = m
	mi.material_override = mat
	mi.transform = Transform3D(Basis(x_axis, y_axis, z_axis), (a + b) * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_meshes.append(mi)


### 程序化表面纹理：返回一张灰度贴图，与 albedo_color 相乘。
##
## 为什么不用一张"金属贴图"：我们没有美术资源，但"纯色"才是廉价感的来源。
## 只要让明暗有 1/f 噪声的起伏（脏、磨、油），大脑就会读成"真实材质"。
##
## 两个实现细节值得记住：
##  ① 用 NoiseTexture2D 而不是自己 for 循环写像素 —— 它**异步**在后台线程生成，
##     主线程几乎零成本。我第一版手写 128×128 循环，光这一项就让出生卡了半秒。
##  ② color_ramp 把噪声从 0..1 压到 (1-contrast)..1 区间。
##     直接用 0..1 的灰度相乘，表面会出现纯黑的斑，看起来像发霉而不是磨损。
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
	m.albedo_color = base      # 与 albedo_texture 相乘
	m.albedo_texture = tex
	m.metallic = metallic
	m.roughness = roughness
	# ★ 这个值不能留默认的 0.5。
	#   布料/皮革的镜面反射很弱，但默认值会让它们反射天空环境，
	#   结果是一个 albedo 设成纯黑的袖子，在画面上显示成**浅灰色**——
	#   我为此绕了好几轮：改颜色没反应、改纯黑还是灰，最后查像素才发现
	#   亮的是环境反射，不是漫反射。
	m.metallic_specular = specular
	return m


func _muzzle(pos: Vector3) -> void:
	muzzle = Node3D.new()
	muzzle.position = pos
	add_child(muzzle)


func _make_flash() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.13, 0.13)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# ★ 关键：没有这张径向贴图，火光就是一块硬边黄方块
	mat.albedo_texture = FxTex.radial()
	mat.albedo_color = Color(1.0, 0.88, 0.58, 1.0)
	mat.disable_receive_shadows = true
	quad.material = mat
	mi.mesh = quad
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if muzzle != null:
		mi.position = muzzle.position
	return mi


# ------------------------------------------------------------
# 外部事件
# ------------------------------------------------------------
### 开火：往后顶 + 上跳 + 火光
## strength 来自 WeaponDef 的 muzzle_flash / 后坐力，霰弹枪明显更猛
func kick(strength := 1.0) -> void:
	_kick_z = 0.030 * strength
	_kick_rot = 0.055 * strength
	_flash_t = 0.055
	if _flash != null:
		_flash.visible = true
		_flash.rotation.z = randf_range(0.0, TAU)
		var s := randf_range(0.75, 1.25) * (0.8 + 0.35 * strength)
		_flash.scale = Vector3(s, s, s)
	if _flash_light != null:
		_flash_light.light_energy = 4.0 * strength


### 枪被收起：从当前姿态连续压到画面下方。
## 不在开始时重置 reload 姿态，是修复"换弹中途切刀会先弹回普通持枪"的关键。
func play_holster(duration := 0.30) -> void:
	_begin_transition("holster", duration, position, rotation)


### 切回 AK：从画面下方抬起，拉动拉机柄再复位。
## duration 与 Combat 的主武器 DRAW 阶段保持一致，期间由 Combat 锁住开火。
func play_equip(duration := 0.55) -> void:
	_begin_transition("equip", duration, EQUIP_LOW_POS, EQUIP_LOW_ROT)
	_bolt_racked_sent = false


### 切枪被取消：从当前姿态平滑回到正常持枪。
func cancel_transition() -> void:
	if _transition == "idle" or _transition == "stowed":
		return
	_begin_transition("return", 0.14, position, rotation)


func is_holstering() -> bool:
	return _transition == "holster"


func is_equipping() -> bool:
	return _transition == "equip"


func is_busy() -> bool:
	return (_transition == "holster"
		or _transition == "equip"
		or _transition == "return")


func _begin_transition(state: String, duration: float, from_pos: Vector3,
		from_rot: Vector3) -> void:
	_transition = state
	_transition_t = 0.0
	_transition_duration = maxf(0.01, duration)
	_transition_from_pos = from_pos
	_transition_from_rot = from_rot
	if _bolt_handle != null and state != "equip":
		_bolt_handle.position = _bolt_rest_pos


### 鼠标移动时调用：枪会"跟不上"你的转身，产生重量感
func add_sway(rel: Vector2) -> void:
	_sway_target.x = clampf(-rel.x * 0.00035, -0.02, 0.02)
	_sway_target.y = clampf(-rel.y * 0.00035, -0.02, 0.02)
	_sway += (_sway_target - _sway) * 0.35
	_sway_target = Vector2.ZERO


# ------------------------------------------------------------
# 每帧动画
# ------------------------------------------------------------
func _process(delta: float) -> void:
	# 后坐力回落：用 move_toward 而不是乘法衰减，
	# 因为乘法在 144Hz 和 60Hz 下速度不一样（帧率依赖），手感会飘
	_kick_z = move_toward(_kick_z, 0.0, delta * 0.55)
	_kick_rot = move_toward(_kick_rot, 0.0, delta * 6.5)

	# 转身滞后：慢慢追上原位
	_sway = _sway.lerp(Vector2.ZERO, clampf(delta * 9.0, 0.0, 1.0))

	# 走路晃动：速度越快幅度越大，在空中不晃
	var bob := Vector3.ZERO
	if on_floor and move_speed > 0.4:
		_bob_t += delta * (6.0 + move_speed * 0.9)
		var amp: float = clampf(move_speed / 8.5, 0.0, 1.0) * 0.016
		bob.x = sin(_bob_t) * amp
		bob.y = absf(cos(_bob_t)) * amp * 0.8
	else:
		_bob_t = lerp(_bob_t, 0.0, delta * 4.0)

	if _transition == "stowed":
		position = HOLSTER_POS
		rotation = HOLSTER_ROT
	elif _transition != "idle":
		_process_transition(delta)
	else:
		# 换弹：枪往下压并侧转，按进度给出"塞弹匣"的顿挫
		var reload_off := 0.0
		var reload_rot := 0.0
		if reloading:
			_reload_t = lerp(_reload_t, 1.0, delta * 8.0)
			var p := sin(reload_ratio * PI)      # 0→1→0，中途最深
			reload_off = -0.10 * p
			reload_rot = 0.55 * p
		else:
			_reload_t = lerp(_reload_t, 0.0, delta * 8.0)

		position = BASE_POS + Vector3(
			_sway.x,
			_sway.y + bob.y + reload_off - _kick_z * 0.25,
			_kick_z) + bob
		rotation = BASE_ROT + Vector3(
			-_kick_rot,
			_sway.x * 1.2,
			reload_rot + _sway.x * 0.6)
		if _bolt_handle != null:
			_bolt_handle.position = _bolt_rest_pos

	# 枪口火光衰减
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			if _flash != null:
				_flash.visible = false
	if _flash_light != null and _flash_light.light_energy > 0.0:
		_flash_light.light_energy = maxf(0.0, _flash_light.light_energy - delta * 90.0)


func _process_transition(delta: float) -> void:
	_transition_t += delta
	var p := clampf(_transition_t / _transition_duration, 0.0, 1.0)

	match _transition:
		"holster":
			var e := p * p
			position = _transition_from_pos.lerp(HOLSTER_POS, e)
			rotation = _transition_from_rot.lerp(HOLSTER_ROT, e)
			if p >= 1.0:
				_transition = "stowed"
		"equip":
			var rise := smoothstep(0.0, 0.58, p)
			position = EQUIP_LOW_POS.lerp(BASE_POS, rise)
			rotation = EQUIP_LOW_ROT.lerp(BASE_ROT, rise)

			# 拉栓节奏：先向后拉机柄，短暂停住，再让它弹回最前方。
			var bolt := 0.0
			if p >= 0.54 and p < 0.74:
				bolt = smoothstep(0.54, 0.74, p)
			elif p >= 0.74 and p < 0.90:
				bolt = 1.0 - smoothstep(0.74, 0.90, p)
			position += Vector3(0.0, 0.012 * bolt, 0.010 * bolt)
			rotation += Vector3(0.12 * bolt, -0.08 * bolt, 0.10 * bolt)
			if _bolt_handle != null:
				_bolt_handle.position = _bolt_rest_pos + Vector3(
					0.004 * bolt, 0.0, BOLT_PULL_DISTANCE * bolt)

			if p >= 0.86 and not _bolt_racked_sent:
				_bolt_racked_sent = true
				bolt_racked.emit()
			if p >= 1.0:
				_transition = "idle"
				position = BASE_POS
				rotation = BASE_ROT
				if _bolt_handle != null:
					_bolt_handle.position = _bolt_rest_pos
		"return":
			var e := smoothstep(0.0, 1.0, p)
			position = _transition_from_pos.lerp(BASE_POS, e)
			rotation = _transition_from_rot.lerp(BASE_ROT, e)
			if p >= 1.0:
				_transition = "idle"
				position = BASE_POS
				rotation = BASE_ROT


### 枪口的世界坐标（曳光起点）。没有 muzzle 节点时退回本节点位置
func muzzle_position() -> Vector3:
	if muzzle != null:
		return muzzle.global_position
	return global_position
