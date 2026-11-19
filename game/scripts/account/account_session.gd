extends Node
## 会话与存档同步（Autoload，全局名 `AccountSession`）
##
## 它只做"胶水"，不改游戏规则：
##   ① 等本地玩家出现，然后按启动方式挑一个存档后端（本地文件 / 云端）；
##   ② 把存档还原成 Player / Inventory / ShopService 需要的结构；
##   ③ 监听 GameState 信号 + 轮询装备账本，把变化写回；
##   ④ 提供「退出登录」和「排行榜」入口。
##
## ★ S13 三个关键改动（原来这里是"账号与联机互斥"的另一半原因）：
##   1. **不再强行单机。** 以前发现 `Players/1` 不存在就 `_solo = true` + 隐藏菜单，
##      于是"登录"等于"只能单机"。现在启动方式由 Launch 决定，这里只负责存档。
##   2. **不再写死 `Players/1`。** 那个路径在客户端上指向**房主的角色** ——
##      会把你的存档灌到别人身上。改成按 `get_unique_id()` 动态查。
##   3. **单机有本地存档了。** 以前不登录就没有任何持久化，重启即失忆。
##
## ★ 为什么存档还留在这个文件里，而不是拆一个 SaveManager：
##   转换函数（`_collect_save` / `_to_server_save` / `_from_server_save`）
##   全部依赖 `_player`，拆出去要一起搬。现在用 `Backend` 枚举在内部
##   分两个分支，改动面最小。真正的拆法是"存档格式"和"后端读写"分成两层，
##   等联机存档的权威问题（谁能写）定下来再拆，否则会白拆一次。

## ★ 为什么存档同步放在 Autoload 而不是 Player：
##   Player 由服务器生成，联机时客户端会重建、死亡会重生；把"账号存档"
##   绑在 Player 上，重生和换场景都会丢。Autoload 活得比场景久，
##   而且能同时看到 GameState、ShopService 和场景树，是最小的侵入位置。
##
## ★ 为什么装备用轮询而不是改 ShopService：
##   现有商店把装备放在 `_equipment: peer_id -> item_id` 里，购买成功后写这个字典。
##   我们只读它、比对变化，再把同一个整数写进存档；不改购买链路，
##   也不新增第二套装备结构。

const WORLD_SCENE := "res://scenes/world.tscn"
const LOGIN_SCENE := "res://scenes/login/login.tscn"
const START_SCENE := "res://scenes/start/start.tscn"
const BADGE_SCENE := preload("res://scenes/account/account_badge.tscn")
const LEADERBOARD_SCENE := preload("res://scenes/leaderboard/leaderboard.tscn")

const SAVE_VERSION := 1
const AUTOSAVE_INTERVAL := 3.0
const RANK_PUSH_INTERVAL := 15000
const EQUIPMENT_POLL_INTERVAL := 0.4
const DIRTY_SAVE_DELAY := 0.55

## 单机存档路径。格式与云端**完全一致**（同一份 `_to_server_save` 产物），
## 这样"单机玩到一半想联机"不需要任何迁移代码。
const LOCAL_SAVE_PATH := "user://local_save.json"

## 当前这套会话用哪个后端写档案
enum Backend {
	NONE,   ## 不同步（自检、无账号的命令行联机）
	LOCAL,  ## user://local_save.json（单机）
	CLOUD,  ## 后端 /api/saves/me（联机，JWT 认证）
}

## 当前游戏没有关卡系统。排行榜的"进度"用累计生存时长推导：
## 每 10 分钟算一个阶段，余数换算成阶段内百分比。
const STAGE_SECONDS := 600.0

var _world: Node = null
var _player: Node3D = null
var _badge: CanvasLayer = null
var _leaderboard: CanvasLayer = null

## 当前用哪个后端。NONE 表示"这次不存档"，所有写入口都会直接返回，
## 这样自检和无账号联机不会在磁盘上留下垃圾文件。
var _backend := Backend.NONE
## Players 容器。存下来是为了能断开它的 child_entered_tree 连接，
## 不留下指向已释放场景的回调。
var _players: Node = null

var _save_loaded := false
var _applying := false
var _dirty := false
var _dirty_wait := 0.0
var _flushing := false
var _save_revision := 0

var _equipment_poll := 0.0
var _autosave_timer := 0.0
var _last_equipment := -1
var _play_seconds := 0.0
var _base_play_seconds := 0.0

var _pushing_rank := false
var _last_rank_push := -RANK_PUSH_INTERVAL

## 每换一次世界/退出登录就 +1。异步请求回来时如果 epoch 变了，
## 说明它属于旧会话，直接丢弃结果，避免旧请求把新会话踢回登录页。
var _session_epoch := 0
var _leaving := false

