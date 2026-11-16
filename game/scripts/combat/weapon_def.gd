class_name WeaponDef
## 枪械数据表（纯数据，不建节点、不碰 UI）
##
## 本轮**只有 AK47**。理由：一把枪才能把参数调到"手感对"，
## 三把半成品不如一把打磨过的。加新枪只需要在 DB 里加一段 —— 结构已经留好。
##
## 单位说明（写错会差一个数量级）：
##   damage       —— 单发伤害
##   interval     —— 两发之间的最小间隔（秒）。600 RPM = 0.1
##   spread_*     —— **角度（度）**。0.3 度 ≈ 200 米外偏 1 米
##   recoil_v     —— 每发把视角往上顶多少（度）
##   recoil_h     —— 每发的水平随机偏移（度）
##   recoil_recover —— 后坐力每秒回落多少（度/秒）
##
## AK47 的定位：**高伤害、强后坐、弹匣大、不能无脑扫**。
##   前三发可以点射精准，按住不放枪口会一路爬到天上 —— 这是它的性格，
##   也是"会玩"和"不会玩"的分界线。

const DB := {
	"ak47": {
		"id": "ak47",
		"name": "AK47",
		"damage": 34.0,
		"interval": 0.100,          # 600 RPM，和真枪一致
		"auto": true,
		"mag": 30,
		# ★ S11 把开局备用弹从 240 降到 90（= 3 个弹匣）。
		#   240 是"永远打不完"的量，那样拾荒就失去了最强的一条动机 ——
		#   玩家不会为了一堆弹药走进危险区。
		#   90 发的含义是：能打两三场遭遇战，然后**必须去找补给**。
		#   上限（Combat.RESERVE_CAP = 240）则是"攒得起来，但攒不满"。
		"reserve": 90,
		"reload": 2.45,             # 换弹偏慢，逼你算着打
		"spread_base": 0.32,        # 静止首发：几乎指哪打哪
		"spread_per_shot": 0.46,    # 连射扩散
		"spread_max": 6.2,
		"spread_recover": 8.0,      # 停火后收敛速度
		"move_penalty": 2.0,
		"air_penalty": 4.5,
		"recoil_v": 1.05,           # 前 3 发可控，之后明显爬升
		"recoil_h": 0.52,           # 左右抖，逼你点射
		"recoil_recover": 10.5,
		"range": 220.0,
		"pellets": 1,
		"head_mult": 2.4,
		"sound": "shot_rifle",
		"muzzle_flash": 1.15,
	},
}


static func get_def(id: String) -> Dictionary:
	if not DB.has(id):
		push_warning("[WeaponDef] 未知枪械 %s，回退 AK47" % id)
		return DB["ak47"]
	return DB[id]


static func all_ids() -> Array:
	return DB.keys()


static func default_id() -> String:
	return "ak47"
