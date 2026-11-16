extends Node
## 无头验收探针
##
## 为什么要这个东西：这个工程没法靠"看"来验收 —— 截图权限被系统拦着，
## 而"我觉得应该对了"不算证据。探针让每个阶段都有一条可复现的命令，
## 输出以 `[TEST]` 开头，失败时用非零退出码，shell 能直接判。
##
## 用法：
##   tools/Godot.app/Contents/MacOS/Godot --headless --path game -- --server --selftest input

var _tree: SceneTree
const STEP_TOL := 0.30      # 单步允许的最大高差（玩家台阶辅助能迈 0.35）


func run(test_name: String) -> void:
	_tree = get_tree()
	match test_name:
		"input":
			_test_input()
		"slots":
			_test_slots()
		"knife":
			_test_knife()
		"layout":
			_test_layout()
		"town":
			_test_town()
		"spawn":
			_test_spawn()
		"porch":
			_test_porch()
		"shop":
			_test_shop()
		"hostbuy":
			_test_hostbuy()
		"equipjoin":
			_test_equipjoin()
		"shoot":
			_test_shoot()
		"sfx":
			_test_sfx()
		"combat":
			_test_combat()
		"loot":
			_test_loot()
		"shot":
			_shot()
		"knifeshot":
			_knifeshot()
		_:
			print("[TEST] 未知测试：%s" % test_name)
			_finish(true)


# ------------------------------------------------------------
# 输入锁：两个 UI 同时开，关一个不能把另一个也放开
# ------------------------------------------------------------
func _test_input() -> void:
	var seq := []
	seq.append(GameState.ui_captures_input)          # 初始：false
	GameState.claim_ui("chat")
	seq.append(GameState.ui_captures_input)          # 聊天开：true
	GameState.claim_ui("shop")
	seq.append(GameState.ui_captures_input)          # 两个都开：true
	GameState.release_ui("chat")
	seq.append(GameState.ui_captures_input)          # 只关聊天：仍然 true（旧实现这里会变 false）
	GameState.release_ui("shop")
	seq.append(GameState.ui_captures_input)          # 都关：false

	print("[TEST] 输入锁时序=%s" % [seq])
	print("[TEST] 期望=[false, true, true, true, false]")
	var ok: bool = seq == [false, true, true, true, false]

	# 键位映射：新增切枪/检视动作，手电从 F 挪到 L。
	# 这里查 physical_keycode，而不是 keycode —— 玩家换键盘布局时物理键位不该漂移。
	var expected := {
		"slot_primary": 49,   # 1
		"slot_knife": 51,     # 3
		"last_weapon": 81,    # Q
		"inspect": 70,        # F
		"flashlight": 76,     # L
	}
	var keys_ok := true
	for action in expected.keys():
		var code := int(expected[action])
		if not InputMap.has_action(action):
			print("[TEST] 缺少动作=%s" % action)
			keys_ok = false
			continue
		var found := false
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey and ev.physical_keycode == code:
				found = true
				break
		if not found:
			print("[TEST] 动作键位不符=%s 期望=%d" % [action, code])
			keys_ok = false
	print("[TEST] 键位映射=%s" % keys_ok)

	_finish(ok and keys_ok)


# ------------------------------------------------------------
# 武器槽：1/3/Q 的切换顺序、拉刀锁、取消、换弹打断
# ------------------------------------------------------------
func _test_slots() -> void:
	var world := get_parent()
	var player = null
	for i in 80:
		player = world.get_node_or_null("Players/1")
		if player != null:
			break
		await _tree.create_timer(0.05).timeout
	if player == null:
		print("[TEST] 玩家没生成")
		_finish(false)
		return

	for i in 4:
		await _tree.physics_frame

	var c: Combat = player.combat
	var ok := true

	print("[TEST] 初始槽位=%s（期望 AK47）" % c.slot_label())
	if c.current_slot != Combat.Slot.PRIMARY:
		ok = false

	# 1 → 3：收枪 0.30s，再拉刀 0.45s；整段不能攻击
	c.switch_to(Combat.Slot.KNIFE)
	print("[TEST] 切刀开始：锁定=%s 可攻击=%s" % [
		str(c.is_switching()), str(c.can_attack())])
	if not c.is_switching() or c.can_attack():
		ok = false

	await _tree.create_timer(0.36).timeout
	print("[TEST] 0.36s：当前=%s 仍在拉刀=%s（期望 蝴蝶刀 / true）" % [
		c.slot_label(), str(c.is_switching())])
	if c.current_slot != Combat.Slot.KNIFE or not c.is_switching():
		ok = false

	await _tree.create_timer(0.50).timeout
	print("[TEST] 0.86s：当前=%s 切换完成=%s last=%s" % [
		c.slot_label(), str(not c.is_switching()), c.slot_label(c.last_slot)])
	if c.current_slot != Combat.Slot.KNIFE or c.is_switching():
		ok = false
	if c.last_slot != Combat.Slot.PRIMARY:
		ok = false

	# Q：回到上一把（AK47）
	c.switch_to(c.last_slot)
	await _tree.create_timer(0.80).timeout
	print("[TEST] Q 切回：当前=%s last=%s（期望 AK47 / 蝴蝶刀）" % [
		c.slot_label(), c.slot_label(c.last_slot)])
	if c.current_slot != Combat.Slot.PRIMARY or c.is_switching():
		ok = false
	if c.last_slot != Combat.Slot.KNIFE:
		ok = false

	# 切到一半按 1：取消，立刻回到 AK47
	c.switch_to(Combat.Slot.KNIFE)
	var cancelled := c.switch_to(Combat.Slot.PRIMARY)
	print("[TEST] 切到一半按 1：取消=%s 当前=%s 锁定=%s" % [
		str(cancelled), c.slot_label(), str(c.is_switching())])
	if not cancelled or c.is_switching() or c.current_slot != Combat.Slot.PRIMARY:
		ok = false

	# 取消后 Q 仍然要能切到另一把（last_slot 不能停在过期值上）
	c.switch_to(c.last_slot)
	await _tree.create_timer(0.80).timeout
	print("[TEST] 取消后按 Q：当前=%s（期望 蝴蝶刀）" % c.slot_label())
	if c.current_slot != Combat.Slot.KNIFE or c.is_switching():
		ok = false
	c.switch_to(Combat.Slot.PRIMARY)
	await _tree.create_timer(0.80).timeout

	# 换弹中切枪：换弹必须被打断
	c.weapon.ammo = 1
	c.reload()
	var reload_started := c.weapon.reloading
	c.switch_to(Combat.Slot.KNIFE)
	print("[TEST] 换弹中切枪：开始=%s 切后仍在换弹=%s" % [
		str(reload_started), str(c.weapon.reloading)])
	if not reload_started or c.weapon.reloading:
		ok = false

	_finish(ok)


