extends Node3D
## S3 · 世界：搭场 + 管理玩家生成
##
## 这一阶段最重要的一句话：
##   **玩家不是"各自生成自己"，而是"由服务器统一生成，然后复制到所有端"。**
##
## 为什么？如果每台机器各自决定"我要生成一个玩家"，那么：
##   - A 认为自己有 1 个玩家，B 也认为自己有 1 个，但他们互相不知道对方存在
##   - 谁先谁后、谁叫什么名字、出生点在哪，全都不一致
## 由服务器统一指挥，所有人看到的世界才是同一个世界。

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const TARGET_SCENE := preload("res://scenes/target.tscn")
const ZOMBIE_SCENE := preload("res://scenes/zombie.tscn")
const LOOT_DROP_SCENE := preload("res://scenes/loot_drop.tscn")
const LOOT_CONTAINER_SCENE := preload("res://scenes/loot_container.tscn")
const SPAWN_LIFT := 1.4

## 场上同时存在的丧尸上限。它不是性能上限，是**体验上限**：
## 超过 6 只，玩家就分不清哪只是哪只，击杀的成就感会被稀释
const MAX_ZOMBIES := 6
const ZOMBIE_SPAWN_INTERVAL := 4.0
## 在玩家周围多远生成。太近会"凭空冒出来"，太远则永远走不到跟前
const ZOMBIE_SPAWN_MIN := 26.0
const ZOMBIE_SPAWN_MAX := 40.0

@onready var players: Node3D = $Players
## 每个 peer 上一次所在的位置（内存即可：进程重启就忘掉，符合"本轮不做存档"）
var _last_pos: Dictionary = {}
## 首次进入时轮流分配的出生点游标
var _spawn_cursor := 0
@onready var menu: CanvasLayer = $Menu
@onready var status: Label = $Menu/Center/VBox/Status
@onready var hud: GameHud = $HUD
@onready var terrain: TerrainBase = $Terrain
@onready var town: TownBuilder = $Town
## 不写死类型：shop_service.gd 没有 class_name，用鸭子类型调用 replay()
@onready var shop = $ShopService
@onready var targets: Node3D = $Targets
@onready var zombies: Node3D = $Zombies
@onready var loot: Node3D = $Loot

## 单机模式：本地开一个没人连的主机。零网络行为差异，但不用选菜单
var _solo := false
# 初值设为完整间隔：否则第一帧就会刷一只在 26 米外，
# 玩家一出生就听到莫名其妙的嘶吼声，且首屏就已经有敌人在跑
var _zombie_timer := ZOMBIE_SPAWN_INTERVAL


func _ready() -> void:
	# 任何玩家节点进入/离开世界，两端都打印一行 —— 调试联机时这行日志最值钱
	players.child_entered_tree.connect(_on_player_added)
	players.child_exiting_tree.connect(_on_player_removed)

	Net.session_started.connect(_on_session_started)
	Net.session_failed.connect(_on_session_failed)
	# 客户端"真的连上"是异步事件，只有收到这个信号才能确定进世界了。
	# 之前漏了这一步，菜单会一直挂着，输入框会抢走键盘事件 —— 表现就是"进游戏了但动不了"。
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	$Menu/Center/VBox/HostBtn.pressed.connect(_on_host_pressed)
	$Menu/Center/VBox/JoinBtn.pressed.connect(_on_join_pressed)

	# ★ 顺序就是语义：先有地形，再有城镇，最后才可能有人连进来。
	#   客户端也执行同一行 —— 城镇不联网同步，各端用同一种子各算一遍。
	town.generate(terrain)

	_handle_cmdline()
	_maybe_run_selftest()


### 无头验收入口：`-- --selftest <名字>`
## 探针自己会 quit，所以放在最后、且不依赖任何异步流程
func _maybe_run_selftest() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--selftest"):
		return
	var i := args.find("--selftest")
	var test_name := "all"
	if i + 1 < args.size() and not args[i + 1].begins_with("--"):
		test_name = args[i + 1]
	var probe: Node = load("res://scripts/dev/selftest.gd").new()
	probe.name = "Selftest"
	add_child(probe)
	probe.run(test_name)

	# 保险丝：探针脚本要是解析失败，进程会一直挂着不退（第一次踩过，跑了 9 分钟）。
	# 90 秒没结果就带着错误码退出，让 shell 立刻知道出事了。
	# （porch 那条测试要逐帧模拟 10 栋楼的行走，本身就占十几秒，所以给得宽一点）
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		push_error("[TEST] 超时未完成，强制退出")
		get_tree().quit(2))




