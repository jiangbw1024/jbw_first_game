extends StaticBody3D
## S6 · 一块建筑（地基 / 墙）
##
## 这个脚本刻意只做一件事：**按类型搭出自己的形状和碰撞体**。
##
## 它不知道：
##   - 自己站在哪（位置由 Build 管理器设置）
##   - 网格多大（GRID 只在 build.gd 里定义一次）
##   - 是谁放的、什么时候放的
##
## 为什么这样切？因为"棋子该长什么样"和"棋子该放哪里"是两个会分别变化的知识。
## 把网格尺寸复制到这里一份，将来改 GRID 就会出现"地基之间有条缝"这种鬼 bug ——
## 和 S5 讲的 SSOT 是同一件事：同一个知识只写一次。

const FOUNDATION_SIZE := Vector3(2.0, 0.4, 2.0)
const WALL_SIZE := Vector3(2.0, 2.4, 0.24)

var kind := "foundation"


### 由管理器调用：搭出视觉与碰撞。base 位置由外部设置，这里只管形状。
func setup(k: String, yaw_deg: int) -> void:
	kind = k
	rotation.y = deg_to_rad(float(yaw_deg))

	var size := _size_for(k)
	# 视觉与碰撞来自同一份 size —— 同源纪律，和 S5 的地形完全一致
	var mesh := BoxMesh.new()
	mesh.size = size

	var material := StandardMaterial3D.new()
	material.albedo_color = _color_for(k)
	material.roughness = 0.9
	material.metallic = 0.0

	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = mesh
	visual.material_override = material
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


### 本地尺寸表。管理器要用它来摆幽灵预览，所以是 public
static func size_of(k: String) -> Vector3:
	return WALL_SIZE if k == "wall" else FOUNDATION_SIZE


func _size_for(k: String) -> Vector3:
	return size_of(k)


func _color_for(k: String) -> Color:
	if k == "wall":
		return Color(0.66, 0.56, 0.42)   # 木板
	return Color(0.46, 0.37, 0.28)       # 木地基
