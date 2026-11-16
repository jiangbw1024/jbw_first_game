class_name BuildingSpec
extends RefCounted
## 一栋楼的"规格书"：只有数据，不含任何节点
##
## 为什么是 RefCounted 而不是 Resource？
##   Resource 面向"磁盘资产 + 编辑器 @export + 被多个地方共享引用"，
##   而我们这份数据是"从种子现算、和场景同生共死"。
##   用 Resource 还得操心 resource_local_to_scene —— 否则两端会共享同一个对象，
##   一边改 yaw 另一边跟着变，属于典型的"越用越玄"的 bug。
##
## 为什么不用 Dictionary？
##   字段固定、被生成器/建筑/禁建判断三处读。拼错 key 只会在运行时炸，
##   而带类型的成员在**解析期**就报错。

## 基座中心（XZ 为世界坐标，y 由 ground_y 单独记录，避免混用）
var center := Vector3.ZERO
var ground_y := 0.0

## 基座顶面高度（由 TownBuilder 采样地形后填入）。
## 楼板、墙、屋顶全部以它为基准往上叠 —— 建筑内部不需要知道地形长什么样。
var plinth_top := 0.0

## 基座底面高度（footprint 最低点再往下 0.8 米），用来把坡地"包"住
var ground_min := 0.0

## 门**外面**的地面高度（台阶落脚处），由 TownBuilder 采样后填入。
##
## 为什么要单独记：楼里的地面是 plinth_top，坡地上它可能比门外高 1 米多。
## 没有这个数就没法知道"门口要几级台阶"—— 而缺台阶正是"非得跳着才能进门"的根因。
var porch_ground := 0.0

## 门廊平台往墙外伸多深。由 BuildingSite 按地面形状算出来 ——
## 门口如果有土包，平台会一路铺过去把它埋掉，让台阶只负责最后那一米。
var porch_depth := 1.9

## 台阶需要多长（水平距离，从平台外沿量起）。
##
## 由 TownBuilder 沿着门外方向**逐段下探**算出来：坡道面第一次沉到土面之下，
## 就是台阶该结束的地方。这样缓坡上是三级小台阶，陡坡上自动变长，
## 而不是一律按"整片地形的最大落差"造一段六米长的大楼梯。
var porch_reach := 1.0

## 宽（X 向）× 深（Z 向），单位米。yaw 为 90 度时两者交换
var size := Vector2(10.0, 8.0)

## 只允许 0 / 90：保持轴对齐，禁建区才能用简单的矩形判断
var yaw_deg := 0

var floors := 2
var floor_h := 3.2          ## 低于 3.0 会卡头（胶囊 1.8 + 楼板 0.25 + 余量）

## 门朝向：0=+Z 1=-Z 2=+X 3=-X
var door_dir := 0

var is_shop := false


### 外接半尺寸（含 2 米外扩），用于禁建区与建筑间距
func footprint_half() -> Vector2:
	var h := size * 0.5 + Vector2(2.0, 2.0)
	if yaw_deg % 180 == 90:
		return Vector2(h.y, h.x)
	return h


### 门朝向对应的**局部**单位方向
##
### 注意是局部坐标：墙是在建筑自己的坐标系里开的洞，整个建筑再绕 Y 转 yaw。
### 第一版这里返回世界方向，结果 yaw=90 的楼门开到了另一面 ——
### 表现是"有的楼门对广场，有的楼门对着墙"，而且只在部分楼上出错。
func door_normal() -> Vector3:
	match door_dir:
		0: return Vector3(0, 0, 1)
		1: return Vector3(0, 0, -1)
		2: return Vector3(1, 0, 0)
		_: return Vector3(-1, 0, 0)


### 把局部方向转到世界
##
### ★ 用 `rotated()` 而不是手写 sin/cos：
###   手写时我把旋转方向搞反了（Godot 的 Basis(UP, +r) 与"逆时针"公式差一个负号），
###   表现是 yaw=90 的楼门开到镜像方向，而 yaw=0 的楼完全正常 —— 一半对一半错最难查。
func door_world_normal() -> Vector3:
	if yaw_deg % 360 == 0:
		return door_normal()
	return door_normal().rotated(Vector3.UP, deg_to_rad(float(yaw_deg)))


### 门外 1 米的**世界**坐标（给自检射线、给商店 NPC 定位）
func door_outside() -> Vector3:
	var n := door_normal()
	var half := size * 0.5
	var out := absf(n.x) * half.x + absf(n.z) * half.y + 1.0
	var local := Vector3(n.x * out, 0.0, n.z * out)
	if yaw_deg % 360 != 0:
		local = local.rotated(Vector3.UP, deg_to_rad(float(yaw_deg)))
	return Vector3(center.x + local.x, ground_y, center.z + local.z)


func describe() -> String:
	return "B%s_%.0fx%.0f_%dF_door%d%s" % [
		str(Vector2i(roundi(center.x), roundi(center.z))),
		size.x, size.y, floors, door_dir, "_SHOP" if is_shop else ""]