# ------------------------------------------------------------
# 命令行模式：方便脚本化测试，也方便以后开专用服务器
#   Godot --headless --path game -- --server
#   Godot --path game -- --join 192.168.1.10
# 注意 `--` 之后的参数要用 OS.get_cmdline_user_args() 读，
# 前面的会被 Godot 自己吃掉。
# ------------------------------------------------------------
func _handle_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--solo"):
		# 单机 = 本地主机（没有人连进来）。
		# 为什么不做"纯离线"：那要把 Spawner/Synchronizer/RPC 全部绕开，
		# 几天后开联机又得补回来。现在这样，联机阶段只需去掉这个分支。
		_solo = true
		menu.visible = false
		Net.host()
	elif args.has("--server"):
		menu.visible = false
		Net.host()
	elif args.has("--join"):
		var i := args.find("--join")
		var ip := "127.0.0.1"
		if i + 1 < args.size():
			ip = args[i + 1]
		menu.visible = false
		print("[S3] 正在连接 %s …" % ip)
		Net.join(ip)


# ------------------------------------------------------------
# 会话
# ------------------------------------------------------------
func _on_session_started(role: String) -> void:
	hud.show_notice("")
	if role == "host":
		menu.visible = false
		_begin_server()
	else:
		# 客户端要等 connected_to_server 才算真的连上，这里只更新提示
		status.text = "正在连接…"
		menu.visible = true


func _on_session_failed(reason: String) -> void:
	status.text = reason
	menu.visible = true
	hud.show_notice(reason)
	push_warning("[S3] %s" % reason)


func _on_connected_to_server() -> void:
	menu.visible = false
	print("[S3] 已进入世界（本机 peer_id = %d）" % multiplayer.get_unique_id())


func _begin_server() -> void:
	# 这两个信号必须在有人连接之前挂上，否则会漏掉事件
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[S3] 服务端已启动，端口 %d，等待连接…" % Net.PORT)
	# 主机自己也是一个玩家，peer_id 固定为 1
	_spawn_for_peer(1)
	_spawn_loot_containers()
	if _solo:
		_spawn_targets()


func _on_peer_connected(id: int) -> void:
	print("[S3] 玩家 %d 加入" % id)
	_spawn_for_peer(id)


func _on_peer_disconnected(id: int) -> void:
	print("[S3] 玩家 %d 离开" % id)
	if players.has_node(str(id)):
		players.get_node(str(id)).queue_free()


# ------------------------------------------------------------
# 生成玩家（只在服务器执行）
# ------------------------------------------------------------
func _spawn_for_peer(id: int) -> void:
	if players.has_node(str(id)):
		return
	var player := PLAYER_SCENE.instantiate()
	# 关键：节点名 = peer_id。这是"这台机器代表谁"的唯一标识，
	# 客户端靠它认出"哪个是我"，也靠它做 RPC 的目标寻址。
	player.name = str(id)
	player.position = _spawn_position_for(id)
	print("[S8] 玩家 %d 出生于 (%.1f, %.1f, %.1f)" % [
		id, player.position.x, player.position.y, player.position.z])
	players.add_child(player)


### 出生点：优先"就近上次位置"，否则主城广场
##
### 为什么由服务器算？因为 `_last_pos` 只有服务器有权威值，
### 而且"哪个出生点合法"依赖城镇数据 —— 客户端自己算就是第二个真相源。
func _spawn_position_for(id: int) -> Vector3:
	var last: Variant = _last_pos.get(id, null)
	var xz: Vector3
	if typeof(last) == TYPE_VECTOR3:
		xz = town.pick_spawn(last)
	else:
		# 首次进入：轮流用广场上的出生点。
		# 不用"随机取一个"是因为同时进来的两个人可能抽到同一个点，出生即重叠。
		xz = town.main_spawn(_spawn_cursor)
		_spawn_cursor += 1
	# 出生点已经带了地面高度（生成时采样过），但地形可能被改过 —— 再查一次最稳
	var ground := terrain.height_at(xz.x, xz.z)
	return Vector3(xz.x, maxf(xz.y, ground) + SPAWN_LIFT, xz.z)