# ------------------------------------------------------------
# 刀战：轻击 3 刀、重击 2 刀、背刺 1 刀
# ------------------------------------------------------------
func _test_knife() -> void:
	var world := get_parent()
	var player = null
	for i in 80:
		player = world.get_node_or_null("Players/1")
		if player != null:
			break
		await _tree.create_timer(0.05).timeout
	if player == null:
		print("[TEST] 玩家没生成")
		_finish(false)
		return

	for i in 4:
		await _tree.physics_frame

	var c: Combat = player.combat
	var targets: Node3D = world.get_node("Targets")
	for child in targets.get_children():
		child.queue_free()
	for i in 3:
		await _tree.physics_frame

	var ok := true
	c.switch_to(Combat.Slot.KNIFE)
	await _tree.create_timer(0.85).timeout
	print("[TEST] 刀槽就绪：当前=%s 切换中=%s" % [
		c.slot_label(), str(c.is_switching())])
	if c.current_slot != Combat.Slot.KNIFE or c.is_switching():
		ok = false

	var forward: Vector3 = -player.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var origin: Vector3 = player.global_position + Vector3.UP

	# ---- 1. 轻击 40，三刀杀 100 血 ----
	var light := _spawn_knife_target(targets,
		player.global_position + forward * 1.5, player.rotation.y + PI)
	await _tree.physics_frame
	await _tree.physics_frame
	var hp0: float = light.hp
	c.knife.cooldown = 0.0
	c._server_knife_start(false, origin, forward)
	var dmg_light: float = hp0 - light.hp
	print("[TEST] 轻击伤害=%.0f（期望 40）" % dmg_light)
	if absf(dmg_light - 40.0) > 1.0:
		ok = false
	for i in 2:
		c.knife.cooldown = 0.0
		c._server_knife_start(false, origin, forward)
	print("[TEST] 三轻击后 dead=%s hp=%.0f（期望 true / <=0）" % [
		str(light.dead), light.hp])
	if not light.dead:
		ok = false
	light.queue_free()
	await _tree.physics_frame

	# ---- 2. 重击 90，两刀杀 100 血 ----
	var heavy := _spawn_knife_target(targets,
		player.global_position + forward * 1.5, player.rotation.y + PI)
	await _tree.physics_frame
	await _tree.physics_frame
	var hp1: float = heavy.hp
	c.knife.cancel_pending()
	c.knife.cooldown = 0.0
	c._server_knife_start(true, origin, forward)
	await _tree.create_timer(0.50).timeout
	var dmg_heavy: float = hp1 - heavy.hp
	print("[TEST] 重击伤害=%.0f（期望 90）" % dmg_heavy)
	if absf(dmg_heavy - 90.0) > 1.0:
		ok = false
	c.knife.cancel_pending()
	c.knife.cooldown = 0.0
	c._server_knife_start(true, origin, forward)
	await _tree.create_timer(0.50).timeout
	print("[TEST] 两重击后 dead=%s hp=%.0f（期望 true / <=0）" % [
		str(heavy.dead), heavy.hp])
	if not heavy.dead:
		ok = false
	heavy.queue_free()
	await _tree.physics_frame

	# ---- 3. 背刺 180：目标背对玩家 ----
	var back := _spawn_knife_target(targets,
		player.global_position + forward * 1.5, player.rotation.y, 300.0)
	await _tree.physics_frame
	await _tree.physics_frame
	var hp2: float = back.hp
	c.knife.cancel_pending()
	c.knife.cooldown = 0.0
	c._server_knife_start(true, origin, forward)
	await _tree.create_timer(0.50).timeout
	var dmg_back: float = hp2 - back.hp
	print("[TEST] 背刺伤害=%.0f（期望 180）" % dmg_back)
	if absf(dmg_back - 180.0) > 1.0:
		ok = false
	back.queue_free()

	_finish(ok)


func _spawn_knife_target(parent: Node3D, pos: Vector3, yaw: float,
		max_hp := 100.0) -> TargetDummy:
	var t: TargetDummy = load("res://scenes/target.tscn").instantiate()
	t.max_hp = max_hp
	parent.add_child(t)
	t.global_position = pos
	t.rotation.y = yaw
	return t


# ------------------------------------------------------------
# 刀视图截图：待机 / 检视 / 轻击
# ------------------------------------------------------------
func _knifeshot() -> void:
	for i in 30:
		await _tree.process_frame

	var player := get_parent().get_node_or_null("Players/1")
	if player == null:
		print("[TEST] 玩家没生成")
		_finish(false)
		return

	player.set("_pitch", 0.0)
	var head := player.get_node_or_null("Head")
	if head != null:
		head.rotation.x = 0.0

	player.rotation.y = 0.0
	var c: Combat = player.combat
	c.switch_to(Combat.Slot.KNIFE)
	await _tree.create_timer(0.50).timeout
	var wv = player.get_node("Head/Camera3D/WeaponView")
	var kv_dbg = player.get_node("Head/Camera3D/KnifeView")
	print("[TEST] WeaponView visible=%s in_tree=%s / KnifeView visible=%s in_tree=%s" % [
		str(wv.visible), str(wv.is_visible_in_tree()),
		str(kv_dbg.visible), str(kv_dbg.is_visible_in_tree())])
	await RenderingServer.frame_post_draw
	var draw_img := _tree.root.get_viewport().get_texture().get_image()
	draw_img.save_png("/tmp/knife_draw.png")
	await _tree.create_timer(0.40).timeout
	for i in 8:
		await _tree.process_frame

	await RenderingServer.frame_post_draw
	var img := _tree.root.get_viewport().get_texture().get_image()
	var err := img.save_png("/tmp/knife_idle.png")
	if err != OK:
		print("[TEST] 待机截图失败 err=%d" % err)
		_finish(false)
		return
	print("[TEST] 待机截图 /tmp/knife_idle.png")

	# 诊断用：把刀单独藏起来，确认右下角没有别的视图残留
	kv_dbg.visible = false
	for i in 3:
		await _tree.process_frame
	await RenderingServer.frame_post_draw
	var hidden_img := _tree.root.get_viewport().get_texture().get_image()
	hidden_img.save_png("/tmp/knife_hidden.png")
	kv_dbg.visible = true

	var kv = player.get("knife_view")
	if kv != null:
		kv.call("play_inspect")
	await _tree.create_timer(0.52).timeout
	await RenderingServer.frame_post_draw
	img = _tree.root.get_viewport().get_texture().get_image()
	err = img.save_png("/tmp/knife_inspect.png")
	print("[TEST] 检视截图 /tmp/knife_inspect.png err=%d" % err)

	if kv != null:
		kv.call("play_attack", false)
	await _tree.create_timer(0.14).timeout
	await RenderingServer.frame_post_draw
	img = _tree.root.get_viewport().get_texture().get_image()
	err = img.save_png("/tmp/knife_slash.png")
	print("[TEST] 轻击截图 /tmp/knife_slash.png err=%d" % err)

	_finish(err == OK)