var _leaderboard_was_paused := false
var _leaderboard_was_mouse := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	# 暂停时也要继续做装备轮询和自动存档。按钮本身不依赖 _process，
	# 但"暂停菜单里退出登录"之后要立刻保存，这里的 ALWAYS 是必要的。
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().scene_changed.connect(_on_scene_changed)
	GameState.inventory_changed.connect(_on_inventory_changed)
	GameState.ammo_changed.connect(_on_ammo_changed)
	GameState.health_changed.connect(_on_health_changed)
	_on_scene_changed()


func _notification(what: int) -> void:
	# 关窗口 / 切到后台时各存一次。自动登录状态不受影响：
	# 只有 Account.logout() 或 token 失效才会删 user://auth_session.json。
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if _save_loaded:
			_flush_save()


# ------------------------------------------------------------
# 场景流转（登录页 / 主场景都调用这里）
# ------------------------------------------------------------
func enter_game() -> Error:
	if not Account.is_logged_in():
		return ERR_UNAUTHORIZED
	# 登录页可能是在退出旧会话后回来的。ENet 服务器属于 Net Autoload，
	# 不会随世界场景释放；不主动断开的话端口 7777 会一直被旧 peer 占着。
	_close_multiplayer_peer()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return get_tree().change_scene_to_file(WORLD_SCENE)


### 手动退出：先尽力把最后一份存档写回，再回到"该回的那一屏"。
##
### ★ 这版修的 bug：单机点「退出登录」完全没反应。
##   旧实现是
##       await _flush_save()
##       if not Account.is_logged_in(): return      # ← 单机永远走这里
##       _leave_to_login(true)
##   单机没有账号，`is_logged_in()` 恒为 false，于是整个函数在最后一步之前
##   就返回了：存档其实已经写盘，但场景不换、按钮还停在"正在保存并退出…"。
##   **"没登录"不等于"没会话可退"。** 单机的会话是本地档案，照样要能退出。
##
### 现在的语义：退出 = 结束当前会话，回到进入它的那一屏。
##   云端会话 → 清 token，回登录页（换个人登）；
##   本地会话 → 没有 token 可清，回开始页重新选「单机 / 联机」。
##   两种都要先把存档落盘，否则这次游玩的进度就白玩了。
func logout_to_login() -> void:
	if _leaving:
		return
	if _save_loaded:
		await _flush_save()
	# _flush_save 收到 401 时已经自行回登录页了，别在这里再切一次场景。
	if _leaving:
		return
	if _logout_needs_login():
		_leave_to(LOGIN_SCENE, true)
	else:
		# ★ token 不清：单机虽然不读账号，但"下次联机自动登录"还有用。
		#   清 token 是"我要换个人玩"的意思，只有云端会话才有这个语义。
		_leave_to(START_SCENE, false)


### 退出后应该回登录页吗？
##
### 唯一的判据是「这次会话是不是真的握着一个云端身份」：
##   单机（LOCAL）不读账号，即使本机存着 token 也不算云端会话 ——
##   这时候把玩家丢到登录页，等于让一个只想单机的人先登录，纯添堵。
func _logout_needs_login() -> bool:
	return _backend == Backend.CLOUD and Account.is_logged_in()


### 离开当前这一局，回开始页 —— **不退账号、不删 token**。
##
### ★ 为什么它和 logout_to_login 是两个函数：
##   "我不想玩这一局了" 和 "我要换个账号登" 是两种意图，
##   只是以前只有后者的实现，想回开始页的人被迫登出，
##   下次联机还得重新输密码 —— 一个动作顺手干了另一件不该干的事。
func leave_to_start() -> void:
	if _leaving:
		return
	if _save_loaded:
		await _flush_save()
	# _flush_save 里收到 401 已经自己回登录页了，别抢着再切一次。
	if _leaving:
		return
	_leave_to(START_SCENE, false)


### 决定这次用哪个存档后端。
##
### 优先级不是拍脑袋定的，每条都有具体理由：
###   1. **自检最优先**：它跑在无头环境里，写存档会污染 user:// 并且让断言不可重复
###   2. **单机 = 本地文件**（即使已登录）：
###      单机不该依赖后端。若单机也走云端，后端一挂、token 一过期，
###      一个只想自己玩的人就会被弹回登录页 —— 这是最气人的体验。
###      代价是单机进度不会自动上云，见下面那条边界说明。
###   3. **已登录 = 云端**：联机的全部意义就是"进度跟着账号走"
###   4. **其余（--server / --join 无账号）= 不存档**：
###      没有身份就没有"该写进谁的档案"这个答案，硬写只会写错人
func _pick_backend() -> Backend:
	if Launch.is_selftest():
		return Backend.NONE
	if Launch.mode == Launch.Mode.SOLO:
		return Backend.LOCAL
	if Account.is_logged_in():
		return Backend.CLOUD
	return Backend.NONE


