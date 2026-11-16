class_name WeaponState
## 一把枪的运行时状态：余弹、冷却、扩散累积、换弹进度
##
## 为什么把"数据"和"状态"分开：
##   WeaponDef 是常量表（改它 = 改游戏平衡），WeaponState 是某个玩家手里那把手枪
##   "现在还剩几发"。混在一起的后果是——你在调试时改了 def，所有测试都变成"满弹"，
##   因为状态被数据覆盖了。分开之后，数据永远只读，状态永远可变。

var id: String
var def: Dictionary

var ammo: int
var reserve: int

## 距离下一发还要等多久（秒）
var cooldown := 0.0
## 连射累积的额外扩散（度）
var bloom := 0.0

var reloading := false
var reload_left := 0.0

## 输入缓冲：在冷却结束前 0.12 秒内点击，冷却一结束立刻开火。
## 没有它的话，玩家"点得比射速快"时会有一种"我没按到"的掉手感。
const BUFFER_TIME := 0.12
var buffer := 0.0


func _init(weapon_id := "ak47") -> void:
	id = weapon_id
	def = WeaponDef.get_def(weapon_id)
	ammo = int(def["mag"])
	reserve = int(def["reserve"])


func tick(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	bloom = maxf(0.0, bloom - float(def["spread_recover"]) * delta)
	buffer = maxf(0.0, buffer - delta)
	if reloading:
		reload_left -= delta
		if reload_left <= 0.0:
			_finish_reload()


func can_fire() -> bool:
	return not reloading and cooldown <= 0.0 and ammo > 0


### 真正打出一发：扣弹、上冷却、加扩散
func consume() -> void:
	ammo -= 1
	cooldown = float(def["interval"])
	bloom = minf(bloom + float(def["spread_per_shot"]), float(def["spread_max"]))


### 点了一下但打不出来（冷却中/空仓）：存进缓冲，稍后补上
func remember_press() -> void:
	buffer = BUFFER_TIME


func wants_buffered_shot() -> bool:
	return buffer > 0.0 and can_fire()


func begin_reload() -> bool:
	if reloading or ammo >= int(def["mag"]) or reserve <= 0:
		return false
	reloading = true
	reload_left = float(def["reload"])
	return true


### 切枪会打断换弹。弹药不返还、也不补满，就是停在当前状态。
func cancel_reload() -> void:
	reloading = false
	reload_left = 0.0


func _finish_reload() -> void:
	var need := int(def["mag"]) - ammo
	var take := mini(need, reserve)
	ammo += take
	reserve -= take
	reloading = false
	reload_left = 0.0
	bloom = 0.0          # 换弹会把枪口稳定下来，这是惯例


### 当前扩散角（度）。speed 是玩家水平速度，on_floor 决定是否吃空中惩罚
func spread_deg(speed: float, on_floor: bool) -> float:
	var s := float(def["spread_base"]) + bloom
	# 移动惩罚按"速度占步行速度的比例"给，跑起来明显变散但不会完全失控
	s += float(def["move_penalty"]) * clampf(speed / 5.0, 0.0, 1.6)
	if not on_floor:
		s += float(def["air_penalty"])
	return minf(s, float(def["spread_max"]) + float(def["air_penalty"]) + 2.0)


### 换弹进度 0..1（给视图模型做动画）
func reload_ratio() -> float:
	if not reloading:
		return 0.0
	return 1.0 - reload_left / maxf(0.01, float(def["reload"]))
