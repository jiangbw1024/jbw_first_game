class_name KnifeState
## 一把刀的运行时状态：冷却、重击前摇、待结算的重击
##
## 为什么重击要拆成"开始"和"结算"：
##   右键按下去不能立刻出伤害，否则 0.35 秒前摇只是动画，玩家没有反应空间。
##   开始只负责进入前摇；真正扣血由服务器在 tick 里到点结算。

const KnifeDefScript = preload("res://scripts/combat/knife_def.gd")

var id: String
var def: Dictionary

var cooldown := 0.0
var pending_heavy := false
var _windup_left := 0.0


func _init(knife_id := "butterfly") -> void:
	id = knife_id
	def = KnifeDefScript.get_def(knife_id)


func tick(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	if pending_heavy:
		_windup_left -= delta


func can_light() -> bool:
	return cooldown <= 0.0 and not pending_heavy


func can_heavy() -> bool:
	return cooldown <= 0.0 and not pending_heavy


func begin_light() -> bool:
	if not can_light():
		return false
	cooldown = float(def["light_interval"])
	return true


func begin_heavy() -> bool:
	if not can_heavy():
		return false
	cooldown = float(def["heavy_interval"])
	pending_heavy = true
	_windup_left = float(def["heavy_windup"])
	return true


### 前摇走完时返回 true，由 Combat 结算一次伤害。
## 不清空 pending 的话，同一帧会被 _process 反复消费。
func consume_pending() -> bool:
	if not pending_heavy or _windup_left > 0.0:
		return false
	pending_heavy = false
	_windup_left = 0.0
	return true


func cancel_pending() -> void:
	pending_heavy = false
	_windup_left = 0.0


### 0..1，给视图模型做"抬手→劈下"的进度。
func windup_ratio() -> float:
	if not pending_heavy:
		return 0.0
	return 1.0 - clampf(_windup_left / maxf(0.01, float(def["heavy_windup"])), 0.0, 1.0)
