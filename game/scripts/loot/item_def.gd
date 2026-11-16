class_name ItemDef
extends RefCounted
## S11 · 物资表（唯一真相源）
##
## ★ 为什么是常量表而不是 Resource / JSON：
##   物资表要在**客户端和服务器两边**都完全一致 —— 服务器说"你捡到了废金属"，
##   客户端要照着它的名字和颜色画出来，两边对不上的结果就是
##   "服务器的废金属在客户端叫『铁片』"。常量表两端逐字相同、可 diff、零 IO。
##
##   等物资涨到上百种、需要策划改数值时，再上 Resource。现在上只会让
##   "改一个名字"变成"开编辑器、改资源、重新导入"。
##
## ★ stack：一格能放多少个。它决定了背包压力的形状 ——
##   弹药一格 60 发很宽松，废金属一格 20 个就很紧。这不是拍脑袋，
##   是"哪种东西该逼玩家做取舍"的设计语言。

const AMMO := "ammo_rifle"
const MEDKIT := "medkit"
const SCRAP := "scrap"
const WOOD := "wood"
const CLOTH := "cloth"

## kind 决定"拿到之后发生什么"：
##   "ammo"   → 直接进枪的备用弹（不占背包格）
##   "consumable" → 进背包，按 H 使用
##   "material"   → 进背包，S12 建造时消耗
const LIST := {
	AMMO: {
		"name": "步枪弹",
		"kind": "ammo",
		"stack": 60,
		"color": Color(0.78, 0.64, 0.24),
	},
	MEDKIT: {
		"name": "急救包",
		"kind": "consumable",
		"stack": 4,
		"heal": 40.0,
		"color": Color(0.80, 0.24, 0.20),
	},
	SCRAP: {
		"name": "废金属",
		"kind": "material",
		"stack": 20,
		"color": Color(0.50, 0.54, 0.60),
	},
	WOOD: {
		"name": "木材",
		"kind": "material",
		"stack": 20,
		"color": Color(0.42, 0.29, 0.16),
	},
	CLOTH: {
		"name": "布料",
		"kind": "material",
		"stack": 20,
		"color": Color(0.62, 0.57, 0.48),
	},
}


static func has(item_id: String) -> bool:
	return LIST.has(item_id)


static func get_def(item_id: String) -> Dictionary:
	return LIST.get(item_id, {})


static func name_of(item_id: String) -> String:
	return String(get_def(item_id).get("name", "未知物品"))


static func kind_of(item_id: String) -> String:
	return String(get_def(item_id).get("kind", "material"))


static func stack_of(item_id: String) -> int:
	return int(get_def(item_id).get("stack", 1))


static func color_of(item_id: String) -> Color:
	return get_def(item_id).get("color", Color(0.6, 0.6, 0.6)) as Color


### 所有物资 id（掉落表随机时用）
static func all_ids() -> Array:
	return LIST.keys()


### 常用掉落表：丧尸身上会掉什么。
## 权重之和不必是 100 —— 用"累加区间"抽样，只要权重非负即可。
## 为什么不掉 AMMO 给丧尸：子弹应该来自"你打光了"，不该来自"尸体"，
## 否则玩家会开始刷丧尸补弹，把拾荒动力反过来。
const ZOMBIE_DROPS := [
	{"id": CLOTH, "weight": 34, "min": 1, "max": 3},
	{"id": SCRAP, "weight": 28, "min": 1, "max": 2},
	{"id": MEDKIT, "weight": 22, "min": 1, "max": 1},
	{"id": AMMO, "weight": 16, "min": 6, "max": 12},
]


### 按权重从表里抽一次，返回 {"id": String, "count": int}，抽不出来返回 {}
##
### ★ 为什么用"累减区间"而不是自己算浮点百分比：
##   整数累减没有精度问题，而且"总权重是多少"不需要事先知道 ——
##   以后往表里加一行，不用改任何代码。
##   浮点版（randf() * total 然后逐个减）在边界上可能出现
##   "谁都没减到负"导致返回空，这类 bug 只在特定权重组合下才复现。
static func roll_from(table: Array) -> Dictionary:
	var total := 0
	for e in table:
		total += int(e.get("weight", 0))
	if total <= 0:
		return {}
	var r := randi() % total
	for e in table:
		r -= int(e.get("weight", 0))
		if r < 0:
			return {
				"id": String(e["id"]),
				"count": randi_range(int(e.get("min", 1)), int(e.get("max", 1))),
			}
	return {}
