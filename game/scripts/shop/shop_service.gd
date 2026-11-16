extends Node
## 服务器权威的装备服务
##
## 三件事，都只有服务器说了算：
##   ① 谁买了什么（`_equipment: peer_id → item_id`）
##   ② 买的时候人是不是真的在商店旁边（用它自己看到的位置量，不信客户端）
##   ③ 把结果广播给所有人（外观要让别人看得见）
##
## ★ 为什么不用 MultiplayerSynchronizer 同步 hand_item_id？
##   装备是"低频、离散、必须到达"的数据。Synchronizer 走不可靠通道，
##   而且是"变更时发一次" —— 丢一次包就永久不同步，直到玩家再换一次枪。
##   RPC + reliable 是"一次成功即终态"，更适合账本型数据。
##   位置那种"每秒都在变、丢了马上有新值"的连续量，才适合 Synchronizer。

const MAX_BUY_DISTANCE := 6.0
const BUY_COOLDOWN_MS := 250

var _equipment: Dictionary = {}     # peer_id → item_id
var _last_buy_ms: Dictionary = {}


func _ready() -> void:
	GameState.buy_requested.connect(_on_buy_requested)
	# 客户端连上后主动要一份全表：让需要数据的一方发起，顺序永远是对的
	multiplayer.connected_to_server.connect(func() -> void: rpc_id(1, "_request_equipment"))


func _on_buy_requested(item_id: int) -> void:
	if multiplayer.is_server():
		_server_buy(multiplayer.get_unique_id(), item_id)
	else:
		rpc_id(1, "_request_buy", item_id)


# ------------------------------------------------------------
# 客户端 → 服务器
# ------------------------------------------------------------
@rpc("any_peer", "call_remote", "reliable")
func _request_buy(item_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	_server_buy(sender, item_id)


func _server_buy(peer_id: int, item_id: int) -> void:
	if not Goods.has(item_id):
		_notify.rpc_id(peer_id, "没有这件装备")
		return

	var p := _player_node(peer_id)
	if p == null:
		return

	var now := Time.get_ticks_msec()
	if now - int(_last_buy_ms.get(peer_id, -999999)) < BUY_COOLDOWN_MS:
		return
	_last_buy_ms[peer_id] = now

	# ★ 距离由服务器用它看到的玩家位置来量。
	#   信任客户端上报的坐标 = 允许在 2 公里外买空商店（也是所有"远程刷物品"漏洞的根源）
	var town := get_node_or_null("../Town") as TownBuilder
	if town != null:
		if p.global_position.distance_to(town.npc_position()) > MAX_BUY_DISTANCE:
			_notify.rpc_id(peer_id, "离商店太远")
			return

	_apply_equip.rpc(peer_id, item_id)


# ------------------------------------------------------------
# 服务器 → 所有人
# ------------------------------------------------------------
@rpc("authority", "call_local", "reliable")
func _apply_equip(peer_id: int, item_id: int) -> void:
	# 先写缓存：即使玩家节点还没复制过来，这次装备也不会丢
	_equipment[peer_id] = item_id

	var p := _player_node(peer_id)
	if p != null and p.has_method("apply_hand_item"):
		p.apply_hand_item(item_id)

	if peer_id == multiplayer.get_unique_id():
		GameState.notify.emit("已装备：%s" % Goods.name_of(item_id), 2.0)


# ------------------------------------------------------------
# 新人加入：补一份全表
# ------------------------------------------------------------
@rpc("any_peer", "call_remote", "reliable")
func _request_equipment() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var list := []
	for pid in _equipment:
		list.append([int(pid), int(_equipment[pid])])
	_apply_equipment.rpc_id(sender, list)


@rpc("authority", "call_remote", "reliable")
func _apply_equipment(list: Array) -> void:
	for e in list:
		var pid := int(e[0])
		var item := int(e[1])
		_equipment[pid] = item
		var p := _player_node(pid)
		if p != null and p.has_method("apply_hand_item"):
			p.apply_hand_item(item)
	print("[S8] 收到装备快照：%d 条" % list.size())


### 玩家节点出现时重放一次（幂等）。
### 覆盖"装备 RPC 比节点复制先到"这个顺序问题 —— 两条路都落同一个缓存，所以一定收敛。
func replay(node: Node3D) -> void:
	if node == null:
		return
	var pid := int(node.name)
	if _equipment.has(pid) and node.has_method("apply_hand_item"):
		node.apply_hand_item(int(_equipment[pid]))
		print("[S8] 重放装备 peer=%d item=%d" % [pid, int(_equipment[pid])])


@rpc("authority", "call_remote", "reliable")
func _notify(text: String) -> void:
	GameState.notify.emit(text, 2.0)


func equipment_of(peer_id: int) -> int:
	return int(_equipment.get(peer_id, 0))


func _player_node(id: int) -> Node3D:
	var players := get_node_or_null("../Players")
	if players == null:
		return null
	return players.get_node_or_null(str(id)) as Node3D
