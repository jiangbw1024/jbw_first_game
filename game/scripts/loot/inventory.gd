class_name Inventory
extends RefCounted
## S11 · 背包：固定格数 + 堆叠
##
## ★ 为什么是"格"而不是"重量"：
##   重量的好处是连续、真实；坏处是玩家**没法预估**。
##   你捡起一块金属是 +0.3 还是 +1.2？玩家算不出来，于是每次拾取都像开盲盒。
##   格子是离散的：一眼看到"还剩 2 格"，就知道"还能再拿两样东西"。
##   压力必须**可预估**，玩家才会真的为它做决策 —— 否则只是随机让人烦躁。
##
## ★ 为什么是 RefCounted 而不是 Node：
##   背包是**数据**，不是场景里的东西。它不需要 _process、不需要在树里、
##   不需要同步位置。做成 Node 只会带来"谁来 add_child 它"这种无意义的问题。
##   跨端传递时只传 slots（Array），由对端 new 一个再 load_state()。
##
## ★ 服务器权威：只有服务器能改 slots。客户端拿到的永远是**结果**。
##   理由和血量、装备完全一样 —— 能改背包就能凭空刷物资。

const SLOTS := 12

## 每格是 {} 或 {"id": String, "count": int}
var slots: Array = []


func _init() -> void:
	for i in SLOTS:
		slots.append({})


# ------------------------------------------------------------
# 写入（只在服务器调用）
# ------------------------------------------------------------
### 尝试放进 count 个，返回**实际放进去的数量**。
##
## 为什么返回数量而不是 bool：
##   玩家背包只剩 1 格时捡 5 个废金属，正确的行为是"拿走 20 个、剩下 4 个留在地上"，
##   而不是"背包满了，一个都不给"。bool 表达不了这件事，
##   而"部分拾取"恰好是玩家最舒服的那种反馈。
func add(item_id: String, count: int) -> int:
	if count <= 0 or not ItemDef.has(item_id):
		return 0
	var cap := ItemDef.stack_of(item_id)
	var left := count

	# ① 先填已有的同类堆。不先填的话会出现"背包里有 3 堆各 1 个"的碎片
	for i in SLOTS:
		if left <= 0:
			break
		var s: Dictionary = slots[i]
		if String(s.get("id", "")) != item_id:
			continue
		var room := cap - int(s["count"])
		if room <= 0:
			continue
		var n := mini(room, left)
		s["count"] = int(s["count"]) + n
		left -= n

	# ② 再占空格
	for i in SLOTS:
		if left <= 0:
			break
		var s: Dictionary = slots[i]
		if not s.is_empty():
			continue
		var n := mini(cap, left)
		s["id"] = item_id
		s["count"] = n
		left -= n

	return count - left


### 取出 count 个，返回实际取出的数量
func take(item_id: String, count: int) -> int:
	var left := maxi(0, count)
	for i in SLOTS:
		if left <= 0:
			break
		var s: Dictionary = slots[i]
		if String(s.get("id", "")) != item_id:
			continue
		var have := int(s["count"])
		var n := mini(have, left)
		s["count"] = have - n
		if int(s["count"]) <= 0:
			s.clear()
		left -= n
	return maxi(0, count) - left


# ------------------------------------------------------------
# 查询（两端都可）
# ------------------------------------------------------------
func count_of(item_id: String) -> int:
	var total := 0
	for s in slots:
		if String(s.get("id", "")) == item_id:
			total += int(s["count"])
	return total


func used_slots() -> int:
	var n := 0
	for s in slots:
		if not s.is_empty():
			n += 1
	return n


func is_full() -> bool:
	return used_slots() >= SLOTS


### 能不能**完整**装下 count 个（用于"捡之前先判断要不要提示背包满"）
func can_fit(item_id: String, count: int) -> bool:
	if not ItemDef.has(item_id):
		return false
	var cap := ItemDef.stack_of(item_id)
	var room := 0
	for s in slots:
		if s.is_empty():
			room += cap
		elif String(s.get("id", "")) == item_id:
			room += cap - int(s["count"])
		if room >= count:
			return true
	return room >= count


# ------------------------------------------------------------
# 序列化：跨端只传这个
# ------------------------------------------------------------
### 每格压成 [id, count] 或 []。
## 为什么不用 slots.duplicate(true) 直接传：
##   字典跨进程序列化要多包一层类型信息，而这里的数据形状是固定的 ——
##   压成两元素数组更小，也让"网络上到底传了什么"一眼可见。
func to_array() -> Array:
	var out: Array = []
	for s in slots:
		if s.is_empty():
			out.append([])
		else:
			out.append([String(s["id"]), int(s["count"])])
	return out


func load_state(data: Array) -> void:
	slots.clear()
	for i in SLOTS:
		if i < data.size():
			var e = data[i]
			if e is Array and e.size() >= 2:
				slots.append({"id": String(e[0]), "count": int(e[1])})
				continue
		slots.append({})


func clear() -> void:
	for i in SLOTS:
		slots[i] = {}