func _backend_name() -> String:
	match _backend:
		Backend.LOCAL: return "本地"
		Backend.CLOUD: return "云端"
		_: return "无"


### 真正离开世界：清状态 → （可选）清 token → 换场景。
##
### ★ 参数是"去哪一屏"，不是"是否退出登录"。
##   S13 之前这里写死 LOGIN_SCENE，因为那时只有联机一条路；
##   现在单机也要能退出，目的地就变成了调用方要回答的问题。
func _leave_to(scene_path: String, clear_token: bool) -> void:
	if _leaving:
		return
	_leaving = true
	_close_leaderboard()
	_save_loaded = false
	_dirty = false
	_detach_world()
	if clear_token:
		Account.logout()
	get_tree().paused = false
	# ★ 一次性清空所有输入锁，不逐个 release。
	#   离开时死者的 "dead"、背包的 "bag" 都可能还挂在集合里；
	#   漏掉一个，下一局进游戏角色就不动了（而且看不出是谁锁的）。
	GameState.clear_ui()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 回开始页 = 这次启动结束了：必须把 direct 清掉，否则开始页会把玩家
	# 立刻又送回世界（命令行启动时尤其明显：退出像没生效）。
	if scene_path == START_SCENE:
		Launch.end_intent()
	get_tree().change_scene_to_file(scene_path)


func _expire_session() -> void:
	Account.logout()
	# token 已经删了，这里只负责把玩家送回登录页。
	_leave_to(LOGIN_SCENE, false)


# ------------------------------------------------------------
# 主场景接入
# ------------------------------------------------------------
func _on_scene_changed() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	if scene.scene_file_path == WORLD_SCENE:
		_attach_world(scene)
		return

	# 离开世界（登录页 / 开始页 / 登出）：先抢着存一次，再断开。
	# 主场景已经释放，此时关 peer 不会让 world/player 在最后一帧
	# 调用 get_unique_id() 报错；端口也会在下一屏可交互前释放。
	_close_multiplayer_peer()
	if _save_loaded and is_instance_valid(_player):
		_flush_save()
	_save_loaded = false
	_detach_world()


func _attach_world(scene: Node) -> void:
	if _world == scene:
		return
	_world = scene
	_player = null
	_players = null
	_badge = null
	_leaderboard = null
	_save_loaded = false
	_backend = Backend.NONE
	_applying = false
	_dirty = false
	_dirty_wait = 0.0
	_flushing = false
	_pushing_rank = false
	_save_revision = 0
	_play_seconds = 0
	_base_play_seconds = 0
	_last_equipment = -1
	_equipment_poll = 0.0
	_autosave_timer = 0.0
	_last_rank_push = -RANK_PUSH_INTERVAL
	_session_epoch += 1
	_leaving = false
	_world.tree_exiting.connect(_on_world_exiting)

	_backend = _pick_backend()
	if _backend == Backend.NONE:
		# 自检 / 无账号联机：不挂徽章、不读存档、不写盘。
		# 这三件事一件都不做，自检才是干净可重复的。
		return

	_add_badge(
		Account.username() if _backend == Backend.CLOUD else "本地档案",
		_backend == Backend.CLOUD)
	_bind_when_ready()


### 等"我的"玩家节点出现，再开始同步存档。
##
### ★ 为什么不能等固定几帧（旧版就是等 12 帧然后放弃）：
##   从登录页进来时，玩家是在**点了「创建房间」之后**才由服务器生成的，
##   中间可能隔几十秒。等固定帧数必然失败，而且失败得很安静 ——
##   旧版的表现就是"登录了但存档没加载"，日志里只有一行 warning。
###
### 所以改成挂 `Players.child_entered_tree`：谁进来都看一眼是不是我。
func _bind_when_ready() -> void:
	var players := _world.get_node_or_null("Players")
	if players == null:
		push_warning("[存档] 主场景没有 Players 容器，跳过存档")
		return
	_players = players
	if not players.child_entered_tree.is_connected(_on_player_entered):
		players.child_entered_tree.connect(_on_player_entered)
	_try_bind_local_player()


func _on_player_entered(_node: Node) -> void:
	_try_bind_local_player()


func _try_bind_local_player() -> void:
	if is_instance_valid(_player):
		return
	var p := _local_player()
	if p == null:
		return
	_player = p
	print("[存档] 绑定本地玩家节点 %s（后端：%s）" % [p.name, _backend_name()])
	_claim_identity(p)
	await _load_save()