func _on_player_added(node: Node) -> void:
	var who := "我" if int(node.name) == multiplayer.get_unique_id() else "远端"
	print("[S3] 世界中出现玩家 %s（%s）" % [node.name, who])
	# 记住出生点，死亡后回到这里。放在"已加入世界"这一刻记录，
	# 而不是 player._ready() 里 —— 那时节点的位置可能还没被设置好
	if node.has_method("set_spawn_point"):
		node.set_spawn_point((node as Node3D).global_position)
	# 地形可能需要在观察者周围生成网格与碰撞（Terrain3D 就是这样）。
	# 手搓地形这行等于什么都不做 —— 契约里的默认实现。
	if int(node.name) == multiplayer.get_unique_id():
		terrain.attach_viewer(node as Node3D)
	# 装备重放：装备 RPC 可能比玩家节点先到，这里补一次（幂等）。
	# 对所有人都要做 —— 否则看不到别人手里的枪。
	if shop != null and node is Node3D:
		shop.replay(node as Node3D)


func _on_player_removed(node: Node) -> void:
	print("[S3] 玩家 %s 离开世界" % node.name)
	# 断线这一刻记快照：节点马上要被 free，之后就问不到了。
	# 不用"每秒记录"是因为那会写很多无用数据，而"最后位置"在离开时最准确。
	if multiplayer.is_server() and node is Node3D:
		_last_pos[int(node.name)] = (node as Node3D).global_position


# ------------------------------------------------------------
# 菜单交互
# ------------------------------------------------------------
func _on_host_pressed() -> void:
	Net.host()


func _on_join_pressed() -> void:
	# 先把节点取成具体类型，再读属性。
	# 直接写 $Menu/.../IpEdit.text 会得到 Variant，`:=" 推断不出类型就会报解析错误
	var edit: LineEdit = $Menu/Center/VBox/IpEdit
	var ip: String = edit.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	status.text = "正在连接 %s …" % ip
	Net.join(ip)


# ------------------------------------------------------------
# S9 · 靶子（临时，S10 换成真正的丧尸）
# ------------------------------------------------------------
### 摆在玩家前方、朝向城镇广场的空地上，保证不卡进建筑
func _spawn_targets() -> void:
	var me: Node3D = players.get_node_or_null("1")
	if me == null:
		return
	var base := me.global_position
	var center := town.main_center()
	var dir := center - base
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.5 else Vector3(0, 0, -1)
	var right := dir.cross(Vector3.UP).normalized()

	for i in 3:
		var dist := 8.0 + float(i) * 5.0
		var side := (float(i) - 1.0) * 3.2
		var p := base + dir * dist + right * side
		p.y = terrain.height_at(p.x, p.z) + 0.05
		var t := TARGET_SCENE.instantiate()
		t.position = p
		targets.add_child(t)
	print("[S9] 靶子就位：3 个（8m / 13m / 18m）")


# ------------------------------------------------------------
# S11 · 拾荒：容器布置 + 丧尸掉落
# ------------------------------------------------------------
## 布置用的随机种子是**固定**的。
##
## ★ 为什么不做成每局随机：
##   拾荒地图需要被玩家"记住"——"广场东边那两个箱子有急救包"是一种知识，
##   而知识是重复游玩的动力。每局重排的话，玩家永远在瞎跑。
##   真正该随机的是**箱子里有什么**（loot_seed 每次不同），
##   不是箱子在哪。位置固定 = 可学习的路线，内容随机 = 每次都有期待。
const LOOT_LAYOUT_SEED := 20261112

func _spawn_loot_containers() -> void:
	if loot == null or loot.get_child_count() > 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = LOOT_LAYOUT_SEED

	# 出生点附近三个：教玩家"这里有东西可以搜"。
	# 不放太多 —— 出生点不该是补给站，那会让人一辈子不往远处走
	var me: Node3D = players.get_node_or_null("1")
	if me != null:
		for i in 3:
			var ang := rng.randf() * TAU
			var r := rng.randf_range(5.0, 11.0)
			_place_container(me.global_position + Vector3(cos(ang) * r, 0, sin(ang) * r), rng)

	# 城镇广场周围五个：值得跑一趟的目标
	var center: Vector3 = town.main_center()
	for i in 5:
		var ang := TAU * float(i) / 5.0 + rng.randf_range(-0.28, 0.28)
		var r := rng.randf_range(9.0, 17.0)
		_place_container(center + Vector3(cos(ang) * r, 0, sin(ang) * r), rng)

	print("[S11] 拾荒容器就位：%d 个" % loot.get_child_count())


