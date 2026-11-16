class_name TownBuilding
extends StaticBody3D
## 一栋可进入的多层建筑（灰盒：全靠盒子拼，零外部素材）
##
## 三个关键取舍：
##
## **① 视觉合并成一个 ArrayMesh，碰撞保留 N 个 BoxShape3D**
##   一栋楼约 90-120 个盒子。每个盒子建一个 MeshInstance3D 就是上百个 draw call；
##   合并后是 1 个。但碰撞不能合并 —— 引擎只认一个个独立形状，
##   而 BoxShape3D 是最省的形状（别用 ConvexPolygonShape3D，那种要跑凸包）。
##
## **② 楼梯用"斜坡碰撞 + 斜坡视觉"，不做台阶**
##   CharacterBody3D 没有自动上台阶能力，0.2 米的竖直台阶对它就是一道墙。
##   所以碰撞必须是一块 33° 的斜坡（小于默认 floor_max_angle 45°）。
##   灰盒阶段直接把斜坡当楼梯看，等有美术再换成"视觉台阶 + 隐形斜坡"。
##
## **③ 基座是"填平坡地"而不是"修改地形"**
##   楼底从 footprint 最低点再往下 0.8 米开始，一直浇到最高点 +0.2 米，
##   于是坡地被一坨混凝土包住。绝不写 Terrain3D 的高度图 ——
##   那会引出"地形要不要联机同步"这个地狱级问题。

const WALL_T := 0.24         # 墙厚
const SLAB_T := 0.25         # 楼板厚
const STAIR_W := 1.6         # 楼梯宽
const STAIR_RUN := 4.4       # 楼梯水平长度（对应 3.2 米层高 → 36°）
const DOOR_W := 1.4
const DOOR_H := 2.4          # 原来 2.2，跳起来会撞门楣；2.4 走进去不磕头
const WIN_SILL := 1.0        # 窗台高
const WIN_TOP := 2.2         # 窗顶高

# ---- 门廊（平台 + 台阶 + 雨棚）----
# 这几个数是"进门体验"的全部来源。灰盒楼的四面长得一模一样，
# 没有平台、台阶、雨棚这三样，玩家在楼下只会看到一堵墙。
const PORCH_DEPTH := BuildingSite.PORCH_DEPTH   # 平台往墙外伸多深（和选址打分共用）
const PORCH_WING := 1.3      # 平台比门洞每边再宽多少
const STEP_RISE := 0.15      # 目标踏步高（越小越像楼梯，但级数变多、坡道变长）
const STEP_RUN := 0.30       # 踏步进深
const MAX_STEPS := 10
const RAMP_T := 0.18         # 隐形坡道厚度
const CANOPY_H := 2.8        # 雨棚离平台面的高度
const PORCH_SLOPE := BuildingSite.PORCH_SLOPE   # 台阶坡度（0.5 ≈ 26.6°）
const RAMP_TAIL := 0.8       # 隐形坡道比可见台阶多伸出的长度（末端扎进土里）

var spec: BuildingSpec

var _st := SurfaceTool.new()
var _mat: StandardMaterial3D
var _shapes := 0


func build(s: BuildingSpec, mat: StandardMaterial3D) -> void:
	spec = s
	_mat = mat
	add_to_group("town")

	# 节点放在楼心、y=0：这样局部坐标的 y 就等于世界高度，写起来最直观
	position = Vector3(s.center.x, 0.0, s.center.z)
	rotation.y = deg_to_rad(float(s.yaw_deg))

	_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var w := s.size.x
	var d := s.size.y
	var top := s.plinth_top

	# 基座
	var bottom := s.ground_min
	_add_box(Vector3(0.0, (bottom + top) * 0.5, 0.0),
		Vector3(w, top - bottom, d), 0.0, true)

	# 门廊：平台 + 台阶 + 雨棚。**没有它就只能跳着进门** —— 见 _porch 里的说明
	_porch(top, w, d)

	# 各层：楼板 + 四面墙（第 1 层起，楼板留楼梯洞）
	for f in s.floors:
		var y0 := top + float(f) * s.floor_h
		_slab(y0, w, d, f > 0)
		_walls(y0, w, d, f)
		if f > 0:
			_ramp(top + float(f - 1) * s.floor_h, s.floor_h, w)

	# 屋顶 + 女儿墙
	var roof_y := top + float(s.floors) * s.floor_h
	_slab(roof_y, w, d, false)
	_parapet(roof_y, w, d)

	_flush()