### 本地玩家 = 节点名等于**我的** peer_id 的那个。
##
### ★ 这里以前写死 "Players/1"，是这次要修的核心 bug：
##   在客户端上，`Players/1` 是**房主**的角色。
##   写死它等于"把我的存档灌进别人身体里"—— 传送他、改他的血。
##   之前没出事，只是因为互斥让客户端根本走不到这条路。
func _local_player() -> Node3D:
	if not is_instance_valid(_world):
		return null
	var players := _world.get_node_or_null("Players")
	if players == null:
		return null
	return players.get_node_or_null(str(multiplayer.get_unique_id())) as Node3D


### 把账号身份写进玩家节点。
##
### 单机（LOCAL）没有账号，跳过：本地档案不需要"证明我是谁"。
func _claim_identity(p: Node3D) -> void:
	if _backend != Backend.CLOUD:
		return
	var acc_id := 0
	var raw := Account.account_id()
	if raw.is_valid_int():
		acc_id = int(raw)
	if multiplayer.is_server():
		p.call("apply_identity", acc_id, Account.username())
	else:
		p.rpc_id(1, "_request_identity", acc_id, Account.username())


### 释放全局 MultiplayerAPI 的 peer。
##
### ENetMultiplayerPeer 绑定的是进程级端口，世界场景被 free 并不会关掉它。
### 只切场景不退会话的话，下一次 Net.host() 的 create_server(PORT) 会返回
### ERR_ALREADY_IN_USE，表现就是「点了创建房间，提示创建失败」。
### 实现已经搬到 Net（谁管端口，谁负责关），这里保留名字只是为了调用点可读。
func _close_multiplayer_peer() -> void:
	Net.shutdown()


func _on_world_exiting() -> void:
	if _save_loaded and is_instance_valid(_player):
		_flush_save()
	_save_loaded = false


func _detach_world() -> void:
	# 断开 Players 的信号：场景马上要被 free，留着连接会变成指向已释放对象的回调
	if is_instance_valid(_players) and _players.child_entered_tree.is_connected(_on_player_entered):
		_players.child_entered_tree.disconnect(_on_player_entered)
	_players = null
	_world = null
	_player = null
	_backend = Backend.NONE
	_badge = null
	_leaderboard = null
	_applying = false
	_dirty = false
	_flushing = false
	_pushing_rank = false
	_last_equipment = -1
	_session_epoch += 1


### cloud=false 表示"本地档案"：没有云端身份，排行榜按钮在这局里是死键，
### 退出按钮实际做的是"回开始页"。徽章自己决定怎么显示，这里只提供事实。
func _add_badge(display_name: String, cloud := true) -> void:
	if _badge != null and is_instance_valid(_badge):
		return
	_badge = BADGE_SCENE.instantiate() as CanvasLayer
	_world.add_child(_badge)
	if _badge.has_method("setup"):
		_badge.call("setup", display_name, cloud)


func _set_badge_state(text: String) -> void:
	if _badge != null and is_instance_valid(_badge) and _badge.has_method("set_sync_state"):
		_badge.call("set_sync_state", text)


# ------------------------------------------------------------
# 排行榜覆盖层
# ------------------------------------------------------------
func open_leaderboard() -> void:
	if _leaderboard != null and is_instance_valid(_leaderboard):
		return
	if not is_instance_valid(_world) or not Account.is_logged_in():
		return

	# 记录打开前的暂停/鼠标状态：从暂停菜单里点进来时，关闭后要回到暂停菜单，
	# 而不是直接把玩家丢回游戏。
	_leaderboard_was_paused = get_tree().paused
	_leaderboard_was_mouse = Input.mouse_mode
	_leaderboard = LEADERBOARD_SCENE.instantiate() as CanvasLayer
	_world.add_child(_leaderboard)
	_leaderboard.close_requested.connect(_close_leaderboard)
	GameState.claim_ui("leaderboard")
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_leaderboard() -> void:
	if _leaderboard != null and is_instance_valid(_leaderboard):
		_leaderboard.queue_free()
	_leaderboard = null
	GameState.release_ui("leaderboard")
	if _leaderboard_was_paused:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		get_tree().paused = false
		Input.mouse_mode = _leaderboard_was_mouse


