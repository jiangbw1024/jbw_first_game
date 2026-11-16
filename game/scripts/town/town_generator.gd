class_name TownGenerator
extends RefCounted
## 确定性城镇布局生成器（纯静态、纯数据、不建节点）
##
## ★ 联机一致性的唯一要求：**同样的地形 + 同样的种子 → 同样的布局**。
##   所以这里有三条纪律，任何一条破了都会变成"两个人看到的城镇不一样"：
##
##   ① 只用 `rng.seed = TOWN_SEED` 这一个随机源。
##      禁止全局 `randi()/randf()` —— 那个 RNG 的全局状态在两端不同步。
##   ② 不含 `await`、不含 `if multiplayer.is_server()`。
##      异步会让生成时机不同；端判断会让两端走不同分支。
##   ③ 布局只依赖 `terrain.height_at()`（两端同种子同参数，逐位相同）。
##
##   验收方式很硬：同一份代码跑两次，把 `digest()` 打印出来做 diff，必须为空。

## 城镇种子 —— 与地形 SEED（terrain3d_world.gd 里的 20261111）是两个独立的东西。
## 但**地形参数一改，这里算出来的选址就全变了**，所以两者要放在一起看。
const TOWN_SEED := 20261112

const MIN_TOWN_DIST := 220.0        ## 城镇之间最小间距（米）
const SPAWN_LIFT := 0.1             ## 出生点离地高度（贴地即可，交给物理落地）

const MAIN_RING := Vector2(80.0, 220.0)    ## 主城选址环带（离原点）
const OUTPOST_RING := Vector2(300.0, 560.0)


## 生成全部城镇：1 主城 + 2 哨站
static func generate(terrain: TerrainBase, seed_value: int = TOWN_SEED) -> Array[TownPlan]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var plans: Array[TownPlan] = []

	var main := TownPlan.new()
	main.id = 0
	main.is_main = true
	main.name = "主城"
	main.radius = 24.0
	main.center = _pick_site(terrain, rng, MAIN_RING, [], 24)
	_populate(terrain, rng, main, 6, true)
	plans.append(main)

	for k in 2:
		var out := TownPlan.new()
		out.id = k + 1
		out.name = "哨站%d" % (k + 1)
		out.radius = 14.0
		var taken: Array[Vector3] = []
		for p in plans:
			taken.append(p.center)
		out.center = _pick_site(terrain, rng, OUTPOST_RING, taken, 18)
		_populate(terrain, rng, out, 2, false)
		plans.append(out)

	return plans


# ------------------------------------------------------------
# 选址
# ------------------------------------------------------------
### 在环带里撒点打分，选最平、离原点最近、海拔适中（±40m）的那个
static func _pick_site(terrain: TerrainBase, rng: RandomNumberGenerator,
		ring: Vector2, taken: Array[Vector3], samples: int) -> Vector3:
	# 别贴着世界边缘：留 80 米给雾和碰撞生成
	var limit := terrain.playable_radius() - 80.0
	var best := Vector3.ZERO
	var best_score := INF
	var fallback := Vector3.ZERO
	var has_fallback := false

	for i in samples:
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(ring.x, ring.y)
		var c := Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		if Vector2(c.x, c.z).length() > limit:
			continue

		var far_enough := true
		for t in taken:
			if Vector2(c.x - t.x, c.z - t.z).length() < MIN_TOWN_DIST:
				far_enough = false
				break
		if not far_enough:
			continue

		c.y = terrain.height_at(c.x, c.z)
		if not has_fallback:
			fallback = c
			has_fallback = true

		var score := _site_score(terrain, c)
		if score < best_score:
			best_score = score
			best = c

	# 兜底：候选全被排除也要返回一个点，绝不返回零向量（那会生成在世界原点，可能是山体里）
	return best if best_score < INF else fallback


### 打分：起伏越小越好，离原点越近越好，海拔别太偏
static func _site_score(t: TerrainBase, c: Vector3) -> float:
	var lo := INF
	var hi := -INF
	var sum := 0.0
	var n := 0
	for i in 5:
		for j in 5:
			var h := t.height_at(c.x + (i - 2) * 10.0, c.z + (j - 2) * 10.0)
			lo = minf(lo, h)
			hi = maxf(hi, h)
			sum += h
			n += 1
	var mean := sum / float(n)
	var relief := hi - lo
	var dist := Vector2(c.x, c.z).length()
	return relief + 0.02 * dist + 0.15 * absf(mean - 40.0)


