class_name TownBuilder
extends Node3D
## 把 TownPlan（纯数据）变成节点树
##
## 它只做三件事：填基座参数、实例化建筑、对外回答三个问题
## （这里禁不禁建 / 该在哪出生 / 商店 NPC 在哪）。
##
## 为什么"选址/布局"和"实例化"要分成两个类？
##   因为二者的验证方式完全不同：布局要在 headless 里跑两次做 diff（纯数据），
##   实例化要检查碰撞数量、门能否走进去（要有节点）。
##   混在一起就只能靠"看一眼"，而看一眼恰恰是最不可靠的验收方式。

var plans: Array[TownPlan] = []
var buildings: Array[TownBuilding] = []

const SHOP_NPC_SCENE := preload("res://scenes/shop_npc.tscn")

var _mat_normal: StandardMaterial3D
var _mat_shop: StandardMaterial3D


func generate(terrain: TerrainBase, seed_value: int = TownGenerator.TOWN_SEED) -> void:
	_mat_normal = _make_material(Color(0.62, 0.63, 0.66))
	_mat_shop = _make_material(Color(0.74, 0.64, 0.46))

	plans = TownGenerator.generate(terrain, seed_value)

	for plan in plans:
		var root := Node3D.new()
		root.name = "Town%d" % plan.id
		add_child(root)

		for i in plan.buildings.size():
			var spec := plan.buildings[i]
			_fill_ground(terrain, spec)
			# 商店 NPC 站的是"一楼地面"，而一楼地面是基座顶面 ——
			# 生成器算这个点时还不知道 plinth_top（那要先采样地形），所以在这里补
			if spec.is_shop:
				plan.shop_position.y = spec.plinth_top
			var b := TownBuilding.new()
			b.name = "Bldg%d" % i
			root.add_child(b)
			b.build(spec, _mat_shop if spec.is_shop else _mat_normal)
			buildings.append(b)

	_spawn_shop_npc()
	print("[S8] 城镇就位：%s | 建筑 %d 栋" % [
		"、".join(plans.map(func(p): return p.describe())), buildings.size()])


# ------------------------------------------------------------
# 基座：交给 BuildingSite 算（和选址打分共用同一份算法）
# ------------------------------------------------------------
func _fill_ground(terrain: TerrainBase, spec: BuildingSpec) -> void:
	BuildingSite.apply(terrain, spec)


# ------------------------------------------------------------
# 对外三个问题
# ------------------------------------------------------------
func is_build_blocked(p: Vector3) -> bool:
	for plan in plans:
		if plan.is_blocked(p):
			return true
	return false


### 选出生点：`last` 为 null 表示首次进入 → 主城广场
func pick_spawn(last: Variant) -> Vector3:
	if plans.is_empty():
		return Vector3.ZERO
	var main := plans[0]
	if typeof(last) != TYPE_VECTOR3:
		return main.spawn_points[0] if main.spawn_points.size() > 0 else main.center

	var lp: Vector3 = last
	var best: Vector3 = main.spawn_points[0] if main.spawn_points.size() > 0 else main.center
	var best_d := INF
	for plan in plans:
		for sp in plan.spawns_by_distance(lp):
			if plan.is_inside_building(sp):
				continue
			var d := Vector2(sp.x - lp.x, sp.z - lp.z).length()
			if d < best_d:
				best_d = d
				best = sp
	return best


func main_center() -> Vector3:
	return plans[0].center if plans.size() > 0 else Vector3.ZERO


### 主城第 index 个出生点（轮流分配，避免两个人重叠出生）
func main_spawn(index: int) -> Vector3:
	if plans.is_empty():
		return Vector3.ZERO
	var main := plans[0]
	if main.spawn_points.is_empty():
		return main.center
	return main.spawn_points[index % main.spawn_points.size()]


### 商店 NPC 的世界坐标（没有主城时返回主城中心，避免调用方拿到 NaN）
func npc_position() -> Vector3:
	for plan in plans:
		if plan.is_main:
			return plan.shop_position
	return main_center()


func npc_dir() -> int:
	for plan in plans:
		if plan.is_main:
			return plan.shop_dir
	return 0


# ------------------------------------------------------------
# 商店 NPC
# ------------------------------------------------------------
func _spawn_shop_npc() -> void:
	for plan in plans:
		if not plan.is_main:
			continue
		var npc := SHOP_NPC_SCENE.instantiate()
		npc.name = "ShopNpc"
		npc.position = plan.shop_position

		# 面朝门口（玩家的来向）。节点默认朝 -Z，所以角度要取反。
		var dir := Vector3.ZERO
		for spec in plan.buildings:
			if spec.is_shop:
				dir = spec.door_world_normal()
		if dir != Vector3.ZERO:
			npc.rotation.y = atan2(-dir.x, -dir.z)

		add_child(npc)
		print("[S8] 商店 NPC 就位：%s 朝向 %s" % [
			str(plan.shop_position.round()), str(dir)])


func _make_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	return m