# ------------------------------------------------------------
# 城镇布局：同一地形跑两次，指纹必须完全一致
# ------------------------------------------------------------
func _test_layout() -> void:
	var terrain: TerrainBase = get_parent().get_node("Terrain")
	var a := TownGenerator.generate(terrain)
	var b := TownGenerator.generate(terrain)
	var da := TownGenerator.digest(a)
	var db := TownGenerator.digest(b)

	print("[TEST] 一次生成=%s" % da)
	print("[TEST] 二次生成=%s" % db)

	var buildings := 0
	for p in a:
		buildings += p.buildings.size()
	print("[TEST] 城镇数=%d 建筑数=%d" % [a.size(), buildings])
	for p in a:
		print("[TEST]   %s 商店=%s" % [p.describe(), str(p.shop_position.is_finite())])
		for s in p.buildings:
			print("[TEST]     %s" % s.describe())

	var ok: bool = da == db and a.size() == 3 and buildings >= 10
	if da != db:
		push_error("[TEST] 两次生成不一致 —— 生成器里有非确定性因素")
	_finish(ok)


# ------------------------------------------------------------
# 建筑：碰撞盒数量、门口有没有地板、楼梯坡面在不在
# ------------------------------------------------------------
func _test_town() -> void:
	var world := get_parent()
	var town: TownBuilder = world.get_node("Town")
	# 刚 add_child 的碰撞形状要等一个物理帧才进物理空间，
	# 立刻打射线会"什么都打不到"—— 这是无头测试最常见的假失败
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state

	var total: int = town.buildings.size()
	var shapes := 0
	var min_shapes := 999999
	var door_ok := 0
	var stair_ok := 0

	for b in town.buildings:
		var s: BuildingSpec = b.spec
		var c := b.collision_count()
		shapes += c
		min_shapes = mini(min_shapes, c)

		# 门口：从门外 1 米、门洞高度（基座顶 +1.1 米）水平打进去。
		# 门开着 → 穿过门洞打到屋内深处（距离 > 3 米）
		# 门是实墙 → 2 米处就被挡住
		# 这比"向下打看有没有地板"更贴近真实需求：我们要的是"能不能走进去"。
		var n := s.door_world_normal()
		var outside := s.door_outside()
		var start := Vector3(outside.x, s.plinth_top + 1.1, outside.z) + n * 1.0
		var q := PhysicsRayQueryParameters3D.create(start, start - n * 10.0)
		var hit := space.intersect_ray(q)
		var dist := 999.0
		if not hit.is_empty():
			dist = start.distance_to(hit.position)
		if dist >= 3.0:
			door_ok += 1
		else:
			print("[TEST]   门洞不通 yaw=%d door=%d 距离=%.2f 起点=(%.1f,%.1f,%.1f)" % [
				s.yaw_deg, s.door_dir, dist, start.x, start.y, start.z])

		# 楼梯：坡道中点上方打，应该打在 36° 的坡面上
		var local := Vector3(-s.size.x * 0.5 + 1.2, s.plinth_top + s.floor_h * 0.5, 0.0)
		var wp: Vector3 = b.global_transform * local
		var q2 := PhysicsRayQueryParameters3D.create(wp + Vector3.UP * 2.0, wp + Vector3.DOWN * 6.0)
		if not space.intersect_ray(q2).is_empty():
			stair_ok += 1

	print("[TEST] 建筑=%d 碰撞盒=%d 最少单栋=%d" % [total, shapes, min_shapes])
	print("[TEST] 门口有地面=%d/%d 楼梯有碰撞=%d/%d" % [door_ok, total, stair_ok, total])
	_finish(total >= 10 and min_shapes >= 20 and door_ok == total and stair_ok == total)


# ------------------------------------------------------------
# 出生点与禁建区
# ------------------------------------------------------------
func _test_spawn() -> void:
	var world := get_parent()
	var town: TownBuilder = world.get_node("Town")
	var main := town.main_center()

	var p1: Vector3 = world._spawn_position_for(1)
	var p2: Vector3 = world._spawn_position_for(2)
	var d1 := Vector2(p1.x - main.x, p1.z - main.z).length()
	var d12 := Vector2(p1.x - p2.x, p1.z - p2.z).length()

	# 模拟"上次在哨站附近"
	var outpost: Vector3 = town.plans[1].center
	world._last_pos[77] = outpost + Vector3(5, 0, 5)
	var p3: Vector3 = world._spawn_position_for(77)
	var d3 := Vector2(p3.x - outpost.x, p3.z - outpost.z).length()

	var blocked_center: bool = town.is_build_blocked(main)
	var blocked_far: bool = town.is_build_blocked(main + Vector3(80, 0, 0))

	print("[TEST] 首次出生=%s 距主城中心=%.1f" % [str(p1.round()), d1])
	print("[TEST] 第二人出生=%s 与第一人相距=%.1f" % [str(p2.round()), d12])
	print("[TEST] 就近上次=%s 距哨站=%.1f" % [str(p3.round()), d3])
	print("[TEST] 禁建：主城中心=%s 80米外=%s" % [str(blocked_center), str(blocked_far)])

	var ok: bool = d1 < 30.0 and d12 > 0.5 and blocked_center and not blocked_far and d3 < 40.0
	_finish(ok)