# ------------------------------------------------------------
# 服务端存档 → 本地结构
# ------------------------------------------------------------
### 读存档并灌进玩家。两种后端共用同一份格式转换。
##
### ★ 为什么本地存档也存"服务端格式"（equipmentData / gameProgress / characterStats）：
##   如果本地存一份、云端存一份，就出现了两种格式和两套转换代码 ——
##   以后改存档结构必然漏改一边，而漏掉的那一边会表现为"单机好好的，联机丢装备"。
##   **一种格式、两个后端**，是这个函数能这么短的原因。
func _load_save() -> void:
	var epoch := _session_epoch
	var raw := {}

	if _backend == Backend.LOCAL:
		raw = _read_local_save()
		if raw.is_empty():
			# 第一次玩单机没有存档是正常的，不是错误。
			# 这里必须把 _save_loaded 置真，否则后面所有自动保存都会被挡掉。
			_save_loaded = true
			_set_badge_state("新档案（本地）")
			print("[存档] 本地没有档案，按新角色开始")
			return
	else:
		var server_save := Account.take_prefetched_save()
		if server_save.is_empty():
			_set_badge_state("正在同步存档…")
			var result: Dictionary = await Account.fetch_save()
			if epoch != _session_epoch:
				return
			if not bool(result.get("ok", false)):
				if int(result.get("status", 0)) == 401 or not Account.is_logged_in():
					_expire_session()
					return
				# 读取失败时禁止自动保存，否则会把空存档覆盖掉服务端真实进度。
				_save_loaded = false
				_set_badge_state("存档加载失败")
				GameState.notify.emit("无法读取云端存档：%s" % String(result.get("reason", "未知错误")), 4.0)
				push_warning("[账号] 云端存档读取失败：%s" % String(result.get("reason", "")))
				return
			var fetched: Variant = result.get("data", {})
			server_save = fetched if fetched is Dictionary else {}
		raw = server_save

	_load_save_into_player(_from_server_save(raw))
	_maybe_push_rank(_collect_save(), true)