# ------------------------------------------------------------
# 门廊：平台 + 台阶 + 雨棚
# ------------------------------------------------------------
### 为什么必须要有这一段（真实反馈：NPC 那栋楼得跳着才能进去）
##
### 楼里的地面是 `plinth_top`，而它是"footprint 最高点 + 0.2"。
### 坡地上这个面可能比门外地面高出 1 米多，于是门口就是一堵 1 米高的混凝土坎 ——
### `CharacterBody3D` 没有自动上台阶能力，0.2 米的坎都上不去，只能跳。
##
### 三件东西各自解决一个问题：
###   ① 平台：让墙外也有落脚的地面（否则你只能站在土坡上"抠"门）
###   ② 台阶：把那一米多的落差变成一级级 0.15 米的踏步（走上去，不用跳）
###   ③ 雨棚：灰盒楼四面一模一样，没有雨棚根本看不出哪面是门
func _porch(top: float, w: float, d: float) -> void:
	var n := spec.door_normal()                                  # 局部、轴对齐
	var half := spec.size * 0.5
	var face: float = absf(n.x) * half.x + absf(n.z) * half.y     # 楼心 → 墙外表面
	var span: float = d if absf(n.z) > 0.5 else w
	var door_w: float = span / 3.0                               # 门洞 = 这面墙的中间三分之一
	var pw := door_w + PORCH_WING * 2.0                          # 平台比门洞两侧各宽一点
	var lateral := Vector3(n.z, 0.0, -n.x)                       # 与门方向垂直的水平轴

	# ① 平台：把楼板"伸"到墙外。深度由 BuildingSite 按地面算（能埋掉门口的土包），
	#    底面一直落到地面以下，避免悬空一块板
	var depth: float = maxf(spec.porch_depth, 0.6)
	var bottom := minf(spec.ground_min, spec.porch_ground - 0.5)
	_porch_box(n, lateral, face + depth * 0.5, bottom, top, pw, depth)

	# ② 台阶：从平台外沿一级级降到门外地面
	#   长度和落差都是 TownBuilder 沿地面探出来的（spec.porch_reach / porch_ground），
	#   这里只负责"均匀分成 N 级"。
	var reach: float = maxf(spec.porch_reach, 0.2)
	var drop: float = top - spec.porch_ground
	var count := clampi(int(ceil(drop / STEP_RISE)), 2, MAX_STEPS)
	var rise := drop / float(count)
	var run := reach / float(count)
	for i in count:
		var y_i := top - rise * float(i + 1)
		var dist := face + depth + run * (float(i) + 0.5)
		_porch_box(n, lateral, dist, bottom, y_i, pw, run)

	# ③ 隐形坡道：视觉上是台阶，脚下踩的是一整条连续斜面。
	#    ★ 为什么不是"每一级都垫一块小斜坡"：那样每块斜坡的两端都会和踏步面差半级，
	#      而 CharacterBody3D 连 0.1 米的竖直错台都会当成墙。一整条穿过所有踏步**前缘**
	#      的斜面，才能保证从下往上走时脚下永远连续。
	#      代价：站在踏步后半段时脚会"浮"起最多 rise（0.15 米）—— 灰盒阶段可接受。
	var total_run := reach + RAMP_TAIL
	var total_drop := drop + PORCH_SLOPE * RAMP_TAIL
	_porch_ramp(n, Vector3(n.x * (face + depth + total_run * 0.5), top - total_drop * 0.5,
			n.z * (face + depth + total_run * 0.5)),
		pw, total_run, total_drop)

	# ④ 雨棚（纯视觉，不加碰撞：加了会在跳起来时撞头）
	var cw := pw * 0.8
	var cd := minf(depth * 0.9, 2.4)
	_porch_box(n, lateral, face + cd * 0.5, top + CANOPY_H, top + CANOPY_H + 0.2, cw, cd, false)


### 沿门方向摆一个盒子：`dist` 是盒子中心到楼心的距离，沿 `n` 方向
func _porch_box(n: Vector3, lateral: Vector3, dist: float, y0: float, y1: float,
		width: float, depth: float, solid: bool = true) -> void:
	var size := Vector3(
		absf(lateral.x) * width + absf(n.x) * depth,
		maxf(y1 - y0, 0.02),
		absf(lateral.z) * width + absf(n.z) * depth)
	var c := Vector3(n.x * dist, (y0 + y1) * 0.5, n.z * dist)
	_add_box(c, size, 0.0, solid)