# ------------------------------------------------------------
# 商店：能买、远处不能买、非法 id 不能买
# ------------------------------------------------------------
func _test_shop() -> void:
	var world := get_parent()
	var town: TownBuilder = world.get_node("Town")
	var shop = world.get_node("ShopService")
	var npc := town.npc_position()

	await get_tree().physics_frame
	var p := world.get_node_or_null("Players/1") as Node3D
	if p == null:
		print("[TEST] 找不到玩家节点 Players/1（要用 --server 运行）")
		_finish(false)
		return

	# 把玩家挪到 NPC 旁边（正常游玩时是走过去的）
	p.global_position = npc + Vector3(0, 1.0, 1.6)
	await get_tree().physics_frame

	shop._server_buy(1, 2)
	await get_tree().process_frame
	var eq: int = shop.equipment_of(1)
	var hand := p.get_node_or_null("HandItem")
	var parts := 0
	if hand != null:
		parts = int(hand.part_count())

	# 跑到 200 米外再买
	p.global_position = npc + Vector3(200, 0, 0)
	await get_tree().physics_frame
	shop._server_buy(1, 3)
	await get_tree().process_frame
	var eq_far: int = shop.equipment_of(1)

	# 非法 id
	shop._server_buy(1, 999)
	await get_tree().process_frame
	var eq_bad: int = shop.equipment_of(1)

	print("[TEST] 购买成功 item=%d 手里部件=%d" % [eq, parts])
	print("[TEST] 200 米外购买后仍是 %d（应为 2）" % eq_far)
	print("[TEST] 非法 id 后仍是 %d（应为 2）" % eq_bad)

	_finish(eq == 2 and parts == 3 and eq_far == 2 and eq_bad == 2)


# ------------------------------------------------------------
# 主机先买一把枪，然后保持在线（供客户端加入观察）
# ------------------------------------------------------------
func _test_hostbuy() -> void:
	var world := get_parent()
	var town: TownBuilder = world.get_node("Town")
	var shop = world.get_node("ShopService")
	await get_tree().physics_frame
	var p := world.get_node_or_null("Players/1") as Node3D
	if p == null:
		print("[TEST] 主机没有玩家节点")
		_finish(false)
		return
	p.global_position = town.npc_position() + Vector3(0, 1.0, 1.6)
	await get_tree().physics_frame
	shop._server_buy(1, 3)
	await get_tree().process_frame
	print("[TEST] 主机已装备 item=%d，保持在线等待客户端…" % int(shop.equipment_of(1)))
	# 故意不 quit：主机要活着，客户端才有东西可看。
	# world.gd 里有 30 秒保险丝，到点会自己退出。


# ------------------------------------------------------------
# 客户端中途加入：应当立刻看到主机手里的枪（靠快照重放）
# ------------------------------------------------------------
func _test_equipjoin() -> void:
	var world := get_parent()
	await get_tree().create_timer(4.0).timeout

	var players := world.get_node("Players")
	var my := str(multiplayer.get_unique_id())
	var with_gun := 0
	for c in players.get_children():
		var hand := c.get_node_or_null("HandItem")
		var parts := 0
		if hand != null:
			parts = int(hand.part_count())
		if c.name == my:
			print("[TEST] 我（%s）手里部件=%d" % [c.name, parts])
		else:
			print("[TEST] 远端玩家 %s 手里部件=%d" % [c.name, parts])
			if parts > 0:
				with_gun += 1

	print("[TEST] 看到持枪的远端玩家=%d" % with_gun)
	_finish(with_gun >= 1)


# ------------------------------------------------------------
# 门廊可走性：真放一个胶囊，从台阶下面往上走，看能不能**不跳**走进楼
# ------------------------------------------------------------
## 这是本轮最该有的一个测试。
## 之前"门口能不能穿过去"用的是射线 —— 射线只证明"门洞没有墙"，
## 证明不了"人能走上去"。而玩家反馈的恰恰是后者：得跳。
##
## 做法：造一个 CharacterBody3D + 真胶囊，每帧给一个朝门内的速度并 move_and_slide，
## 跑 1.5 秒后看它有没有站到楼板高度、且真的在楼里。
func _test_porch() -> void:
	var world := get_parent()
	var town: TownBuilder = world.get_node("Town")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var sp: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state

	var total := town.buildings.size()
	var ok_count := 0
	var worst := 0.0
	var worst_desc := ""

	for b in town.buildings:
		var s: BuildingSpec = b.spec
		var n := s.door_world_normal()
		var face: float = absf(n.x) * s.size.x * 0.5 + absf(n.z) * s.size.y * 0.5
		var start_d := face + s.porch_depth + s.porch_reach + 1.5

		# 沿门的方向，从门外 1.5 米处一路走到门内 1.2 米，每 0.2 米打一条向下的射线。
		# 判据：相邻两点的地面高差 ≤ STEP_TOL —— 这就是"人能不能走上去"。
		# 为什么不放一个胶囊去走：CharacterBody 会因自身穿透、贴地吸附等一堆因素
		# 卡在莫名其妙的地方，测出来的是"探针的行为"，不是"地形的可走性"。
		var prev_y := NAN
		var max_step := 0.0
		var max_at := 0.0
		var d := start_d
		while d > face - 1.2:
			var px: float = s.center.x + n.x * d
			var pz: float = s.center.z + n.z * d
			# 起点只比楼板高 0.4 米：从更高处打会先打到屋顶/雨棚，测出来的是屋顶高度
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(px, s.plinth_top + 0.4, pz),
				Vector3(px, s.plinth_top - 12.0, pz))
			var h := sp.intersect_ray(q)
			# 打空的时候必须把 prev_y 复位成 NaN，否则"上一个点没打到(-99) → 这个点打到"
			# 会算出一个 100 多米的假落差（第一版就这么误报了三栋楼）
			if h.is_empty():
				prev_y = NAN
			else:
				var y: float = h.position.y
				if not is_nan(prev_y):
					var step := absf(y - prev_y)
					if step > max_step:
						max_step = step
						max_at = d
				prev_y = y
			d -= 0.2

		if max_step > worst:
			worst = max_step
			worst_desc = "%s 在 d=%.1f 处落差 %.2f" % [s.describe(), max_at, max_step]
		if max_step <= STEP_TOL:
			ok_count += 1
		else:
			print("[TEST]   走不上去 %s 最大落差=%.2f（d=%.1f）落台阶长=%.1f" % [
				s.describe(), max_step, max_at, s.porch_reach])

	print("[TEST] 门口可走（单步 ≤%.2f 米）：%d/%d ｜ 最大落差 %.2f 米 @ %s" % [
		STEP_TOL, ok_count, total, worst, worst_desc])
	_finish(ok_count == total)