# ------------------------------------------------------------
# 填充一座镇：出生点 + 建筑
# ------------------------------------------------------------
static func _populate(terrain: TerrainBase, rng: RandomNumberGenerator,
		plan: TownPlan, count: int, with_shop: bool) -> void:
	plan.center.y = terrain.height_at(plan.center.x, plan.center.z)

	# 出生点：广场上均匀一圈（多个出生点，服务器按"就近上次位置"挑）
	var spawn_count := 6 if plan.is_main else 3
	for i in spawn_count:
		var a := TAU * float(i) / float(spawn_count) + 0.3
		var d := plan.radius * 0.45
		var x := plan.center.x + cos(a) * d
		var z := plan.center.z + sin(a) * d
		plan.spawn_points.append(Vector3(x, terrain.height_at(x, z) + SPAWN_LIFT, z))

	# 建筑：绕广场一圈，门朝广场
	for k in count:
		# ① 先定这栋楼"长什么样"（尺寸/层数/朝向），这些和位置无关
		var a := TAU * float(k) / float(count) + rng.randf_range(-0.12, 0.12)
		var size := Vector2(rng.randf_range(9.0, 14.0), rng.randf_range(8.0, 12.0))
		var yaw := 0 if rng.randf() < 0.5 else 90
		var floors := 3 if (with_shop and k == 0) else rng.randi_range(2, 3)

		# ② 再挑位置和门朝向：在"朝广场"的方向上试几圈，每个位置再试 4 个朝向。
		#    这一步是本轮"有些房子不好进"的根治办法 ——
		#    楼放在陡坡上，基座会有 8 米厚、门口落差 7 米，再怎么加台阶也救不回来。
		#
		#    ★ 为什么朝向比位置还关键：楼板高度 = 地基最高点 + 0.2，
		#      所以**门只有开在坡的上坡侧，门口落差才小**。
		#      门朝下坡时，那一侧的地面可能比楼板低好几米，等于把入口开在悬崖上。
		#      朝广场只是"好看"，能不能走进去才是硬指标，所以朝向加分只有 1.2 米当量。
		var best_cost := INF
		var best: BuildingSpec = null
		for da in [-0.18, 0.0, 0.18]:
			for dr in [8.0, 12.0, 16.0]:
				var a2: float = a + float(da)
				var ring: float = plan.radius + float(dr)
				var cand := Vector3(plan.center.x + cos(a2) * ring, 0.0,
					plan.center.z + sin(a2) * ring)
				if _crowded(cand, size, plan.buildings):
					continue
				var probe := BuildingSpec.new()
				probe.center = cand
				probe.size = size
				probe.yaw_deg = yaw
				probe.floors = floors
				probe.is_shop = with_shop and k == 0
				probe.ground_y = terrain.height_at(cand.x, cand.z)
				var plaza_dir := _door_towards(cand.x, cand.z,
					plan.center.x, plan.center.z, yaw)
				for dd in 4:
					probe.door_dir = dd
					# apply 会顺手把 plinth_top / porch_* 填好，所以选中的对象可以直接用
					var cost := BuildingSite.apply(terrain, probe)
					cost += maxf(0.0, cost - 0.6) * 2.0          # 落差越大越不划算
					if dd != plaza_dir:
						cost += 1.2                               # 不朝广场的一点小遗憾
					if cost < best_cost:
						best_cost = cost
						# ★ 必须复制：probe 会被下一轮 apply 覆盖，
						#   直接保存引用的话，最后留下的是"最后一个候选"而不是"最好的那个"。
						best = _clone(probe)

		# 兜底：所有候选都被挤掉时用原始位置（不能返回 null，否则整座镇少一栋楼）
		if best == null:
			best = BuildingSpec.new()
			best.size = size
			best.yaw_deg = yaw
			best.floors = floors
			best.is_shop = with_shop and k == 0
			best.center = Vector3(plan.center.x + cos(a) * (plan.radius + 12.0), 0.0,
				plan.center.z + sin(a) * (plan.radius + 12.0))
			best.ground_y = terrain.height_at(best.center.x, best.center.z)
			best.door_dir = _door_towards(best.center.x, best.center.z,
				plan.center.x, plan.center.z, yaw)
			BuildingSite.apply(terrain, best)

		var spec := best
		plan.buildings.append(spec)

		if spec.is_shop:
			# NPC 站在门内 2 米（门本身在墙外 1 米处，往里退 3 米）
			var n := spec.door_world_normal()
			var inside := spec.door_outside() - n * 3.0
			inside.y = spec.plinth_top
			plan.shop_position = inside
			plan.shop_dir = spec.door_dir


### 复制一份规格书（含 BuildingSite 算出来的四个高度字段）
static func _clone(s: BuildingSpec) -> BuildingSpec:
	var c := BuildingSpec.new()
	c.center = s.center
	c.ground_y = s.ground_y
	c.plinth_top = s.plinth_top
	c.ground_min = s.ground_min
	c.porch_ground = s.porch_ground
	c.porch_depth = s.porch_depth
	c.porch_reach = s.porch_reach
	c.size = s.size
	c.yaw_deg = s.yaw_deg
	c.floors = s.floors
	c.floor_h = s.floor_h
	c.door_dir = s.door_dir
	c.is_shop = s.is_shop
	return c


### 太挤了吗：按两栋楼的"外接半径"粗略排开，避免门廊/台阶插进邻居墙里
static func _crowded(c: Vector3, size: Vector2, placed: Array[BuildingSpec]) -> bool:
	for b in placed:
		var need := (maxf(size.x, size.y) + maxf(b.size.x, b.size.y)) * 0.5 + 4.0
		if Vector2(c.x - b.center.x, c.z - b.center.z).length() < need:
			return true
	return false


### 门朝广场：在世界里算出"朝向中心"的方向，再换算到**建筑局部坐标**
##
### 这一步不换算的话，yaw=90 的楼会把门开到背面 ——
### 因为洞是在局部坐标系里开的，而"朝广场"是世界坐标系里的概念。
static func _door_towards(from_x: float, from_z: float, to_x: float, to_z: float, yaw_deg: int) -> int:
	var d := Vector2(to_x - from_x, to_z - from_z).normalized()
	# 世界方向 → 局部方向：反向旋转。同样用 rotated()，别再手写三角函数。
	var world_dir := Vector3(d.x, 0.0, d.y)
	var local := world_dir.rotated(Vector3.UP, -deg_to_rad(float(yaw_deg)))
	if absf(local.x) > absf(local.z):
		return 2 if local.x > 0.0 else 3      # 局部 +X / -X
	return 0 if local.z > 0.0 else 1          # 局部 +Z / -Z


# ------------------------------------------------------------
# 一致性指纹：给无头测试做 diff 用
# ------------------------------------------------------------
static func digest(plans: Array[TownPlan]) -> String:
	var parts: Array[String] = []
	for p in plans:
		parts.append(p.describe())
		for b in p.buildings:
			parts.append(b.describe())
	return "|".join(parts)
