class_name BuildingSite
extends RefCounted
## 「这栋楼放这儿，地基要多高、平台伸多远、台阶几级」—— 唯一的算法出处
##
## 为什么要单独抽这个类：它有两个使用者，而且必须给出**同一个答案**。
##   · TownGenerator 用它给候选位置打分（哪块地最平，就该把楼放哪儿）
##   · TownBuilder   用它算基座高度、平台深度、台阶长度
## 两边各写一遍必然漂移 —— 生成器认为"很平"的位置，造出来门口落差 7 米。
##
## 三次实测踩出来的三层结构（顺序就是算法）：
##   ① 楼板高度 = 楼内最高点与门外最高点里更高的那个 + 0.2   （门不能被土埋）
##   ② 平台深度 = 往外找到地面离楼板 ≤1 米的地方              （土包土脊直接埋进平台）
##   ③ 台阶长度 = 从平台外沿沿坡下探，直到坡道沉到土里        （只负责最后那 ≤1 米）
##
## ★ ② 是最后补上的、也是最关键的一层。原先只有 ①③：门口一道 1.5 米高的土脊
##   把楼板顶高了，于是"落差"指标看着只有 0.2 米（很完美），
##   可人从外面要翻过那道土坎才过得来 —— 台阶造得再好也没用。

const PLINTH_LIFT := 0.2      ## 楼板比地面最高点再抬多少
const PORCH_DEPTH := 1.9      ## 平台的最小深度（往墙外伸多深）
const PORCH_MAX_DEPTH := 7.0  ## 平台最多伸这么远
const PORCH_SLOPE := 0.5      ## 台阶坡度（0.5 ≈ 26.6°，低于 45° 的地面上限）
const REACH_MIN := 0.7        ## 至少要有两级台阶（平地也有 0.2 米的坎）
const REACH_MAX := 8.0        ## 台阶再长，说明平台没伸够（陡坡上就得更长）
const PROBE_STEP := 0.2       ## 探测步长
const EDGE_MAX_DROP := 1.0    ## 平台外沿处，地面最多比楼板低这么多


### 采样地形，把高度字段写进 spec，并返回"这个位置有多差"（给选址打分用）
##
### 返回值越小越好。落差是主项；门前坡度重罚 —— 坡太陡，人连走到台阶底下都做不到。
static func apply(terrain: TerrainBase, spec: BuildingSpec) -> float:
	var half := spec.size * 0.5
	var lo := INF
	var hi := -INF
	for i in 3:
		for j in 3:
			var local := Vector3((float(i) - 1.0) * half.x, 0.0, (float(j) - 1.0) * half.y)
			if spec.yaw_deg % 360 != 0:
				local = local.rotated(Vector3.UP, deg_to_rad(float(spec.yaw_deg)))
			var h := terrain.height_at(spec.center.x + local.x, spec.center.z + local.z)
			lo = minf(lo, h)
			hi = maxf(hi, h)

	var n := spec.door_world_normal()
	var face: float = absf(n.x) * half.x + absf(n.z) * half.y
	var lateral := Vector3(n.z, 0.0, -n.x)

	# 门外也要采样：门朝上坡时，屋外的土可能比楼板还高，门会被埋进去
	var porch_hi := -INF
	for d in [1.0, 2.0, 3.0, 4.5, 6.0, 8.0]:
		for lat in [-2.5, -1.0, 0.0, 1.0, 2.5]:
			var dd: float = d
			var ll: float = lat
			var px: float = spec.center.x + n.x * (face + dd) + lateral.x * ll
			var pz: float = spec.center.z + n.z * (face + dd) + lateral.z * ll
			porch_hi = maxf(porch_hi, terrain.height_at(px, pz))

	# ① 楼板高度
	spec.plinth_top = maxf(hi, porch_hi) + PLINTH_LIFT
	spec.ground_min = lo - 0.8
	if spec.ground_y == 0.0:
		spec.ground_y = terrain.height_at(spec.center.x, spec.center.z)

	# ② 平台深度：往外找第一处"地面离楼板 ≤ EDGE_MAX_DROP"的地方。
	#    要求连续两个采样点都满足 —— 否则会停在一道土脊的顶上（土脊后面又是坑）。
	var depth := PORCH_DEPTH
	for i in 13:
		var d := PORCH_DEPTH + 0.45 * float(i)
		if d > PORCH_MAX_DEPTH:
			break
		depth = d                      # 先假设要伸到这里（一轮都没达标就用最远的）
		var g1 := _ground(terrain, spec, n, face + d)
		var g2 := _ground(terrain, spec, n, face + d + 0.8)
		var edge := spec.plinth_top - minf(g1, g2)
		if edge >= 0.02 and edge <= EDGE_MAX_DROP:
			break
		# edge < 0 说明这里的地面比楼板还高（土包）→ 必须继续铺过去把它埋掉。
		# 第一版在这里"取最小 edge"，等于专挑被土埋得最深的位置停下 —— 正好挑反。
	spec.porch_depth = depth

	# ③ 台阶长度：从平台外沿沿坡下探，找到"坡道面第一次沉到土面之下"的那一点
	var d_end := -1.0
	for i in int(REACH_MAX / PROBE_STEP) + 1:
		var dd := PROBE_STEP * float(i + 1)
		if spec.plinth_top - PORCH_SLOPE * dd \
				<= _ground(terrain, spec, n, face + depth + dd) + 0.02:
			d_end = dd
			break
	spec.porch_reach = clampf(d_end if d_end > 0.0 else REACH_MAX, REACH_MIN, REACH_MAX)

	# 台阶末端踩到的高度：坡道公式与实际地形取更高的那个，保证不悬空
	var g_end := _ground(terrain, spec, n, face + depth + spec.porch_reach)
	spec.porch_ground = maxf(spec.plinth_top - PORCH_SLOPE * spec.porch_reach, g_end)

	# 打分：落差 + 门前坡度重罚（超过 ~31° 就基本走不上去了）+ 楼内起伏
	var max_slope := 0.0
	var prev := _ground(terrain, spec, n, face + 0.4)
	for i in 15:
		var dd := 0.4 * float(i + 1)
		var g := _ground(terrain, spec, n, face + 0.4 + dd)
		max_slope = maxf(max_slope, absf(g - prev) / 0.4)
		prev = g

	return (spec.plinth_top - spec.porch_ground) \
		+ 0.25 * (spec.plinth_top - lo) \
		+ maxf(0.0, max_slope - 0.55) * 14.0


static func _ground(terrain: TerrainBase, spec: BuildingSpec, n: Vector3, dist: float) -> float:
	return terrain.height_at(spec.center.x + n.x * dist, spec.center.z + n.z * dist)