# ------------------------------------------------------------
# S9 · 射击：伤害 / 爆头倍率 / 射速限流 / 换弹 / 扩散 / 推击
# ------------------------------------------------------------
### 为什么全用 `_server_fire` 而不是模拟鼠标点击：
##   模拟输入要经过 Input 状态机、鼠标捕获状态、窗口焦点，
##   任何一环在无头模式下不成立，测试就会"时好时坏"。
##   直接调权威函数，测的是**判定逻辑本身** —— 这才是我们想锁住的东西。
func _test_shoot() -> void:
	var world := get_parent()
	var player = null
	var targets: Array = []
	for i in 80:
		player = world.get_node_or_null("Players/1")
		var tn := world.get_node_or_null("Targets")
		if player != null and tn != null and tn.get_child_count() > 0:
			targets = tn.get_children()
			break
		await _tree.create_timer(0.05).timeout

	if player == null or targets.is_empty():
		print("[TEST] 玩家或靶子没生成")
		_finish(false)
		return

	# ★ 必须等物理服务器把靶子的碰撞体注册进来。
	#   节点 add_child 之后，碰撞形状要等到下一个 physics frame 才进空间 ——
	#   这段时间里射线什么都打不到，而"节点已经存在"又骗过了上面的等待循环。
	#   症状很典型：第一次射击伤害 0，后面的射击正常。
	#
	#   0.30s 而不是 0.12s：这段时间要覆盖"玩家出生 → 武器外观构建 → 碰撞体注册"。
	#   给 AK 加了噪声贴图之后构建变慢，0.12s 就不够了 ——
	#   这就是为什么"等固定时长"很脆，等不够就会偶发失败。
	for i in 4:
		await _tree.physics_frame
	await _tree.create_timer(0.30).timeout

	var combat = player.get_node("Combat")
	var cam: Camera3D = player.view_camera()
	var t = targets[0]
	var ok := true

	# ---- 1. 身体命中 ----
	var hp0: float = t.hp
	var ammo0: int = combat.weapon.ammo
	# 瞄上胸而不是腰：坡地上 8 米外的低处射线会先撞到地形（实测踩过）
	var aim_body: Vector3 = t.global_position + Vector3(0, 1.20, 0)
	combat._server_fire(cam.global_position, (aim_body - cam.global_position).normalized())
	await _tree.create_timer(0.20).timeout
	var dmg_body: float = hp0 - t.hp
	var used: int = ammo0 - combat.weapon.ammo
	print("[TEST] 身体命中：伤害=%.1f 扣弹=%d（期望 34 / 1）" % [dmg_body, used])
	if dmg_body < 1.0:
		var sp: PhysicsDirectSpaceState3D = (player as Node3D).get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(cam.global_position,
			cam.global_position + (aim_body - cam.global_position).normalized() * 60.0)
		q.collision_mask = Layers.HURT_MASK
		q.exclude = [(player as CollisionObject3D).get_rid()]
		var h := sp.intersect_ray(q)
		print("[TEST]   诊断：射线命中=%s" % ("空" if h.is_empty() else str(h["collider"].name)))
	ok = ok and absf(dmg_body - 34.0) < 1.0 and used == 1

	# ---- 2. 爆头 ----
	var hp1: float = t.hp
	var aim_head: Vector3 = t.global_position + Vector3(0, 1.75, 0)
	combat._server_fire(cam.global_position, (aim_head - cam.global_position).normalized())
	await _tree.create_timer(0.20).timeout
	var dmg_head: float = hp1 - t.hp
	print("[TEST] 爆头伤害=%.1f（期望 %.1f，倍率 %.1f）" % [
		dmg_head, 34.0 * 2.4, dmg_head / maxf(0.01, dmg_body)])
	ok = ok and dmg_head > dmg_body * 1.8

	# ---- 3. 射速限流：连调两次，只应该扣一发 ----
	await _tree.create_timer(0.20).timeout
	var a0: int = combat.weapon.ammo
	combat._server_fire(cam.global_position, (aim_body - cam.global_position).normalized())
	combat._server_fire(cam.global_position, (aim_body - cam.global_position).normalized())
	await _tree.create_timer(0.05).timeout
	var a1: int = combat.weapon.ammo
	print("[TEST] 射速限流：连打 2 次扣 %d 发（期望 1，间隔 0.10s）" % (a0 - a1))
	ok = ok and (a0 - a1) == 1

	# ---- 4. 扩散：站着 vs 冲刺 ----
	var w = combat.weapon
	var s_still: float = w.spread_deg(0.0, true)
	var s_run: float = w.spread_deg(8.5, true)
	var s_air: float = w.spread_deg(0.0, false)
	print("[TEST] 扩散：站立=%.2f° 冲刺=%.2f° 空中=%.2f°" % [s_still, s_run, s_air])
	ok = ok and s_run > s_still and s_air > s_still

	# ---- 5. 换弹 ----
	combat.weapon.ammo = 3
	combat.reload()
	var reload_started: bool = combat.weapon.reloading
	await _tree.create_timer(2.70).timeout
	print("[TEST] 换弹：开始=%s 结束后 %d 发（期望 true / 30）" % [str(reload_started), combat.weapon.ammo])
	ok = ok and reload_started and combat.weapon.ammo == 30

	# ---- 6. 推击：站到靶子旁边推一下 ----
	var save_pos := (player as Node3D).global_position
	var save_yaw: float = (player as Node3D).rotation.y
	var to_t: Vector3 = t.global_position - save_pos
	to_t.y = 0.0
	to_t = to_t.normalized()
	(player as Node3D).global_position = t.global_position - to_t * 1.2 + Vector3.UP * 0.2
	# ★ 推击的扇形是沿"身体朝向"判定的，所以必须先把人转向靶子。
	#   前面几项测试都是直接给方向向量，不需要朝向 —— 这一项需要。
	(player as Node3D).rotation.y = atan2(-to_t.x, -to_t.z)
	await _tree.create_timer(0.10).timeout
	t.last_knockback = 0.0
	combat.shove()
	await _tree.create_timer(0.05).timeout
	print("[TEST] 推击力度=%.1f（期望 > 0，说明扇形判定命中）" % t.last_knockback)
	ok = ok and t.last_knockback > 0.0
	(player as Node3D).global_position = save_pos
	(player as Node3D).rotation.y = save_yaw

	_finish(ok)


