class_name TownPlan
extends RefCounted
## 一座城镇的"规划图"：中心、半径、建筑清单、出生点、禁建范围
##
## 同样只有数据。这样"生成"这件事可以在 headless 里跑两次做 diff，
## 而不用先把它变成几百个节点再比对场景树。

var id := 0
var is_main := false
var name := "城镇"
var center := Vector3.ZERO
var radius := 24.0                  ## 广场半径，也是禁建圆的半径

var buildings: Array[BuildingSpec] = []
var spawn_points: Array[Vector3] = []
var shop_position := Vector3.ZERO   ## 只有主城有商店
var shop_dir := 0


### 这个点是否禁止建造
##
### 两段判断：广场圆 + 每栋楼的外接矩形（已含 2 米外扩）。
### 用矩形而不是旋转矩形，是因为 BuildingSpec 只允许 0/90 度朝向 ——
### 生成规则上少一个自由度，判断代码就少一整段三角函数。
func is_blocked(p: Vector3) -> bool:
	if Vector2(p.x - center.x, p.z - center.z).length() <= radius:
		return true
	return is_inside_building(p)


### 只判断"是不是压在楼上"，不管广场
##
### 为什么要把这一条单独拿出来？
### 出生点本来就设计在广场里，而广场是禁建区 ——
### 如果选出生点时用 `is_blocked()` 筛选，会把所有出生点都排除掉，
### 表现是"永远只出生在第一个点"（本次实测踩到）。
func is_inside_building(p: Vector3) -> bool:
	for b in buildings:
		var half := b.footprint_half()
		if absf(p.x - b.center.x) <= half.x and absf(p.z - b.center.z) <= half.y:
			return true
	return false


### 按到某点的水平距离排序的出生点（最近的在前）
func spawns_by_distance(p: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	out.assign(spawn_points)
	out.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return Vector2(a.x - p.x, a.z - p.z).length_squared() \
			< Vector2(b.x - p.x, b.z - p.z).length_squared())
	return out


func describe() -> String:
	return "%s(%.0f,%.0f) r=%.0f 建筑%d 出生点%d" % [
		name, center.x, center.z, radius, buildings.size(), spawn_points.size()]
