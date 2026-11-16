extends TerrainBase
## S5 · 高度图地形（手搓版）
##
## 注意第一行：它不再是"一个独立的地形"，而是 TerrainBase 的一个**实现**。
## 手搓版的价值在于：160 行代码里没有任何魔法，你能看见每一块拼图。
## 它的上限也很清楚 —— 单块、无 LOD、改不成 2 公里。
##
## 高度图的本质只有一句话：
##   **一张二维表格，每格存一个数字 = 那一点的地面高度。**
## 剩下的全是从这张表衍生出来的：
##   视觉网格  ← 把表"拉"成曲面
##   碰撞体    ← 把同一张表交给物理引擎
##   出生点    ← 在表上插值取高度
##
## ★ 最重要的一条纪律：视觉和碰撞必须来自**同一份 _heights**。
##   如果网格用 noise 采一次、碰撞又用 noise 采一次，
##   只要两次的采样位置差一点点，就会出现"人半只脚陷进地里"这种灵异现象。
##   这类 bug 极难排查，因为两边的代码看起来都没错。

const SIZE := 160.0        # 地形边长（米）
const STEP := 1.0          # 顶点间距（米）—— 必须为 1，见 _build_collision 的说明
const AMPLITUDE := 16.0    # 起伏幅度（米）
const SEED := 20261111     # 固定种子：所有客户端必须生成同一份地形

@onready var body: StaticBody3D = $Body
@onready var collision: CollisionShape3D = $Body/Collision
@onready var visual: MeshInstance3D = $Visual

var _n := 0                              # 每边顶点数
var _heights := PackedFloat32Array()     # 唯一的事实来源
var _noise := FastNoiseLite.new()


func _ready() -> void:
	_n = int(SIZE / STEP) + 1
	_setup_noise()
	_sample_heights()
	_build_mesh()
	_build_collision()
	print("[S5] 地形生成完毕 | %d×%d 顶点 | 最高 %.1f m" % [_n, _n, _max_height()])


func _setup_noise() -> void:
	_noise.seed = SEED
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.006
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.fractal_gain = 0.5


# ------------------------------------------------------------
# 1. 生成高度数据
# ------------------------------------------------------------
func _sample_heights() -> void:
	_heights.resize(_n * _n)
	for j in _n:
		for i in _n:
			var x := -SIZE * 0.5 + float(i) * STEP
			var z := -SIZE * 0.5 + float(j) * STEP
			var base := _noise.get_noise_2d(x, z) * AMPLITUDE
			# 岛屿衰减：越靠边越低，四周沉入水面，看起来才像一座岛而不是一块被切开的饼
			var d := Vector2(x, z).length() / (SIZE * 0.5)
			var falloff := clampf(1.0 - d * d, 0.0, 1.0)
			_heights[j * _n + i] = base * falloff + 1.0


### 对外接口：查询任意位置的地面高度（出生点、放建筑、AI 寻路都要用）
func height_at(x: float, z: float) -> float:
	var fi := (x + SIZE * 0.5) / STEP
	var fj := (z + SIZE * 0.5) / STEP
	var i := clampi(int(floor(fi)), 0, _n - 2)
	var j := clampi(int(floor(fj)), 0, _n - 2)
	var tx := clampf(fi - float(i), 0.0, 1.0)
	var tz := clampf(fj - float(j), 0.0, 1.0)
	var h00 := _heights[j * _n + i]
	var h10 := _heights[j * _n + i + 1]
	var h01 := _heights[(j + 1) * _n + i]
	var h11 := _heights[(j + 1) * _n + i + 1]
	# 双线性插值：格子内的高度是平滑过渡的，不是台阶
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


# ------------------------------------------------------------
# 2. 把高度表变成网格
# ------------------------------------------------------------
func _build_mesh() -> void:
	var count := _n * _n
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	colors.resize(count)

	for j in _n:
		for i in _n:
			var idx := j * _n + i
			var x := -SIZE * 0.5 + float(i) * STEP
			var z := -SIZE * 0.5 + float(j) * STEP
			var h := _heights[idx]
			verts[idx] = Vector3(x, h, z)
			uvs[idx] = Vector2(float(i) / float(_n - 1), float(j) / float(_n - 1))
			colors[idx] = _color_for(h)
			normals[idx] = _normal_at(i, j)

	# 每个格子两个三角形。
	# 绕序（a→c→b）决定法线朝上；朝下的绕序会让地面从上方"看不见"（背面剔除）。
	for j in _n - 1:
		for i in _n - 1:
			var a := j * _n + i
			var b := j * _n + i + 1
			var c := (j + 1) * _n + i
			var d := (j + 1) * _n + i + 1
			indices.append_array([a, c, b, b, c, d])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	# 用顶点色上色：草绿 / 岩石灰 / 雪白，零贴图也能看出地貌
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	# 关掉背面剔除：地形是开放曲面，双面渲染更安全，
	# 代价是一点点填充率，换来"永远不会因为绕序写错而整片看不见"
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	visual.mesh = mesh
	visual.material_override = material


### 用中心差分算法线：比 SurfaceTool.generate_normals 快，且结果可控
func _normal_at(i: int, j: int) -> Vector3:
	var hl := _heights[j * _n + maxi(i - 1, 0)]
	var hr := _heights[j * _n + mini(i + 1, _n - 1)]
	var hd := _heights[maxi(j - 1, 0) * _n + i]
	var hu := _heights[mini(j + 1, _n - 1) * _n + i]
	var dx := (hr - hl) / (2.0 * STEP)
	var dz := (hu - hd) / (2.0 * STEP)
	return Vector3(-dx, 1.0, -dz).normalized()


func _color_for(h: float) -> Color:
	var grass := Color(0.33, 0.45, 0.26)
	if h < 3.0:
		# 沙滩 → 草地
		return Color(0.74, 0.69, 0.50).lerp(grass, clampf(h / 3.0, 0.0, 1.0))
	if h < 10.0:
		return grass
	if h < 13.5:
		# 草地 → 岩石
		return grass.lerp(Color(0.52, 0.50, 0.47), clampf((h - 10.0) / 3.5, 0.0, 1.0))
	# 岩石 → 雪
	return Color(0.52, 0.50, 0.47).lerp(Color(0.92, 0.93, 0.95), clampf((h - 13.5) / 2.0, 0.0, 1.0))


# ------------------------------------------------------------
# 3. 把同一份高度表交给物理引擎
# ------------------------------------------------------------
func _build_collision() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = _n
	shape.map_depth = _n
	shape.map_data = _heights
	# ★ HeightMapShape3D 的相邻采样点间距被硬编码为 1 米，
	#   所以 STEP 必须等于 1，否则碰撞体和视觉就会错位。
	#   想让地形更大，正确做法是"加大顶点数"或"整体缩放"，而不是改 STEP。
	collision.shape = shape


func _max_height() -> float:
	var m := -INF
	for h in _heights:
		m = maxf(m, h)
	return m


# ------------------------------------------------------------
# TerrainBase 契约的实现
# ------------------------------------------------------------
func playable_radius() -> float:
	return SIZE * 0.5 - 4.0


func describe() -> String:
	return "手搓高度图 %d×%d（%.0f 米见方，无 LOD）" % [_n, _n, SIZE]