# ------------------------------------------------------------
# 音效：程序合成的流是否真的有内容
# ------------------------------------------------------------
### 无头模式听不到声音，但可以验证"生成出来了、长度对、不是静音"。
## 这一步很值：合成代码里一个写错的下标就会产出全零缓冲区 ——
## 游戏里表现为"开枪没声音"，而且完全不报错。
func _test_sfx() -> void:
	var names := ["shot_rifle", "hit_flesh", "hit_head", "hit_wall",
		"dry_fire", "reload_out", "reload_in", "shove", "shell_drop", "zombie_die"]
	var ok := true
	for n in names:
		var st = Sfx.call("_stream_for", n)
		if st == null:
			print("[TEST] %s 生成失败" % n)
			ok = false
			continue
		var dur: float = st.get_length()
		# 检查峰值：全零的流时长对但没声音
		# 采样是 16 位小端，按 2 字节读；全零的缓冲区会在这里露馅
		var peak := 0
		var i := 0
		while i + 1 < st.data.size():
			peak = maxi(peak, absi(st.data.decode_s16(i)))
			i += 2
		print("[TEST] %-11s 时长=%.2fs 峰值=%d" % [n, dur, peak])
		if dur <= 0.01 or peak < 2000:
			ok = false
	_finish(ok)


# ------------------------------------------------------------
# 战斗闭环：丧尸会追、会咬，玩家会死会活
# ------------------------------------------------------------
func _test_combat() -> void:
	var world := get_parent()
	var player = null
	for i in 80:
		player = world.get_node_or_null("Players/1")
		if player != null:
			break
		await _tree.create_timer(0.05).timeout
	if player == null:
		print("[TEST] 玩家没生成")
		_finish(false)
		return

	# 等物理就绪再放丧尸（同 S9 的教训：节点存在 ≠ 碰撞体进了空间）
	for i in 4:
		await _tree.physics_frame

	var ok := true
	var pen: Node3D = world.get_node("Zombies")

	# ---- 1. 丧尸会朝玩家移动 ----
	var zb = load("res://scenes/zombie.tscn").instantiate()
	pen.add_child(zb)
	# ★ 必须入树之后再设 global_position，否则全局变换无从计算
	zb.global_position = player.global_position + Vector3(0, 0.6, -9.0)
	for i in 4:
		await _tree.physics_frame

	var d0: float = zb.global_position.distance_to(player.global_position)
	await _tree.create_timer(1.2).timeout
	var d1: float = zb.global_position.distance_to(player.global_position)
	print("[TEST] 丧尸追击：%.1fm → %.1fm（期望缩小 1.5m 以上）" % [d0, d1])
	if d1 >= d0 - 1.5:
		print("[TEST]   诊断：state=%s" % str(zb.state))
		ok = false

	# ---- 2. 贴到跟前会咬人 ----
	var hp0: float = player.hp
	zb.global_position = player.global_position + Vector3(0, 0.3, 1.3)
	await _tree.create_timer(2.0).timeout
	var hp1: float = player.hp
	print("[TEST] 玩家挨咬：HP %.0f → %.0f（期望 -%.0f）" % [hp0, hp1, zb.ATTACK_DAMAGE])
	if hp1 >= hp0:
		print("[TEST]   诊断：state=%s 距离=%.2f" % [
			str(zb.state), zb.global_position.distance_to(player.global_position)])
		ok = false

	# ---- 3. 打空血会倒、会重生 ----
	player.take_damage(500.0, player.global_position)
	await _tree.create_timer(0.25).timeout
	print("[TEST] 死亡状态=%s（期望 true）" % str(player.dead))
	if not player.dead:
		ok = false
	# ★ 重生前必须把丧尸清掉，否则它会守在出生点继续咬 ——
	#   重生出来 HP 100，一秒后又被啃成 88，测试会误判成"重生没回满血"。
	#   这不是 bug，是测试没考虑"原地重生 = 又回到敌人嘴边"。
	zb.queue_free()
	await _tree.create_timer(0.2).timeout
	# 重生要 3 秒，留 4 秒余量
	await _tree.create_timer(4.0).timeout
	print("[TEST] 重生后 HP=%.0f dead=%s（期望 100 / false）" % [player.hp, str(player.dead)])
	if player.hp < 99.0 or player.dead:
		ok = false

	_finish(ok)


