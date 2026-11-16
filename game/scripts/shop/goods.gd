class_name Goods
extends RefCounted
## 占位商品表：本轮**没有**物品系统、背包、货币
##
## 为什么不放服务器下发、也不做 Resource：
##   ① 下发等于把"外观长什么样"变成网络数据 —— 多一份可以被改写的真相；
##      常量两端逐字一致、可 diff、零 IO，联机时永远不会不同步。
##   ② 本轮只有 3 条占位数据，上 Resource 是给未来的物品表预留。
##      等真做物品/货币时，迁移面只有这一个文件。
##
## 商品靠"盒子清单"描述外观：换枪 = 换一组盒子的尺寸/位置/颜色。
## 等有美术资源了，把 parts 换成模型路径即可，同步层完全不用动。

const LIST := [
	{
		"id": 1,
		"name": "脉冲步枪",
		"price": 120,
		"parts": [
			{"size": Vector3(0.10, 0.10, 0.72), "offset": Vector3(0, 0, -0.18), "color": Color(0.30, 0.55, 0.92)},
			{"size": Vector3(0.08, 0.22, 0.10), "offset": Vector3(0, -0.14, 0.06), "color": Color(0.22, 0.24, 0.28)},
			{"size": Vector3(0.06, 0.06, 0.30), "offset": Vector3(0, 0.06, 0.28), "color": Color(0.75, 0.78, 0.82)},
		],
	},
	{
		"id": 2,
		"name": "散射炮",
		"price": 260,
		"parts": [
			{"size": Vector3(0.20, 0.20, 0.52), "offset": Vector3(0, 0, -0.14), "color": Color(0.86, 0.52, 0.18)},
			{"size": Vector3(0.26, 0.26, 0.12), "offset": Vector3(0, 0, -0.42), "color": Color(0.55, 0.32, 0.12)},
			{"size": Vector3(0.09, 0.24, 0.09), "offset": Vector3(0, -0.16, 0.10), "color": Color(0.24, 0.22, 0.20)},
		],
	},
	{
		"id": 3,
		"name": "磁轨枪",
		"price": 480,
		"parts": [
			{"size": Vector3(0.07, 0.07, 1.05), "offset": Vector3(0, 0, -0.30), "color": Color(0.55, 0.88, 0.78)},
			{"size": Vector3(0.12, 0.14, 0.26), "offset": Vector3(0, -0.02, 0.18), "color": Color(0.30, 0.36, 0.38)},
			{"size": Vector3(0.16, 0.05, 0.34), "offset": Vector3(0, 0.10, -0.10), "color": Color(0.72, 0.95, 0.90)},
		],
	},
]

const EMPTY_ID := 0


static func has(item_id: int) -> bool:
	if item_id <= EMPTY_ID:
		return false
	for it in LIST:
		if int(it["id"]) == item_id:
			return true
	return false


static func get_item(item_id: int) -> Dictionary:
	for it in LIST:
		if int(it["id"]) == item_id:
			return it
	return {}


static func name_of(item_id: int) -> String:
	var it := get_item(item_id)
	return String(it.get("name", "空手"))


static func price_of(item_id: int) -> int:
	var it := get_item(item_id)
	return int(it.get("price", 0))