func _place_container(xz: Vector3, rng: RandomNumberGenerator) -> void:
	# 高度必须问地形契约，不要自己算（TerrainBase 是唯一真相源）
	var y := terrain.height_at(xz.x, xz.z)
	var c := LOOT_CONTAINER_SCENE.instantiate()
	c.position = Vector3(xz.x, y + 0.02, xz.z)
	c.rotation.y = rng.randf() * TAU
	# ★ 每个箱子一个独立种子：共用同一个种子会让所有箱子出一模一样的东西，
	#   玩家搜第一个就知道后面所有箱子里是什么
	c.loot_seed = rng.randi()
	if rng.randf() < 0.3:
		c.title = "铁柜"
	loot.add_child(c)


### 在指定位置放一堆掉落物
func _spawn_loot_at(pos: Vector3, item_id: String, count: int) -> void:
	if loot == null or count <= 0:
		return
	var d := LOOT_DROP_SCENE.instantiate()
	d.item_id = item_id
	d.amount = count
	# 抬高 0.05 避免和地面 z-fighting；掉落物自己还有浮动动画
	d.position = Vector3(pos.x, pos.y + 0.05, pos.z)
	loot.add_child(d)


### 丧尸死亡回调（由 zombie.died 信号触发，只在服务器）
##
## ★ 为什么让 world 接信号、而不是让 zombie 自己生成掉落物：
##   zombie 一旦开始 new 掉落物，它就得知道掉落表、知道 Loot 容器在哪、
##   知道物品定义 —— 一个"会走会咬的东西"不该背这些。
##   信号把"我死了"和"死了之后世界怎么反应"拆开，
##   以后加"死亡任务计数""成就""尸潮进度"都挂在这个信号上，不动 zombie 一行。
func _on_zombie_died(zb: Node3D) -> void:
	if not multiplayer.is_server() or not is_instance_valid(zb):
		return
	# 不是每只都掉：70% 掉落，让"这只掉东西了"有一点意外感。
	# 100% 掉落会把尸体变成自动贩卖机，玩家会开始"刷丧尸"
	if randf() > 0.70:
		return
	var drop := ItemDef.roll_from(ItemDef.ZOMBIE_DROPS)
	if drop.is_empty():
		return
	_spawn_loot_at(zb.global_position, String(drop["id"]), int(drop["count"]))


# ------------------------------------------------------------
# S10 · 丧尸刷新（只在服务器）
# ------------------------------------------------------------
## 为什么要"定时补"而不是"一次性摆满"：
## 一次性摆满之后，玩家清完就再也遇不到敌人，世界会突然变空。
## 定时补位让"危险"变成持续的，但也留了喘息时间 —— 这个间隔就是节奏。
func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	_zombie_timer -= delta
	if _zombie_timer > 0.0:
		return
	_zombie_timer = ZOMBIE_SPAWN_INTERVAL
	if zombies.get_child_count() >= MAX_ZOMBIES:
		return
	_spawn_zombie_near()


func _spawn_zombie_near() -> void:
	var who := _pick_player()
	if who == null:
		return
	var ang := randf() * TAU
	var r := randf_range(ZOMBIE_SPAWN_MIN, ZOMBIE_SPAWN_MAX)
	var x := who.global_position.x + cos(ang) * r
	var z := who.global_position.z + sin(ang) * r
	# 高度必须问同一份地形（TerrainBase 契约）。自己算一份就是第二个真相源，
	# 之前踩过：地形和生成各写一套高度公式，丧尸半截埋进山里
	var y := terrain.height_at(x, z)
	var zb := ZOMBIE_SCENE.instantiate()
	zb.position = Vector3(x, y + 0.3, z)
	# 用 bind 把"是哪一只"带进回调：died 本身不带参数，
	# 而掉落物需要知道死在哪 —— 这就是 bind 的用途（预绑定参数）
	zb.died.connect(_on_zombie_died.bind(zb))
	zombies.add_child(zb)


func _pick_player() -> Node3D:
	for n in get_tree().get_nodes_in_group("players"):
		if n is Node3D and is_instance_valid(n) and n.get("dead") != true:
			return n as Node3D
	return null