### 隐形坡道：只有碰撞、没有视觉。沿 `n` 方向下降 `rise`，水平走 `run`
##
### ★ 基向量不要手推正负号。第一版写的是 `Basis(RIGHT, ±angle)`，
###   结果一边的楼坡道是反的 —— 末端翘出地面 0.4 米，正好在台阶底下形成一堵墙，
###   表现就是"台阶造好了还是上不去"，而且只有一半朝向的楼中招。
###   现在直接用"沿坡向下"的单位向量 `dir` 构造基向量，方向写成什么就是什么。
func _porch_ramp(n: Vector3, top_center: Vector3, width: float, run: float, rise: float) -> void:
	if rise <= 0.005 or run <= 0.005:
		return
	var dir := (n + Vector3.DOWN * (rise / run)).normalized()    # 沿坡向下
	var side := Vector3.UP.cross(dir).normalized()               # 横向（水平）
	var up_v := dir.cross(side).normalized()                     # 坡面的法线
	var length := sqrt(run * run + rise * rise)
	var basis := Basis(side, up_v, dir)
	# 中心要从"坡面中线"往下退半个厚度，这样**上表面**正好落在中线上
	_add_collision_only(top_center - up_v * (RAMP_T * 0.5),
		Vector3(width, RAMP_T, length), basis)


# ------------------------------------------------------------
# 楼板
# ------------------------------------------------------------
### 楼板：顶面正好在 y。`with_hole` 为真时中间留出楼梯洞（4 块盒子拼"回"字）
func _slab(y: float, w: float, d: float, with_hole: bool) -> void:
	var cy := y - SLAB_T * 0.5
	if not with_hole:
		_add_box(Vector3(0.0, cy, 0.0), Vector3(w, SLAB_T, d), 0.0, true)
		return

	var x0 := _stair_x0(w)
	var x1 := x0 + STAIR_W
	var z0 := -STAIR_RUN * 0.5
	var z1 := STAIR_RUN * 0.5

	# 左、右两条
	var lw := x0 + w * 0.5
	if lw > 0.01:
		_add_box(Vector3(-w * 0.5 + lw * 0.5, cy, 0.0), Vector3(lw, SLAB_T, d), 0.0, true)
	var rw := w * 0.5 - x1
	if rw > 0.01:
		_add_box(Vector3(x1 + rw * 0.5, cy, 0.0), Vector3(rw, SLAB_T, d), 0.0, true)
	# 前后两条（只覆盖楼梯洞的宽度）
	var fd := z0 + d * 0.5
	if fd > 0.01:
		_add_box(Vector3((x0 + x1) * 0.5, cy, -d * 0.5 + fd * 0.5),
			Vector3(STAIR_W, SLAB_T, fd), 0.0, true)
	var bd := d * 0.5 - z1
	if bd > 0.01:
		_add_box(Vector3((x0 + x1) * 0.5, cy, z1 + bd * 0.5),
			Vector3(STAIR_W, SLAB_T, bd), 0.0, true)


func _stair_x0(w: float) -> float:
	# ★ 楼梯要躲开门：门在 -X 面时，进门的正前方就是楼梯的中段（1.6 米高）——
	#   玩家一进门就撞上一堵斜墙，看起来就是"这栋楼进不去"。
	#   所以门朝 -X 时把楼梯整个挪到 +X 侧。
	if spec != null and spec.door_dir == 3:
		return w * 0.5 - 0.4 - STAIR_W
	return -w * 0.5 + 0.4


# ------------------------------------------------------------
# 墙：每面切成三格，中间那格开洞（窗 / 首层门）
# ------------------------------------------------------------
func _walls(y0: float, w: float, d: float, floor_idx: int) -> void:
	var t := WALL_T
	var h := spec.floor_h
	var zf := d * 0.5 - t * 0.5
	var xf := w * 0.5 - t * 0.5

	_face_x(y0, w, zf, h, floor_idx == 0 and spec.door_dir == 0, t)
	_face_x(y0, w, -zf, h, floor_idx == 0 and spec.door_dir == 1, t)
	_face_z(y0, d, xf, h, floor_idx == 0 and spec.door_dir == 2, t)
	_face_z(y0, d, -xf, h, floor_idx == 0 and spec.door_dir == 3, t)