# ------------------------------------------------------------
# S11 · 拾荒：拾取 / 背包上限 / 部分拾取 / 容器 / 弹药上限
# ------------------------------------------------------------
func _test_loot() -> void:
	var world := get_parent()
	var player = null
	for i in 80:
		player = world.get_node_or_null("Players/1")
		if player != null:
			break
		await _tree.create_timer(0.05).timeout
	if player == null:
		print("[TEST] 玩家没生成")
		_finish(false)
		return

	# 节点存在 ≠ 碰撞体进空间（S9 的老教训），等两帧再开始
	for i in 4:
		await _tree.physics_frame

	var ok := true
	var loot: Node3D = world.get_node("Loot")
	var inv = player.inventory

	# ---- 1. 走到掉落物旁边按 E ----
	inv.clear()
	var d = load("res://scenes/loot_drop.tscn").instantiate()
	d.item_id = ItemDef.SCRAP
	d.amount = 5
	loot.add_child(d)
	d.global_position = player.global_position + Vector3(0, 0, -1.4)
	await _tree.physics_frame
	d.interact(player)
	await _tree.create_timer(0.06).timeout
	print("[TEST] 拾取废金属：背包 %d（期望 5），掉落物已消失=%s" % [
		inv.count_of(ItemDef.SCRAP), str(not is_instance_valid(d))])
	if inv.count_of(ItemDef.SCRAP) != 5:
		ok = false

	# ---- 2. 只差 2 格时捡 10 个：应该只拿 2 个，剩下留在地上 ----
	inv.clear()
	for i in Inventory.SLOTS - 1:
		inv.add(ItemDef.WOOD, 20)
	inv.add(ItemDef.SCRAP, 18)          # 最后一格，还能装 2 个
	var got: int = player.add_item(ItemDef.SCRAP, 10)
	print("[TEST] 背包只剩 2 格空间时捡 10 个：实际拿到 %d（期望 2）" % got)
	if got != 2:
		ok = false

	# ---- 3. 背包全满：一个都拿不到 ----
	inv.clear()
	for i in Inventory.SLOTS:
		inv.add(ItemDef.WOOD, 20)
	var got2: int = player.add_item(ItemDef.SCRAP, 5)
	print("[TEST] 背包 12/12 时再捡：拿到 %d（期望 0）" % got2)
	if got2 != 0:
		ok = false

	# ---- 4. 搜刮容器：一次给一批，第二次是空的 ----
	inv.clear()
	var c = load("res://scenes/loot_container.tscn").instantiate()
	c.loot_seed = 1234567               # 固定种子，测试必须可复现
	loot.add_child(c)
	c.global_position = player.global_position + Vector3(1.2, 0, 0)
	await _tree.physics_frame
	# ★ 断言不能只看"背包格子变多"：箱子里可能只出了弹药，
	#   而弹药是直接进枪、不占格的（这是有意的设计）。
	#   所以收益要算"物品件数 + 备用弹发数"两项之和。
	var total_before: int = _inv_total(inv)
	var reserve_before: int = player.combat.weapon.reserve
	c.interact(player)
	await _tree.create_timer(0.12).timeout
	var gain_items: int = _inv_total(inv) - total_before
	var gain_ammo: int = player.combat.weapon.reserve - reserve_before
	print("[TEST] 搜刮容器：物品 +%d 件 / 弹药 +%d 发，looted=%s（期望有收益且 true）" % [
		gain_items, gain_ammo, str(c.looted)])
	if gain_items + gain_ammo <= 0 or not c.looted:
		ok = false
	# 再搜一次不该再给东西（一次性）
	var total2: int = _inv_total(inv)
	var reserve2: int = player.combat.weapon.reserve
	c.interact(player)
	await _tree.create_timer(0.08).timeout
	print("[TEST] 二次搜刮：物品 %d→%d 弹药 %d→%d（期望都不变）" % [
		total2, _inv_total(inv), reserve2, player.combat.weapon.reserve])
	if _inv_total(inv) != total2 or player.combat.weapon.reserve != reserve2:
		ok = false

	# ---- 5. 弹药不进背包格，且受上限约束 ----
	var w = player.combat.weapon
	var saved_reserve: int = w.reserve
	w.reserve = 0
	var used_before: int = inv.used_slots()
	var ammo_got: int = player.add_item(ItemDef.AMMO, 500)
	print("[TEST] 捡 500 发弹药：实际进枪 %d（期望上限 %d），背包占用 %d → %d（期望不变）" % [
		ammo_got, player.combat.RESERVE_CAP, used_before, inv.used_slots()])
	if ammo_got != player.combat.RESERVE_CAP or inv.used_slots() != used_before:
		ok = false
	w.reserve = 80
	var ammo_got2: int = player.add_item(ItemDef.AMMO, 500)
	print("[TEST] 已有 80 发时再捡 500：进枪 %d（期望 %d）" % [
		ammo_got2, player.combat.RESERVE_CAP - 80])
	if ammo_got2 != player.combat.RESERVE_CAP - 80:
		ok = false
	w.reserve = saved_reserve

	# ---- 6. 死亡的代价：材料损失一半，急救包和弹药不动 ----
	inv.clear()
	inv.add(ItemDef.SCRAP, 10)
	inv.add(ItemDef.MEDKIT, 3)
	player._lose_on_death()
	print("[TEST] 阵亡后：废金属 %d（期望 5）急救包 %d（期望 3，不该动）" % [
		inv.count_of(ItemDef.SCRAP), inv.count_of(ItemDef.MEDKIT)])
	if inv.count_of(ItemDef.SCRAP) != 5 or inv.count_of(ItemDef.MEDKIT) != 3:
		ok = false

	# ---- 7. 真实瞄准链路：射线能选中箱子，提示会出现 ----
	# 前面几步都是"直接调 interact()"，跳过了交互探测。
	# 但玩家实际玩的时候走的是 AimRay → _target → 按 E 这条路，
	# 而"射线打不到"恰恰是最容易出错的一环（碰撞层、reach、相机位置任一写错都会中招）。
	var terr = world.get_node_or_null("Terrain")
	var c2 = load("res://scenes/loot_container.tscn").instantiate()
	loot.add_child(c2)
	var facing: Vector3 = -player.global_transform.basis.z
	var p2: Vector3 = player.global_position + facing * 2.4
	p2.y = terr.height_at(p2.x, p2.z) + 0.02
	c2.global_position = p2
	for i in 3:
		await _tree.physics_frame
	# ★ 视角不能靠猜角度：相机在胶囊上方 1.6 米，箱子在脚下 1.4 米 ——
	#   真实俯角约 48°，我第一版凭直觉写 27°，射线直接从箱子上方飞过去了。
	#   这里先转 yaw 面向箱子，再由"相机实际位置 → 箱子中心"算出俯角。
	player.rotation.y = atan2(-(p2.x - player.global_position.x),
		-(p2.z - player.global_position.z))
	for i in 2:
		await _tree.physics_frame
	var cam: Camera3D = player.camera
	var from_pos := cam.global_position
	var aim_at := Vector3(p2.x, p2.y + 0.30, p2.z)
	var flat := Vector2(aim_at.x - from_pos.x, aim_at.z - from_pos.z).length()
	var pitch := atan2(aim_at.y - from_pos.y, maxf(flat, 0.01))
	player.set("_pitch", pitch)
	var head_node: Node = player.get_node_or_null("Head")
	if head_node != null:
		head_node.rotation.x = pitch
	for i in 3:
		await _tree.physics_frame
	var probe: Node = player.get_node_or_null("Interact")
	var seen = probe.get("_target") if probe != null else null
	print("[TEST] 瞄准箱子的射线识别：%s（期望识别到刚放的那个箱子）" % (
		"命中" if seen == c2 else "未命中 → %s" % str(seen)))
	if seen != c2:
		ok = false
	if seen != null and seen.has_method("prompt_text"):
		print("[TEST] 交互提示：%s" % seen.prompt_text(player))
	# 复位视角，别把后续画面带歪
	player.set("_pitch", 0.0)
	if head_node != null:
		head_node.rotation.x = 0.0

	inv.clear()
	_finish(ok)


