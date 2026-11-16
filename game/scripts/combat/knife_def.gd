class_name KnifeDef
## 刀具数据表（纯数据，不建节点、不碰 UI）
##
## 第一把刀是蝴蝶刀。数值按 CS2 的直觉定，但用丧尸 100 血做校准：
##   轻击 40  → 3 刀
##   重击 90  → 2 刀
##   背刺 180 → 1 刀
##
## 和枪一样，这里只放"常量"。某一把刀现在还有几次冷却，在 KnifeState 里。

const DB := {
	"butterfly": {
		"id": "butterfly",
		"name": "蝴蝶刀",
		"light_damage": 40.0,
		"heavy_damage": 90.0,
		"backstab_damage": 180.0,
		"range": 2.2,
		"angle": 55.0,             # 锥形判定半角（度）
		"light_interval": 0.45,
		"heavy_windup": 0.35,
		"heavy_interval": 0.90,
		"backstab_dot": -0.5,      # 目标朝向与"目标→玩家"的夹角余弦阈值
		"light_duration": 0.35,
		"heavy_duration": 0.50,
		"inspect_duration": 1.20,
	},
}


static func get_def(id: String) -> Dictionary:
	if not DB.has(id):
		push_warning("[KnifeDef] 未知刀具 %s，回退蝴蝶刀" % id)
		return DB["butterfly"]
	return DB[id]


static func default_id() -> String:
	return "butterfly"