### 沿 X 方向延伸的一面墙（法线朝 ±Z）
func _face_x(y0: float, span: float, z: float, h: float, is_door: bool, t: float) -> void:
	var col := span / 3.0
	var half := col * 0.5
	_add_box(Vector3(-span * 0.5 + half, y0 + h * 0.5, z), Vector3(col, h, t), 0.0, true)
	_add_box(Vector3(span * 0.5 - half, y0 + h * 0.5, z), Vector3(col, h, t), 0.0, true)
	_opening(Vector3(0.0, 0.0, z), Vector3(col, 0.0, t), y0, h, is_door)


### 沿 Z 方向延伸的一面墙（法线朝 ±X）
func _face_z(y0: float, span: float, x: float, h: float, is_door: bool, t: float) -> void:
	var col := span / 3.0
	var half := col * 0.5
	_add_box(Vector3(x, y0 + h * 0.5, -span * 0.5 + half), Vector3(t, h, col), 0.0, true)
	_add_box(Vector3(x, y0 + h * 0.5, span * 0.5 - half), Vector3(t, h, col), 0.0, true)
	_opening(Vector3(x, 0.0, 0.0), Vector3(t, 0.0, col), y0, h, is_door)


### 中间那格的上下补墙：门只要门楣，窗要窗台 + 窗楣
func _opening(at: Vector3, dims: Vector3, y0: float, h: float, is_door: bool) -> void:
	if is_door:
		var header := h - DOOR_H
		if header > 0.01:
			_add_box(Vector3(at.x, y0 + DOOR_H + header * 0.5, at.z),
				Vector3(dims.x, header, dims.z), 0.0, true)
		return
	# 窗台
	_add_box(Vector3(at.x, y0 + WIN_SILL * 0.5, at.z),
		Vector3(dims.x, WIN_SILL, dims.z), 0.0, true)
	# 窗楣
	var up := h - WIN_TOP
	if up > 0.01:
		_add_box(Vector3(at.x, y0 + WIN_TOP + up * 0.5, at.z),
			Vector3(dims.x, up, dims.z), 0.0, true)


# ------------------------------------------------------------
# 楼梯：一块斜放的盒子，既当视觉也当碰撞
# ------------------------------------------------------------
func _ramp(y_from: float, h: float, w: float) -> void:
	var length := sqrt(STAIR_RUN * STAIR_RUN + h * h)
	var angle := atan(h / STAIR_RUN)
	var basis := Basis(Vector3.RIGHT, angle)
	var center := Vector3(_stair_x0(w) + STAIR_W * 0.5, y_from + h * 0.5, 0.0)
	_add_box_xform(center, Vector3(STAIR_W, 0.18, length), basis, true)


# ------------------------------------------------------------
# 屋顶
# ------------------------------------------------------------
func _parapet(y: float, w: float, d: float) -> void:
	var h := 0.5
	var t := 0.3
	var cy := y + h * 0.5
	_add_box(Vector3(0.0, cy, d * 0.5 - t * 0.5), Vector3(w, h, t), 0.0, true)
	_add_box(Vector3(0.0, cy, -d * 0.5 + t * 0.5), Vector3(w, h, t), 0.0, true)
	_add_box(Vector3(w * 0.5 - t * 0.5, cy, 0.0), Vector3(t, h, d), 0.0, true)
	_add_box(Vector3(-w * 0.5 + t * 0.5, cy, 0.0), Vector3(t, h, d), 0.0, true)


# ------------------------------------------------------------
# 盒子 → 视觉与碰撞
# ------------------------------------------------------------
func _add_box(center: Vector3, size: Vector3, yaw: float, solid: bool) -> void:
	_add_box_xform(center, size, Basis(Vector3.UP, yaw), solid)


func _add_box_xform(center: Vector3, size: Vector3, basis: Basis, solid: bool) -> void:
	var box := BoxMesh.new()
	box.size = size
	_st.append_from(box, 0, Transform3D(basis, center))

	if solid:
		_add_collision_only(center, size, basis)


### 只要碰撞、不要视觉 —— 隐形坡道用
func _add_collision_only(center: Vector3, size: Vector3, basis: Basis) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = Transform3D(basis, center)
	add_child(cs)
	_shapes += 1


func _flush() -> void:
	var mesh := _st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Visual"
	mi.mesh = mesh
	mi.material_override = _mat
	add_child(mi)


func collision_count() -> int:
	return _shapes