func _inv_total(inv) -> int:
	var n := 0
	for s in inv.slots:
		n += int(s.get("count", 0))
	return n


func _finish(ok: bool) -> void:
	if ok:
		print("[TEST] PASS")
		_tree.quit(0)
	else:
		push_error("[TEST] FAIL")
		_tree.quit(1)


# ------------------------------------------------------------
# 截图：给"画质/模型"这种没有数值断言的改动留证据
# ------------------------------------------------------------
### 用法：Godot --path game -- --solo --selftest shot
##
## 必须**不带** --headless —— 无头模式没有渲染目标，截出来是一张空图。
##
## 为什么要等 40 帧：地形 clipmap 是围绕观察者逐帧铺出来的，
## 第一帧只有天空和一双手；SSAO/光照也要几帧才稳定。
## 最后再等一次 frame_post_draw，确保读到的是"这一帧画完"的 framebuffer，
## 而不是上一帧的残留。
func _shot() -> void:
	for i in 40:
		await _tree.process_frame

	# 把视角压平并转向最近的靶子。不这么做的话，截图会随机朝上、朝下或对着山，
	# 鼠标在无焦点窗口里也会产生 relative 事件，_pitch 早就不是 0 了 ——
	# 于是"同一份代码两次截图画面对不上"，没法做前后对比。
	var player := get_parent().get_node_or_null("Players/1")
	var targets := get_parent().get_node_or_null("Targets")
	if is_instance_valid(player) and player.is_inside_tree():
		player.set("_pitch", 0.0)
		var head := player.get_node_or_null("Head")
		if head != null:
			head.rotation.x = 0.0

		# 截图专用：手动在正前方放两只丧尸。
		# 正常刷新间隔是 4 秒、生成距离 26-40 米，等 40 帧根本走不到跟前
		var pen := get_parent().get_node_or_null("Zombies")
		if pen != null and pen.get_child_count() < 3:
			var fwd: Vector3 = -player.global_transform.basis.z
			for i in 2:
				var zb = load("res://scenes/zombie.tscn").instantiate()
				pen.add_child(zb)
				zb.global_position = player.global_position + fwd * (6.5 + float(i) * 4.5) \
					+ Vector3((float(i) - 0.5) * 2.5, 0.25, 0)
		elif targets != null and targets.get_child_count() > 0:
			var t: Node3D = targets.get_child(0)
			var dir: Vector3 = t.global_position - player.global_position
			# Node3D 的正面是 -Z，所以要让 -Z 指向 dir：yaw = atan2(-x, -z)
			player.rotation.y = atan2(-dir.x, -dir.z)

		# 截图专用：正前方摆一个木箱和一堆战利品，
		# 让"拾荒"这件事在画面里看得见（正常游戏里箱子散布在出生点和广场周围）
		var loot_pen := get_parent().get_node_or_null("Loot")
		if loot_pen != null:
			var fwd2: Vector3 = -player.global_transform.basis.z
			var right2: Vector3 = player.global_transform.basis.x
			# ★ 高度必须查地形，不能拿"玩家脚下 - 1.15"凑。
			#   出生点前方是上坡，用玩家高度算出来的位置会低半米，
			#   东西直接被埋进土里 —— 我第一次截图就什么都看不见。
			var terr = get_parent().get_node_or_null("Terrain")
			var box = load("res://scenes/loot_container.tscn").instantiate()
			loot_pen.add_child(box)
			var bp: Vector3 = player.global_position + fwd2 * 3.2 + right2 * 1.1
			bp.y = terr.height_at(bp.x, bp.z) + 0.02
			box.global_position = bp
			var items := [
				[ItemDef.MEDKIT, 1, 3.2, -1.2],
				[ItemDef.SCRAP, 4, 4.4, -2.4],
				[ItemDef.CLOTH, 2, 3.0, -3.1],
			]
			for e in items:
				var dr = load("res://scenes/loot_drop.tscn").instantiate()
				dr.item_id = String(e[0])
				dr.amount = int(e[1])
				loot_pen.add_child(dr)
				var dp: Vector3 = player.global_position + fwd2 * float(e[2]) \
					+ right2 * float(e[3])
				dp.y = terr.height_at(dp.x, dp.z) + 0.05
				dr.global_position = dp

	for i in 6:
		await _tree.process_frame

	await RenderingServer.frame_post_draw

	var img := _tree.root.get_viewport().get_texture().get_image()
	var path := "/tmp/sandbox_shot.png"
	var err := img.save_png(path)
	if err != OK:
		print("[TEST] 截图失败 err=%d" % err)
		_finish(false)
		return
	print("[TEST] 截图 %s (%d×%d)" % [path, img.get_width(), img.get_height()])

	# ---- 第二张：背包面板 ----
	# 画质类改动要分开看：场景一张、界面一张。
	# 两张挤在一张图里，两件事都看不清
	var hud := get_parent().get_node_or_null("HUD")
	if hud != null and is_instance_valid(player):
		var inv = player.inventory
		inv.clear()
		inv.add(ItemDef.SCRAP, 17)
		inv.add(ItemDef.WOOD, 9)
		inv.add(ItemDef.MEDKIT, 3)
		inv.add(ItemDef.CLOTH, 5)
		inv.add(ItemDef.SCRAP, 6)
		GameState.inventory_changed.emit(inv)
		hud._toggle_bag()
		for i in 4:
			await _tree.process_frame
		await RenderingServer.frame_post_draw
		var img2 := _tree.root.get_viewport().get_texture().get_image()
		var path2 := "/tmp/sandbox_bag.png"
		if img2.save_png(path2) == OK:
			print("[TEST] 截图 %s" % path2)
		inv.clear()

	_finish(true)