# ------------------------------------------------------------
# 本地存档（S13）
# ------------------------------------------------------------
### 路径带默认参数，是为了让自检能写到临时文件上。
##  自检如果写真正的存档路径，跑一次测试就会覆盖玩家自己的进度 ——
##  这种"测试污染真实数据"的问题一旦出现，比功能坏了更难察觉。
func _read_local_save(path := LOCAL_SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	# 文件损坏时按"新档案"处理，而不是让游戏起不来。
	# 代价是这一刻的进度会丢 —— 但总比卡在加载界面强。
	push_warning("[存档] 本地档案解析失败，按新角色开始（原文件保留）")
	return {}


func _write_local_save(payload: Dictionary, path := LOCAL_SAVE_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[存档] 无法写入 %s：%s" % [
			path, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true


### 给开始页用的一行摘要：有没有本地档案、上次保存时间、累计生存时长。
##
### ★ 只读。开始页只是"看一眼"，不能因为看了一眼就碰玩家的档案 ——
###   所以这里既不调用 `_load_save`，也不改 `_backend` / `_save_loaded`。
##   修改时间从文件 mtime 取，因为写进磁盘的 payload 里没有 saved_at
##   （`_to_server_save` 只保留 equipmentData / gameProgress / characterStats）。
func local_save_summary() -> Dictionary:
	if not FileAccess.file_exists(LOCAL_SAVE_PATH):
		return {"has": false, "modified": 0, "play_seconds": 0}
	var raw := _read_local_save()
	var play_seconds := 0
	var progress: Variant = raw.get("gameProgress", {})
	if progress is Dictionary:
		play_seconds = int((progress as Dictionary).get("play_seconds", 0))
	return {
		"has": not raw.is_empty(),
		"modified": int(FileAccess.get_modified_time(LOCAL_SAVE_PATH)),
		"play_seconds": play_seconds,
	}


### 后端只存三段 JSON；游戏内仍使用原来的 player/progress 结构。
##   equipmentData  -> player.equipment
##   gameProgress   -> player.position / yaw + progress.play_seconds
##   characterStats -> player.hp / inventory / weapon
func _from_server_save(server_save: Dictionary) -> Dictionary:
	var player: Dictionary = {
		"position": [],
		"equipment": {},
	}
	var progress: Dictionary = {"play_seconds": 0}

	var equipment: Variant = server_save.get("equipmentData", {})
	if equipment is Dictionary:
		player["equipment"] = (equipment as Dictionary).duplicate(true)

	var game_progress: Variant = server_save.get("gameProgress", {})
	if game_progress is Dictionary:
		var progress_data: Dictionary = game_progress
		if progress_data.get("position") is Array:
			player["position"] = (progress_data["position"] as Array).duplicate()
		if progress_data.has("yaw"):
			player["yaw"] = float(progress_data.get("yaw", 0.0))
		progress["play_seconds"] = int(progress_data.get("play_seconds", 0))

	var stats: Variant = server_save.get("characterStats", {})
	if stats is Dictionary:
		var stats_data: Dictionary = stats
		if stats_data.has("hp"):
			player["hp"] = float(stats_data.get("hp", 100.0))
		if stats_data.get("inventory") is Array:
			player["inventory"] = (stats_data["inventory"] as Array).duplicate(true)
		if stats_data.get("weapon") is Dictionary:
			player["weapon"] = (stats_data["weapon"] as Dictionary).duplicate(true)

	return {
		"version": SAVE_VERSION,
		"account_id": Account.account_id(),
		"saved_at": int(Time.get_unix_time_from_system()),
		"player": player,
		"progress": progress,
	}


func _load_save_into_player(save: Dictionary) -> void:
	var data: Variant = save.get("player", {})
	if not data is Dictionary:
		data = {}
	var pdata: Dictionary = data

	_applying = true
	_base_play_seconds = int(save.get("progress", {}).get("play_seconds", 0)) if save.get("progress") is Dictionary else 0
	_play_seconds = 0

	# ★ 只有"本机说了算"的时候才能直接写位置和血量。
	#
	#   单机 / 主机：本机就是服务器，写进去就是真的。
	#   客户端：位置由服务器同步、血量由服务器判定。本机写进去会被
	#   下一帧覆盖 —— 表现是"进游戏瞬间闪一下位置又弹回来"，
	#   严重时角色会卡在墙里。
	#
	#   所以客户端走另一条路：把存档里的"起点状态"打包发给房主，
	#   由房主落到服务器那份玩家上（见 player.gd 的 _request_adopt_state）。
	var authoritative := multiplayer.is_server()

	if authoritative:
		var saved_pos: Variant = pdata.get("position", [])
		if saved_pos is Array and (saved_pos as Array).size() >= 3:
			var pos := _vec3_from(saved_pos)
			_player.global_position = pos
			if _player.has_method("set_spawn_point"):
				_player.call("set_spawn_point", pos)
			# 打出来是为了能验收"坐标真的恢复了"。
			# 只看截图不行：出生点和存档点可能恰好重合，看不出区别。
			print("[存档] 恢复位置 (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z])
		if pdata.has("yaw"):
			_player.rotation.y = float(pdata.get("yaw", 0.0))

		var hp := clampf(float(pdata.get("hp", 100.0)), 1.0, 100.0)
		_player.set("hp", hp)
		_player.set("dead", false)
		GameState.player_health = hp
		GameState.player_health_max = 100.0
		GameState.health_changed.emit(hp, 100.0)
		GameState.death_changed.emit(false)

		var inventory = _player.get("inventory")
		if inventory != null and pdata.get("inventory") is Array:
			inventory.load_state(pdata["inventory"])
			GameState.inventory_changed.emit(inventory)

		var combat = _player.get_node_or_null("Combat")
		if combat != null and pdata.get("weapon") is Dictionary:
			var wdata: Dictionary = pdata["weapon"]
			if combat.get("weapon") != null:
				var weapon = combat.get("weapon")
				weapon.ammo = clampi(int(wdata.get("ammo", weapon.ammo)), 0, 999)
				weapon.reserve = clampi(int(wdata.get("reserve", weapon.reserve)), 0, 999)
				GameState.ammo_changed.emit(weapon.ammo, weapon.reserve, false)
	else:
		# 客户端：只递交"角色状态"，不含坐标 —— 出生点由房主的世界决定，
		# 不然你会在别人家里凭空出现。
		_player.rpc_id(1, "_request_adopt_state", {
			"hp": float(pdata.get("hp", 100.0)),
			"inventory": pdata.get("inventory", []),
			"weapon": pdata.get("weapon", {}),
		})

	# 装备是纯外观，两端都要生效，不分权威
	var item_id := _equipment_from_save(pdata)
	_apply_equipment(item_id)

	_applying = false
	_save_loaded = true
	_last_equipment = item_id
	_set_badge_state("档案已加载（%s）" % _backend_name())
	print("[存档] 已加载%s档案（装备 item=%d）" % [_backend_name(), item_id])


### 从存档里取出装备 id。
##
### ★ 兼容两种格式：
##   `{"1": 3}`  —— 旧格式，键是 peer_id。存档本来就是 1:1 账号的，
##                  所以这个键从来没起过作用，取第一个值即可。
##   `{"item": 3}` —— 新格式。装备跟着账号走，不需要键。
func _equipment_from_save(pdata: Dictionary) -> int:
	var equipment: Variant = pdata.get("equipment", {})
	if not (equipment is Dictionary):
		return 0
	var map: Dictionary = equipment
	if map.has("item"):
		return int(map["item"])
	for key in map:
		return int(map[key])
	return 0


func _apply_equipment(item_id: int) -> void:
	var shop := _world.get_node_or_null("ShopService")
	if shop == null:
		if _player.has_method("apply_hand_item"):
			_player.call("apply_hand_item", item_id)
		return

	# 复用现有装备账本：peer_id -> item_id。
	# 存档里只存一个整数，和 ShopService._equipment 的值完全同构。
	var ledger: Variant = shop.get("_equipment")
	if ledger is Dictionary:
		(ledger as Dictionary)[int(_player.name)] = item_id
	if shop.has_method("replay"):
		shop.call("replay", _player)
	elif _player.has_method("apply_hand_item"):
		_player.call("apply_hand_item", item_id)


func _current_equipment() -> int:
	if not is_instance_valid(_world) or not is_instance_valid(_player):
		return _last_equipment
	var shop := _world.get_node_or_null("ShopService")
	if shop == null:
		return _last_equipment
	var ledger: Variant = shop.get("_equipment")
	if ledger is Dictionary:
		return int((ledger as Dictionary).get(int(_player.name), 0))
	return _last_equipment


# ------------------------------------------------------------
# 玩家 → 服务端存档
# ------------------------------------------------------------
func _process(delta: float) -> void:
	if not _save_loaded or not is_instance_valid(_player):
		return
	_play_seconds += delta
	_equipment_poll += delta
	_autosave_timer += delta

	if _equipment_poll >= EQUIPMENT_POLL_INTERVAL:
		_equipment_poll = 0.0
		var item_id := _current_equipment()
		if item_id != _last_equipment:
			_last_equipment = item_id
			_mark_dirty(0.15)

	if _autosave_timer >= AUTOSAVE_INTERVAL:
		_autosave_timer = 0.0
		_mark_dirty(0.0)

	if _dirty:
		_dirty_wait -= delta
		if _dirty_wait <= 0.0:
			_flush_save()


func _on_inventory_changed(_inv) -> void:
	_mark_dirty(DIRTY_SAVE_DELAY)


func _on_ammo_changed(_mag: int, _reserve: int, _reloading: bool) -> void:
	_mark_dirty(DIRTY_SAVE_DELAY)


func _on_health_changed(_hp: float, _max_hp: float) -> void:
	_mark_dirty(DIRTY_SAVE_DELAY)


func _mark_dirty(delay: float) -> void:
	if _applying or not _save_loaded or _backend == Backend.NONE:
		return
	# 云端后端才有"登录失效"这回事；本地存档跟账号无关
	if _backend == Backend.CLOUD and not Account.is_logged_in():
		return
	if not _dirty:
		_set_badge_state("同步中…")
	_dirty = true
	_dirty_wait = delay
	_save_revision += 1


func _flush_save() -> void:
	if _flushing or not _save_loaded or not is_instance_valid(_player):
		return
	if _backend == Backend.NONE:
		return
	if _backend == Backend.CLOUD and not Account.is_logged_in():
		return

	_flushing = true
	var epoch := _session_epoch
	var revision := _save_revision
	var payload := _to_server_save(_collect_save())

	if _backend == Backend.LOCAL:
		# 本地写盘是同步的，没有 await。但脏标记流程保持和云端完全一致 ——
		# 两种后端的触发时机、合并窗口一样，行为才可预期（也就可测）。
		var ok := _write_local_save(payload)
		_flushing = false
		if ok:
			_settle_revision(revision)
			_set_badge_state("已保存（本地）")
		else:
			_dirty = true
			_dirty_wait = 2.0
			_set_badge_state("本地保存失败")
		return

	var result: Dictionary = await Account.push_save(payload)
	_flushing = false
	if epoch != _session_epoch:
		# ★ 会话已经换了（登出/重开），这次结果作废。
		#   但 _flushing 必须在 return 之前复位，否则这个 autoload
		#   会永久卡在"正在保存"，之后一次都不会再存。
		return

	if bool(result.get("ok", false)):
		_settle_revision(revision)
		_set_badge_state("已同步")
		_maybe_push_rank(_collect_save(), false)
		return

	if int(result.get("status", 0)) == 401 or not Account.is_logged_in():
		_expire_session()
		return
	_dirty = true
	_dirty_wait = 2.0
	_set_badge_state("同步失败，稍后重试")
	push_warning("[账号] 存档同步失败：%s" % String(result.get("reason", "")))


### 保存成功后的收尾：只有"这期间没有新改动"才算干净。
##  否则保持脏，立刻再存一次 —— 不然快速连点会丢掉最后一次改动。
func _settle_revision(revision: int) -> void:
	if revision == _save_revision:
		_dirty = false
		_dirty_wait = 0.0
	else:
		_dirty = true
		_dirty_wait = 0.0


func _collect_save() -> Dictionary:
	var weapon_data := {"ammo": 0, "reserve": 0}
	var combat = _player.get_node_or_null("Combat")
	if combat != null and combat.get("weapon") != null:
		var weapon = combat.get("weapon")
		weapon_data = {"ammo": int(weapon.ammo), "reserve": int(weapon.reserve)}

	var inventory = _player.get("inventory")
	var inventory_data: Array = []
	if inventory != null:
		inventory_data = inventory.to_array()

	# world.tree_exiting 时玩家可能已经离开树，此时 get_global_position() 会报错。
	# 玩家是 Players 的直接子节点，父节点在世界原点，local == global；
	# 离开树时退回本地坐标即可，不能因为退出瞬间的日志把存档丢了。
	var pos := _player.position
	if _player.is_inside_tree():
		pos = _player.global_position

	# ★ 存档是 1:1 账号的，所以装备就是一个值，不需要 peer_id 当键。
	#   旧格式 {peer_id: item} 的键从来没起过作用（每份存档只有一个玩家），
	#   写的时候直接用新格式，读的时候两种都认（见 _equipment_from_save）。
	var equipment := {"item": _current_equipment()}

	return {
		"version": SAVE_VERSION,
		"account_id": Account.account_id(),
		"saved_at": int(Time.get_unix_time_from_system()),
		"player": {
			"position": [pos.x, pos.y, pos.z],
			"yaw": _player.rotation.y,
			"hp": float(_player.get("hp")),
			"inventory": inventory_data,
			"equipment": equipment,
			"weapon": weapon_data,
		},
		"progress": {
			"play_seconds": int(_base_play_seconds + _play_seconds),
		},
	}


func _to_server_save(local_save: Dictionary) -> Dictionary:
	var player: Variant = local_save.get("player", {})
	var progress: Variant = local_save.get("progress", {})
	if not player is Dictionary:
		player = {}
	if not progress is Dictionary:
		progress = {}
	var pdata: Dictionary = player
	var progress_data: Dictionary = progress

	return {
		"equipmentData": pdata.get("equipment", {}),
		"gameProgress": {
			"position": pdata.get("position", []),
			"yaw": float(pdata.get("yaw", 0.0)),
			"play_seconds": int(progress_data.get("play_seconds", 0)),
		},
		"characterStats": {
			"hp": float(pdata.get("hp", 100.0)),
			"inventory": pdata.get("inventory", []),
			"weapon": pdata.get("weapon", {}),
		},
		"saveVersion": SAVE_VERSION,
	}


# ------------------------------------------------------------
# 排行榜数据同步
# ------------------------------------------------------------
func _maybe_push_rank(save: Dictionary, force: bool) -> void:
	if _pushing_rank or not _save_loaded or not Account.is_logged_in():
		return
	var now := Time.get_ticks_msec()
	if not force and now - _last_rank_push < RANK_PUSH_INTERVAL:
		return

	_pushing_rank = true
	_last_rank_push = now
	var epoch := _session_epoch
	var stats := _rank_stats(save)
	var result: Dictionary = await Account.push_leaderboard(
		int(stats["combat_power"]),
		int(stats["cleared_stage"]),
		float(stats["clear_progress"])
	)
	if epoch != _session_epoch:
		return
	_pushing_rank = false
	if bool(result.get("ok", false)):
		return
	if int(result.get("status", 0)) == 401:
		_expire_session()
		return
	push_warning("[排行榜] 数据同步失败：%s" % String(result.get("reason", "")))


func _rank_stats(save: Dictionary) -> Dictionary:
	var player: Variant = save.get("player", {})
	if not player is Dictionary:
		player = {}
	var pdata: Dictionary = player

	var item_id := 0
	if is_instance_valid(_player):
		item_id = _equipment_from_save(pdata)

	var item_count := 0
	var inventory: Variant = pdata.get("inventory", [])
	if inventory is Array:
		for entry in inventory:
			if entry is Dictionary:
				item_count += int((entry as Dictionary).get("count", 0))

	var progress: Variant = save.get("progress", {})
	var play_seconds := 0
	if progress is Dictionary:
		play_seconds = int((progress as Dictionary).get("play_seconds", 0))

	# 战力只由现有数据推导，不新增游戏内属性：
	# 基础 1000 + 装备价值 ×6 + 背包物资数量 ×12 + 每分钟生存 ×5。
	var combat_power := 1000
	combat_power += Goods.price_of(item_id) * 6
	combat_power += item_count * 12
	combat_power += int(play_seconds / 60.0) * 5

	var stages := int(play_seconds / STAGE_SECONDS)
	var in_stage := play_seconds - stages * int(STAGE_SECONDS)
	var clear_progress := clampf(float(in_stage) / STAGE_SECONDS * 100.0, 0.0, 100.0)

	return {
		"combat_power": combat_power,
		"cleared_stage": stages,
		"clear_progress": clear_progress,
	}


func _vec3_from(value: Variant) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var arr: Array = value
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO
