extends StaticBody3D
## S6/S12 · 一块建筑（地基 / 墙 / 门框）
##
## 这个脚本刻意只做一件事：**按类型搭出自己的形状和碰撞体**。
##
## 它不知道：
##   - 自己站在哪（位置由 Build 管理器设置）
##   - 网格多大（GRID 只在 build.gd 里定义一次）
##   - 是谁放的、花了多少材料
##
## 为什么这样切？因为"棋子该长什么样"和"棋子该放哪里"是两个会分别变化的知识。
## 把网格尺寸复制到这里一份，将来改 GRID 就会出现"地基之间有条缝"这种鬼 bug ——
## 和 S5 讲的 SSOT 是同一件事：同一个知识只写一次。

const FOUNDATION_SIZE := Vector3(2.0, 0.4, 2.0)
const WALL_SIZE := Vector3(2.0, 2.4, 0.24)

## 门洞的净空：宽 1.64、高 1.90。玩家胶囊半径 0.4，走中间还剩 0.42 余量；
## 1.90 比身高 1.8 高一点点 —— 贴着门框跑过去不会"卡一下头"
const DOOR_OPEN_W := 1.64
const DOOR_OPEN_H := 1.90
const DOOR_POST_W := (WALL_SIZE.x - DOOR_OPEN_W) * 0.5   # (2.0-1.64)/2 = 0.18

var kind := "foundation"


### 由管理器调用：搭出视觉与碰撞。base 位置由外部设置，这里只管形状。
func setup(k: String, yaw_deg: int) -> void:
	kind = k
	rotation.y = deg_to_rad(float(yaw_deg))
	if k == "door":
		_build_door()
	else:
		_build_box(_size_for(k), _color_for(k))


### 整块的件：一块盒子，视觉与碰撞同源
func _build_box(size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size

	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = mesh
	visual.material_override = _mat(color)
	# 形状以"底面"为原点：这样管理器把 y 设成地面高度就正好坐在地上，
	# 不用每处都记得减半个高度
	visual.position.y = size.y * 0.5
	add_child(visual)

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = shape
	collision.position.y = size.y * 0.5
	add_child(collision)


### 门框：两立柱 + 上横梁，中间是空的。
##
## ★ 为什么不做"能开合的门板"：
##   开合需要一块会动的碰撞体（AnimatableBody3D）+ 铰链支点 + 状态同步，
##   而且"门开着时丧尸能不能进来"会牵进 AI 寻路 —— 那是一个独立的系统。
##   这一轮的目标是让基地"能用"（能进出、能挡视线），
##   所以先给一个固定的门洞。门板本身值得单独一轮，配开关音效和撞击反馈。
func _build_door() -> void:
	var wood := _mat(Color(0.58, 0.46, 0.33))
	var steel := _mat(Color(0.34, 0.35, 0.36))

	# 左右立柱：从 0 到 2.4
	for sx in [-1.0, 1.0]:
		var post_x: float = sx * (DOOR_OPEN_W * 0.5 + DOOR_POST_W * 0.5)
		_limb_box(
			Vector3(DOOR_POST_W, WALL_SIZE.y, WALL_SIZE.z),
			Vector3(post_x, WALL_SIZE.y * 0.5, 0.0), wood)

	# 上横梁：从 DOOR_OPEN_H 到 2.4
	var beam_h: float = WALL_SIZE.y - DOOR_OPEN_H
	_limb_box(
		Vector3(WALL_SIZE.x, beam_h, WALL_SIZE.z),
		Vector3(0.0, DOOR_OPEN_H + beam_h * 0.5, 0.0), wood)

	# 门槛下的一条金属压边：视觉上把门框和地基分开，
	# 也让"这里可以过去"更明显（人眼靠边界判断通道）
	_limb_box(
		Vector3(DOOR_OPEN_W, 0.06, WALL_SIZE.z * 1.1),
		Vector3(0.0, 0.03, 0.0), steel)


### 一块带视觉 + 碰撞的子盒（只用于拼装，不重复建材质）
func _limb_box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = mat
	visual.position = pos
	add_child(visual)

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = pos
	add_child(collision)


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	m.metallic = 0.0
	return m


### 本地尺寸表。管理器要用它来摆幽灵预览和算"顶上能叠多高"，所以是 public。
##
## ★ 门框必须返回**和墙一样的整块尺寸**，不能返回"实际镂空后的外框"：
##   管理器用 size.y 算这一层的 top，下一层就叠在这个 top 上。
##   如果门框报一个更小的 y，二层地板就会比墙矮一截，出现台阶状的缝。
static func size_of(k: String) -> Vector3:
	if k == "wall" or k == "door":
		return WALL_SIZE
	return FOUNDATION_SIZE


func _size_for(k: String) -> Vector3:
	return size_of(k)


func _color_for(k: String) -> Color:
	if k == "wall":
		return Color(0.66, 0.56, 0.42)   # 木板
	return Color(0.46, 0.37, 0.28)       # 木地基
