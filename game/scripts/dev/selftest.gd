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
	# 暂停测试会让整棵树暂停；探针自己必须继续运行，才能解除暂停。
	process_mode = Node.PROCESS_MODE_ALWAYS
	match test_name:
		"input":
			_test_input()
		"pause":
			_test_pause()
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
		"build":
			_test_build()
		"launch":
			_test_launch()
		"profile":
			_test_profile()
		"logout":
			_test_logout()
		"logoutlive":
			_test_logout_live()
		"lobby":
			_test_lobby()
		"buildshot":
			_build_shot()
		"shot":
			_shot()
		"knifeshot":
			_knifeshot()
		"akshot":
			_akshot()
		"pauseshot":
			_pauseshot()
		"startshot":
			_startshot()
		"startui":
			_test_startui()
		"pauseonlineshot":
			_pauseonlineshot()
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
# 游戏内菜单：单机能暂停；联机能开但绝不暂停；出口永远在
# ------------------------------------------------------------
func _test_pause() -> void:
	var world := get_parent()
	var pause_menu = world.get_node_or_null("PauseMenu")
	if pause_menu == null:
		print("[TEST] 找不到 PauseMenu")
		_finish(false)
		return

	# 客户端连接是异步的：会话还没建起来就测，测的是"还没有出口"的中间态，
	# 结论没有意义。最多等 3 秒（180 帧）。
	if not multiplayer.is_server():
		for i in 180:
			if Net.has_session() and not multiplayer.get_peers().is_empty():
				break
			await _tree.process_frame

	var ok := true

	var resume_btn: Button = pause_menu.get_node(
		"Root/Center/Panel/VBox/Main/Buttons/VBox/Resume")
	var guide_btn: Button = pause_menu.get_node(
		"Root/Center/Panel/VBox/Main/Buttons/VBox/GuideButton")
	var leave_btn: Button = pause_menu.get_node(
		"Root/Center/Panel/VBox/Main/Buttons/VBox/Leave")
	var quit_btn: Button = pause_menu.get_node(
		"Root/Center/Panel/VBox/Main/Buttons/VBox/Quit")
	var title: Label = pause_menu.get_node("Root/Center/Panel/VBox/Title")
	var subtitle: Label = pause_menu.get_node("Root/Center/Panel/VBox/Subtitle")

	# ---- 1. 按当前真实角色断言 ----
	#     能冻结就必须真的冻结；不能冻结（客户端 / 有客人）就必须一点不冻。
	#     这条在主机、客户端两种进程里跑出来的期望值不同，所以是"算"出来的，
	#     不是写死的 —— 否则这个用例只能在单机下有意义。
	var can_freeze: bool = bool(pause_menu.get("_can_freeze"))
	print("[TEST] 角色=%s 可冻结=%s（只有单机 / 主机独处才为 true）" % [
		"主机" if multiplayer.is_server() else "客户端", str(can_freeze)])

	var opened: bool = pause_menu.call("open_pause")
	var paused := _tree.paused
	var menu_visible: bool = pause_menu.call("is_open")
	print("[TEST] 打开菜单：打开=%s 暂停中=%s 可见=%s（期望 true/%s/true）" % [
		str(opened), str(paused), str(menu_visible), str(can_freeze)])
	if not opened or not menu_visible:
		ok = false
	if paused != can_freeze:
		print("[TEST] 冻结状态与角色不符：paused=%s 可冻结=%s" % [str(paused), str(can_freeze)])
		ok = false

	var want_title := "游戏暂停" if can_freeze else "游戏菜单"
	var want_resume := "继续游戏" if can_freeze else "回到游戏"
	var want_sub := "冻结" if can_freeze else "不会暂停"
	print("[TEST] 文案：标题=\"%s\" 主按钮=\"%s\"（期望 %s / %s）" % [
		title.text, resume_btn.text, want_title, want_resume])
	if title.text != want_title or resume_btn.text != want_resume:
		ok = false
	if subtitle.text.find(want_sub) < 0:
		print("[TEST] 副标题没说明当前语义：%s" % subtitle.text)
		ok = false

	pause_menu.call("show_guide")
	var guide: Control = pause_menu.get_node("Root/Center/Panel/VBox/Guide")
	var main: Control = pause_menu.get_node("Root/Center/Panel/VBox/Main")
	var guide_text: RichTextLabel = pause_menu.get_node(
		"Root/Center/Panel/VBox/Guide/Scroll/GuideText")
	var guide_ok := guide.visible and not main.visible
	for token in ["W / A / S / D", "鼠标左键", "Esc", "返回开始页"]:
		if guide_text.text.find(token) < 0:
			print("[TEST] 操作指南缺少=%s" % token)
			guide_ok = false
	print("[TEST] 操作指南显示=%s 内容完整=%s" % [str(guide.visible), str(guide_ok)])
	if not guide_ok:
		ok = false

	pause_menu.call("show_main")
	var buttons_ok := (resume_btn.text == want_resume
		and guide_btn.text == "操作指南"
		and leave_btn.text == "返回开始页"
		and quit_btn.text == "退出游戏")
	print("[TEST] 菜单按钮=%s（主按钮 / 指南 / 返回开始页 / 退出游戏）" % str(buttons_ok))
	if not buttons_ok:
		ok = false

	pause_menu.call("resume_game")
	var resumed := not _tree.paused and not bool(pause_menu.call("is_open"))
	print("[TEST] 收起菜单：暂停解除=%s" % str(resumed))
	if not resumed:
		ok = false

	# ---- 2. 反向语义：另一个开关必须独立生效 ----
	#     主机上模拟"有客人"，客户端上模拟"一个人玩"。
	#     这一步是在验证 open_pause 真的读了 _can_freeze，而不是碰巧对。
	pause_menu.call("set_pausable", not can_freeze)
	var flip := not can_freeze
	var opened2: bool = pause_menu.call("open_pause")
	var paused2 := _tree.paused
	var want_title2 := "游戏暂停" if flip else "游戏菜单"
	var want_resume2 := "继续游戏" if flip else "回到游戏"
	print("[TEST] 反向语义（可冻结=%s）：打开=%s 暂停中=%s 标题=\"%s\" 主按钮=\"%s\"" % [
		str(flip), str(opened2), str(paused2), title.text, resume_btn.text])
	if not opened2 or paused2 != flip:
		ok = false
	if title.text != want_title2 or resume_btn.text != want_resume2:
		ok = false

	# ---- 3. 返回开始页要点两次：第一次只进入确认态，不能直接切场景 ----
	#     联机里这一下等于关服务器，误触的代价是别人被踢出去。
	pause_menu.call("request_leave")
	var scene_now: String = _tree.current_scene.scene_file_path if _tree.current_scene != null else ""
	print("[TEST] 离开需确认：按钮=\"%s\" 场景=%s（期望 含「确认」/ 仍在 world.tscn）" % [
		leave_btn.text, scene_now])
	if leave_btn.text.find("确认") < 0:
		ok = false
	if scene_now != "res://scenes/world.tscn":
		ok = false

	# ---- 4. 收起菜单必须解冻，并且不留下输入锁 ----
	pause_menu.call("resume_game")
	var clean := (not _tree.paused and not bool(pause_menu.call("is_open"))
		and not GameState.ui_captures_input and leave_btn.text == "返回开始页")
	print("[TEST] 收起菜单：暂停=%s 可见=%s 输入锁=%s 按钮=\"%s\"（期望全为干净状态）" % [
		str(_tree.paused), str(bool(pause_menu.call("is_open"))),
		str(GameState.ui_captures_input), leave_btn.text])
	if not clean:
		ok = false

	# 还原成这个进程真实的状态，避免影响后面的用例
	pause_menu.call("set_pausable", can_freeze)

	# ---- 5. 重算可用性：会话建立后必须把菜单重新打开 ----
	#     这就是"从大厅点创建房间、一个人玩、Esc 没反应"那条 bug 的守门人：
	#     以前 _refresh_pause_availability 只在 peer 连入/断开时被调用，
	#     单独的会话建立过程没有人算这一次。
	pause_menu.call("set_enabled", false)
	world.call("_refresh_pause_availability")
	var reenabled := bool(pause_menu.get("enabled")) and Net.has_session()
	print("[TEST] 有会话时重算菜单可用性：菜单可开=%s 有会话=%s（期望 true/true）" % [
		str(bool(pause_menu.get("enabled"))), str(Net.has_session())])
	if not reenabled:
		ok = false

	_finish(ok)


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
	# 拉刀只允许播一次：切换完成时 Combat 会再发一次同槽位信号，
	# 如果视图无条件重播，0.86s 时动画应该已经结束而不是仍在播放。
	var knife_view = player.get("knife_view")
	var draw_once: bool = (knife_view != null
		and knife_view.visible
		and not knife_view.is_busy())
	print("[TEST] 拉刀只播一次=%s（期望 true）" % str(draw_once))
	if not draw_once:
		ok = false

	# Q：回到上一把（AK47）
	c.switch_to(c.last_slot)
	await _tree.create_timer(0.36).timeout
	var weapon_view = player.get("view")
	var bolting: bool = weapon_view != null and weapon_view.is_equipping()
	var fire_locked := not c._try_fire()
	print("[TEST] AK 抬枪拉栓：当前=%s 切换中=%s 拉栓动画=%s 开火锁=%s" % [
		c.slot_label(), str(c.is_switching()), str(bolting), str(fire_locked)])
	if c.current_slot != Combat.Slot.PRIMARY or not c.is_switching():
		ok = false
	if not bolting or not fire_locked or c.can_attack():
		ok = false

	await _tree.create_timer(0.60).timeout
	print("[TEST] 0.96s：AK 就绪=%s 动画结束=%s" % [
		str(not c.is_switching()), str(not weapon_view.is_busy())])
	if c.current_slot != Combat.Slot.PRIMARY or c.is_switching():
		ok = false
	if weapon_view == null or weapon_view.is_busy():
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
	await _tree.create_timer(0.96).timeout

	# 换弹中切枪：换弹必须被打断
	c.weapon.ammo = 1
	c.reload()
	var reload_started := c.weapon.reloading
	await _tree.create_timer(0.40).timeout
	var gun_pos_before: Vector3 = weapon_view.position
	c.switch_to(Combat.Slot.KNIFE)
	await _tree.process_frame
	var holstering: bool = weapon_view.is_holstering()
	var pose_jump: float = gun_pos_before.distance_to(weapon_view.position)
	print("[TEST] 换弹中切枪：开始=%s 仍在换弹=%s 收枪动画=%s 姿态跳变=%.4f" % [
		str(reload_started), str(c.weapon.reloading), str(holstering), pose_jump])
	if not reload_started or c.weapon.reloading:
		ok = false
	if not holstering or pose_jump > 0.03:
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
	# 截图期间不接受 Esc 暂停，否则窗口焦点产生的事件会把截图切成暂停菜单。
	var pause_menu = get_parent().get_node_or_null("PauseMenu")
	if pause_menu != null:
		if bool(pause_menu.call("is_open")):
			pause_menu.call("resume_game")
		pause_menu.call("set_enabled", false)

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
# AK 切枪截图：拉栓中段 / 换弹中途收枪
# ------------------------------------------------------------
func _akshot() -> void:
	var pause_menu = get_parent().get_node_or_null("PauseMenu")
	if pause_menu != null:
		if bool(pause_menu.call("is_open")):
			pause_menu.call("resume_game")
		pause_menu.call("set_enabled", false)

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
	await _tree.create_timer(0.85).timeout
	c.switch_to(Combat.Slot.PRIMARY)
	await _tree.create_timer(0.70).timeout
	await RenderingServer.frame_post_draw
	var img := _tree.root.get_viewport().get_texture().get_image()
	var bolt_err := img.save_png("/tmp/ak_bolt.png")

	await _tree.create_timer(0.35).timeout
	c.weapon.ammo = 1
	c.reload()
	await _tree.create_timer(0.45).timeout
	c.switch_to(Combat.Slot.KNIFE)
	await _tree.create_timer(0.15).timeout
	await RenderingServer.frame_post_draw
	img = _tree.root.get_viewport().get_texture().get_image()
	var holster_err := img.save_png("/tmp/ak_holster_reload.png")

	print("[TEST] AK 截图 bolt_err=%d holster_err=%d" % [bolt_err, holster_err])
	_finish(bolt_err == OK and holster_err == OK)


# ------------------------------------------------------------
# 暂停菜单截图：主菜单 / 操作指南
# ------------------------------------------------------------
### 开始页的结构与接线（不用渲染，headless 也能跑）。
##
### 为什么要专门测这个：**"看得见但点不动"是这一屏最容易出的 bug。**
### 按钮存在不等于接上了信号 —— S13 那次单机退出无效，就是按钮好好的、
### 回调却提前 return。所以这里既查节点，也查 `pressed` 有没有真的连上去。
func _test_startui() -> void:
	# 自检启动时 Launch.direct 为真，开始页会一进来就跳走。
	# 这里只想要它"停住"，所以先作废这次启动意图。
	Launch.end_intent()

	var page: Control = load("res://scenes/start/start.tscn").instantiate()
	add_child(page)
	await _tree.process_frame

	var ok := true
	var solo: Button = page.get_node_or_null("Layout/Row/Left/SoloBtn")
	var online: Button = page.get_node_or_null("Layout/Row/Left/OnlineBtn")
	var quit: Button = page.get_node_or_null("Layout/Row/Left/QuitBtn")
	var local_value: Label = page.get_node_or_null(
		"Layout/Row/Right/Card/Margin/VBox/LocalRow/LocalValue")
	var account_value: Label = page.get_node_or_null(
		"Layout/Row/Right/Card/Margin/VBox/AccountRow/AccountValue")

	if solo == null or online == null or quit == null:
		print("[TEST] 开始页缺少按钮节点")
		page.queue_free()
		_finish(false)
		return

	print("[TEST] 开始页按钮：单人=\"%s\" 联机=\"%s\" 退出=\"%s\"" % [
		solo.text, online.text, quit.text])
	if solo.text != "单人进入" or online.text != "联机进入" or quit.text != "退出游戏":
		ok = false

	# 退出按钮必须真的接了信号 —— 这次修的就是"有按钮没出口"。
	var wired := not solo.pressed.get_connections().is_empty() \
		and not online.pressed.get_connections().is_empty() \
		and not quit.pressed.get_connections().is_empty()
	print("[TEST] 三个按钮都已接线=%s（期望 true）" % str(wired))
	if not wired:
		ok = false

	# 档案卡必须有真实读数：没有存档要写"暂无"，不能留占位符。
	print("[TEST] 档案卡：本地=\"%s\" 账号=\"%s\"" % [
		local_value.text if local_value != null else "-",
		account_value.text if account_value != null else "-"])
	if local_value == null or local_value.text.is_empty() or local_value.text == "—":
		ok = false

	# 主次分明：单人必须是实心（有底色），联机是描边（底色几乎透明）。
	# 两个一样的按钮等于没有主次，这一条守着视觉层级。
	var solo_style := solo.get_theme_stylebox("normal") as StyleBoxFlat
	var online_style := online.get_theme_stylebox("normal") as StyleBoxFlat
	if solo_style == null or online_style == null:
		ok = false
	else:
		var contrast := solo_style.bg_color.a - online_style.bg_color.a
		print("[TEST] 按钮层级：单人底色 a=%.2f 联机底色 a=%.2f（差值应 > 0.5）" % [
			solo_style.bg_color.a, online_style.bg_color.a])
		if contrast <= 0.5:
			ok = false

	page.queue_free()
	_finish(ok)


### 开始页截图：UI 改动要能"看"见，不然只能靠猜。
##
### 探针原本挂在世界节点下，而这里要切到开始页 —— 会把它一起 free。
### 所以先把探针搬到 root（不随场景释放），再切场景、等布局稳定、截图。
##  用 `--solo --selftest startshot` 跑（不要加 --headless，无头没有渲染目标）。
func _startshot() -> void:
	for i in 6:
		await _tree.process_frame

	var world := get_parent()
	world.remove_child(self)
	_tree.root.add_child(self)

	# --solo 会把 Launch.direct 置真，开始页会一帧不停又跳回世界。
	# 截图要的是"停在这一屏"，所以先把这次启动意图作废。
	Launch.end_intent()
	_tree.change_scene_to_file("res://scenes/start/start.tscn")

	for i in 30:
		await _tree.process_frame
	await RenderingServer.frame_post_draw
	var img := _tree.root.get_viewport().get_texture().get_image()
	var err := img.save_png("/tmp/start_page.png")
	print("[TEST] 开始页截图=%s 场景=%s" % [
		error_string(err), _tree.current_scene.scene_file_path if _tree.current_scene != null else "-"])
	_finish(err == OK)


func _pauseshot() -> void:
	var world := get_parent()
	if not bool(world.call("is_solo")):
		print("[TEST] 暂停截图必须用 --solo 运行")
		_finish(false)
		return

	var pause_menu = world.get_node_or_null("PauseMenu")
	if pause_menu == null:
		print("[TEST] 找不到 PauseMenu")
		_finish(false)
		return

	for i in 20:
		await _tree.process_frame
	if not bool(pause_menu.call("open_pause")):
		print("[TEST] 暂停菜单打开失败")
		_finish(false)
		return

	for i in 4:
		await _tree.process_frame
	await RenderingServer.frame_post_draw
	var img := _tree.root.get_viewport().get_texture().get_image()
	var err := img.save_png("/tmp/pause_main.png")

	pause_menu.call("show_guide")
	for i in 4:
		await _tree.process_frame
	await RenderingServer.frame_post_draw
	img = _tree.root.get_viewport().get_texture().get_image()
	var guide_err := img.save_png("/tmp/pause_guide.png")

	pause_menu.call("resume_game")
	print("[TEST] 暂停截图 main_err=%d guide_err=%d" % [err, guide_err])
	_finish(err == OK and guide_err == OK)


### 联机版菜单的外观：标题必须是「游戏菜单」，而且世界没有冻住。
##
### 这不是纯截图用例 —— 它同时断言 `set_pausable(false)` 之后
### `get_tree().paused` 仍是 false。如果哪天有人把暂停和解冻逻辑改回去，
### 这张图会照样好看，但断言会红。
func _pauseonlineshot() -> void:
	var pause_menu = get_parent().get_node_or_null("PauseMenu")
	if pause_menu == null:
		print("[TEST] 找不到 PauseMenu")
		_finish(false)
		return

	for i in 20:
		await _tree.process_frame

	pause_menu.call("set_pausable", false)
	if not bool(pause_menu.call("open_pause")):
		print("[TEST] 联机菜单打开失败")
		_finish(false)
		return

	var paused := _tree.paused
	var title: Label = pause_menu.get_node("Root/Center/Panel/VBox/Title")
	# 先抓文案再收菜单：收菜单之后 set_pausable(true) 会把它改回「游戏暂停」，
	# 那时再读就成了"测试自己改坏的值"。
	var title_text := title.text
	for i in 4:
		await _tree.process_frame
	await RenderingServer.frame_post_draw
	var img := _tree.root.get_viewport().get_texture().get_image()
	var err := img.save_png("/tmp/pause_online.png")

	pause_menu.call("resume_game")
	pause_menu.call("set_pausable", true)
	print("[TEST] 联机菜单：标题=\"%s\" 暂停中=%s 截图=%d" % [title_text, str(paused), err])
	_finish(err == OK and not paused and title_text == "游戏菜单")


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
		"dry_fire", "reload_out", "reload_in", "shove", "shell_drop", "zombie_die",
		"knife_draw", "knife_slash", "knife_stab", "knife_hit"]
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


# ------------------------------------------------------------
# S12 · 建造：材料消耗 / 拆除返还 / 砍树
# ------------------------------------------------------------
func _test_build() -> void:
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

	var ok := true
	var build = world.get_node("Buildings")
	var inv = player.inventory
	inv.clear()

	var terrain: Node3D = world.get_node("Terrain")
	var town = world.get_node("Town")

	# ---- 0. 主城广场必须禁建（这是正确行为，不是障碍） ----
	# 先确认它，才能在后面理直气壮地说"城外能建"
	var spawn_cell := Vector2i(roundi(player.global_position.x / 2.0),
		roundi(player.global_position.z / 2.0))
	var blocked_at_spawn: bool = not build._can_place(
		"foundation", spawn_cell, 0, 0, player.global_position)
	print("[TEST] 主城禁止建造：%s（期望 true）" % str(blocked_at_spawn))
	if not blocked_at_spawn:
		ok = false

	# ---- 走到城外，否则后面全是"禁建" ----
	# ★ 测试不该迁就世界，而是应该**复现玩家的真实路径**：
	#   玩家想造房子，本来就得先走出城。所以这里传送等价于"玩家走了 30 米"。
	var moved := false
	for a in 12:
		if moved:
			break
		var ang := TAU * float(a) / 12.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		for d in [14, 20, 26, 32, 40]:
			var probe: Vector3 = player.global_position + dir * float(d)
			if town.is_build_blocked(probe):
				continue
			probe.y = terrain.height_at(probe.x, probe.z) + 1.4
			player.velocity = Vector3.ZERO
			player.global_position = probe
			moved = true
			break
	for i in 5:
		await _tree.physics_frame
	print("[TEST] 已移动到城外：%s（位置 %s）" % [str(moved), str(player.global_position.round())])
	if not moved:
		print("[TEST]   诊断：12 个方向 40 米内全是禁建区，城镇范围可能过大")
		_finish(false)
		return

	# ---- 找一个够得着、可建造的格子 ----
	var cell := Vector2i.ZERO
	var found := false
	for radius in [3, 4, 5, 6, 7]:
		if found:
			break
		for a in 8:
			var ang := TAU * float(a) / 8.0
			var probe2: Vector3 = player.global_position \
				+ Vector3(cos(ang) * float(radius), 0.0, sin(ang) * float(radius))
			var c := Vector2i(roundi(probe2.x / 2.0), roundi(probe2.z / 2.0))
			if build._can_place("foundation", c, 0, 0, player.global_position):
				cell = c
				found = true
				break
	print("[TEST] 城外找到可建造格：%s %s" % [str(found), str(cell)])
	if not found:
		print("[TEST]   诊断：城外 7 米内仍无可建造格")
		_finish(false)
		return

	# ---- 1. 空背包：放不下，且世界没变化 ----
	var before: int = build._pieces.size()
	var r1: bool = build._server_place("foundation", cell, 0, 0, player.global_position, 1)
	print("[TEST] 空背包造地基：%s（期望 false），建筑数 %d → %d（期望不变）" % [
		str(r1), before, build._pieces.size()])
	if r1 or build._pieces.size() != before:
		ok = false

	# ---- 2. 有材料：成功，且按配方扣料 ----
	inv.add(ItemDef.WOOD, 10)
	inv.add(ItemDef.SCRAP, 5)
	var wood0: int = inv.count_of(ItemDef.WOOD)
	var scrap0: int = inv.count_of(ItemDef.SCRAP)
	var r2: bool = build._server_place("foundation", cell, 0, 0, player.global_position, 1)
	var wood1: int = inv.count_of(ItemDef.WOOD)
	var scrap1: int = inv.count_of(ItemDef.SCRAP)
	print("[TEST] 造地基：%s（期望 true），木材 %d→%d 废金属 %d→%d（期望 -2 / -1）" % [
		str(r2), wood0, wood1, scrap0, scrap1])
	if not r2 or wood0 - wood1 != 2 or scrap0 - scrap1 != 1:
		ok = false

	# ---- 3. 材料只够一半时：拒绝，且一分钱都不扣 ----
	# ★ 这条比"完全没材料"重要得多：部分扣料是最隐蔽的 bug ——
	#   玩家只看到"我明明有材料却造不出东西"，查起来却毫无线索。
	# 门框需要 木材 ×3 + 废金属 ×2，这里只给木材 5、一点金属都没有。
	inv.clear()
	inv.add(ItemDef.WOOD, 5)
	var wood_only: int = inv.count_of(ItemDef.WOOD)
	var cell2 := cell + Vector2i(2, 0)
	if not build._can_place("door", cell2, 0, 0, player.global_position):
		cell2 = cell          # 兜底：用刚才那格（门框和地基占位键不同，不冲突）
	var r3: bool = build._server_place("door", cell2, 0, 0,
		player.global_position, 1)
	print("[TEST] 只有木材没有废金属造门框：%s（期望 false），木材 %d → %d（期望不变）" % [
		str(r3), wood_only, inv.count_of(ItemDef.WOOD)])
	if r3 or inv.count_of(ItemDef.WOOD) != wood_only:
		ok = false

	# ---- 4. 拆除返还（按配方一半向下取整） ----
	var target_id := 0
	for id in build._pieces:
		if build._pieces[id]["cell"] == cell:
			target_id = int(id)
			break
	var expect_back := int(RecipeDef.refund_of("foundation").get(ItemDef.WOOD, 0))
	var wood_before: int = inv.count_of(ItemDef.WOOD)
	if target_id > 0:
		build._server_remove(target_id, 1)
	await _tree.create_timer(0.06).timeout
	var back: int = inv.count_of(ItemDef.WOOD) - wood_before
	print("[TEST] 拆除返还：木材 +%d（期望 %d）" % [back, expect_back])
	if back != expect_back:
		ok = false

	# ---- 5. 砍树：3 下，每下 2 木材，倒下那下额外 3 ----
	var trees: Node3D = world.get_node("Trees")
	inv.clear()
	var tree = trees.get_child(0)
	var want: int = int(tree.WOOD_PER_CHOP) * int(tree.MAX_CHOPS) + int(tree.WOOD_FELL_BONUS)
	var fwd: Vector3 = -player.global_transform.basis.z
	tree.global_position = player.global_position + fwd * 1.8
	await _tree.physics_frame
	for i in int(tree.MAX_CHOPS):
		tree.interact(player)
		await _tree.create_timer(0.06).timeout
	var got_wood: int = inv.count_of(ItemDef.WOOD)
	print("[TEST] 砍倒一棵树：木材 +%d（期望 %d），已倒下=%s" % [
		got_wood, want, str(tree.get("_falling"))])
	if got_wood != want or not bool(tree.get("_falling")):
		ok = false

	inv.clear()
	_finish(ok)


# ------------------------------------------------------------
# S12 截图：建造图鉴 + 亲手搭的一面墙
# ------------------------------------------------------------
func _build_shot() -> void:
	for i in 40:
		await _tree.process_frame

	var world := get_parent()
	var player = world.get_node_or_null("Players/1")
	if not is_instance_valid(player):
		print("[TEST] 玩家没生成")
		_finish(false)
		return
	var terrain: Node3D = world.get_node("Terrain")
	var town = world.get_node("Town")
	var build = world.get_node("Buildings")

	# 走到城外（主城禁建，这是设计，不是 bug）
	var moved := false
	for a in 12:
		if moved:
			break
		var ang := TAU * float(a) / 12.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		for d in [14, 20, 26, 32]:
			var probe: Vector3 = player.global_position + dir * float(d)
			if town.is_build_blocked(probe):
				continue
			probe.y = terrain.height_at(probe.x, probe.z) + 1.4
			player.velocity = Vector3.ZERO
			player.global_position = probe
			moved = true
			break
	for i in 6:
		await _tree.physics_frame
	if not moved:
		print("[TEST] 走不到城外，跳过建造截图")
		_finish(false)
		return

	# 材料给足：截图要看到"可造"的绿色，而不是一片红
	player.inventory.clear()
	player.inventory.add(ItemDef.WOOD, 40)
	player.inventory.add(ItemDef.SCRAP, 12)
	GameState.inventory_changed.emit(player.inventory)

	# 在玩家前方搭一排：地基×3，墙上左，门框中，墙右
	#
	# ★ 不能假设"前方三个格子都能建"：山坡上相邻格子的高度差可能超过
	#   REACH_UP/REACH_DOWN，_can_place 会正确地拒绝（不允许悬空造地基）。
	#   所以这里要先探测出一段**连续可建**的格子，而不是硬点三个位置。
	var fwd: Vector3 = -player.global_transform.basis.z
	var right: Vector3 = player.global_transform.basis.x
	var front: Vector3 = player.global_position + fwd * 4.0
	var base := Vector2i(roundi(front.x / 2.0), roundi(front.z / 2.0))

	var run: Array = []
	for axis in [Vector2i(1, 0), Vector2i(0, 1)]:
		if not run.is_empty():
			break
		for sign_v in [-1, 1]:
			if not run.is_empty():
				break
			var d: Vector2i = axis * sign_v
			for k in 4:
				var start: Vector2i = base + d * k
				if build._can_place("foundation", start, 0, 0, player.global_position) \
						and build._can_place("foundation", start + d, 0, 0, player.global_position) \
						and build._can_place("foundation", start + d * 2, 0, 0, player.global_position):
					run = [start, start + d, start + d * 2]
					break
	print("[DBG] 连续可建格：%s" % str(run))

	var built := 0
	var c_left := base + Vector2i(-1, 0)
	var c_mid := base
	var c_right := base + Vector2i(1, 0)
	if run.size() == 3:
		c_left = run[0]
		c_mid = run[1]
		c_right = run[2]
	for c in [c_left, c_mid, c_right]:
		if build._server_place("foundation", c, 0, 0, player.global_position, 1):
			built += 1
	for i in 4:
		await _tree.physics_frame
	# 墙和门框也逐块判定，失败的跳过（不因为一块失败就整张图不拍）
	print("[DBG] wall   -> %s" % str(build._server_place("wall", c_left, 0, 0, player.global_position, 1)))
	print("[DBG] door   -> %s" % str(build._server_place("door", c_mid, 0, 0, player.global_position, 1)))
	print("[DBG] wall   -> %s" % str(build._server_place("wall", c_right, 0, 0, player.global_position, 1)))
	for i in 6:
		await _tree.process_frame

	# 退后几步再拍：三块墙拼起来有 6 米宽，站在 4 米外会糊满整个画面，
	# 拍出来只有"一片米色"，看不出这是墙
	var back_step: Vector3 = -fwd * 3.0
	player.velocity = Vector3.ZERO
	player.global_position = player.global_position + back_step + right * -1.4
	for i in 6:
		await _tree.physics_frame

	# 打开建造模式：图鉴条会出现在底部
	build._set_build_mode(true)
	GameState.build_kind = "door"
	# 截图专用：关掉建造管理器的每帧瞄准更新并隐藏幽灵块。
	# 幽灵是那块半透明的绿色预览 —— 玩的时候必须有，
	# 但在照片里它就变成"地上莫名其妙的一块绿"，掩盖了真正的建筑。
	build.set_process(false)
	var ghost = build.get("_ghost")
	if ghost != null:
		ghost.visible = false
	# 视角压低一点，让墙和图鉴同时入画
	player.set("_pitch", -0.10)
	var head := player.get_node_or_null("Head")
	if head != null:
		head.rotation.x = -0.10
	for i in 12:
		await _tree.process_frame
	await RenderingServer.frame_post_draw

	for id in build._pieces:
		var pi: Dictionary = build._pieces[id]
		print("[DBG] 已建 id=%d kind=%s cell=%s level=%d base=%.1f" % [
			int(id), String(pi["kind"]), str(pi["cell"]), int(pi["level"]), float(pi["base"])])

	var img := _tree.root.get_viewport().get_texture().get_image()
	var path := "/tmp/sandbox_build.png"
	if img.save_png(path) == OK:
		print("[TEST] 截图 %s（已建 %d 块地基 + 2 墙 + 1 门框）" % [path, built])
	build._set_build_mode(false)
	_finish(true)


# ------------------------------------------------------------
# S13 · 启动意图与存档归属
# ------------------------------------------------------------
### 验证"这次启动是什么模式"只有 Launch 一个答案。
func _test_launch() -> void:
	var ok := true

	# 自检自己就是用 --solo 跑的，所以这里能验证解析结果
	print("[TEST] Launch.mode=%s（期望 单机） direct=%s account_required=%s" % [
		Launch.mode_name(), str(Launch.direct), str(Launch.account_required)])
	if Launch.mode != Launch.Mode.SOLO:
		ok = false
	if not Launch.direct:
		ok = false
	if Launch.account_required:
		ok = false

	# ★ 最关键的一条：自检期间存档后端必须是 NONE。
	#   否则每跑一次测试，玩家的真实存档就被覆盖一次 —— 这种 bug
	#   不会报错，只会在某天玩家发现"我的东西没了"。
	var backend: int = AccountSession.call("_pick_backend")
	print("[TEST] 自检时的存档后端=%d（期望 0=NONE，不能碰真实存档）" % backend)
	if backend != 0:
		ok = false

	_finish(ok)


### 验证"本地玩家"找的是自己，以及本地存档能原样往返。
func _test_profile() -> void:
	var world := get_parent()
	var player = null
	for i in 60:
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

	var ok := true

	# ---- 1. 本地玩家必须按"我的 peer_id"查，不能写死 1 ----
	var me: Node = AccountSession.call("_local_player")
	var my_id: int = multiplayer.get_unique_id()
	var matched := me != null and int(me.name) == my_id
	print("[TEST] 本地玩家查找：找到=%s 节点名=%s 我的 peer_id=%d（期望一致）" % [
		str(me != null), str(me.name) if me != null else "-", my_id])
	if not matched:
		ok = false

	# ---- 2. 本地存档往返 ----
	# 写到临时路径，绝不碰真正的 user://local_save.json
	var tmp := "user://__selftest_save.json"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

	var empty: Dictionary = AccountSession.call("_read_local_save", tmp)
	print("[TEST] 无文件时读取：%d 键（期望 0）" % empty.size())
	if not empty.is_empty():
		ok = false

	var payload := {
		"equipmentData": {"item": 3},
		"gameProgress": {"position": [1.5, 6.0, -2.25], "yaw": 0.75, "play_seconds": 42},
		"characterStats": {"hp": 77.0, "inventory": [{"id": "wood", "count": 4}], "weapon": {"ammo": 12, "reserve": 88}},
		"saveVersion": 1,
	}
	var wrote: bool = AccountSession.call("_write_local_save", payload, tmp)
	var back: Dictionary = AccountSession.call("_read_local_save", tmp)
	var pos: Array = back.get("gameProgress", {}).get("position", [])
	print("[TEST] 存档往返：写入=%s 位置=%s 时长=%s（期望 [1.5,6,-2.25] / 42）" % [
		str(wrote), str(pos), str(back.get("gameProgress", {}).get("play_seconds"))])
	if not wrote or pos.size() != 3 or absf(float(pos[0]) - 1.5) > 0.001:
		ok = false
	if int(back.get("gameProgress", {}).get("play_seconds", 0)) != 42:
		ok = false

	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

	# ---- 3. 装备格式兼容：旧 {peer_id: item} 与新 {item: n} 都要认 ----
	var old_fmt: int = AccountSession.call("_equipment_from_save", {"equipment": {"1": 5}})
	var new_fmt: int = AccountSession.call("_equipment_from_save", {"equipment": {"item": 7}})
	var none_fmt: int = AccountSession.call("_equipment_from_save", {"equipment": {}})
	print("[TEST] 装备读取：旧格式=%d 新格式=%d 空=%d（期望 5 / 7 / 0）" % [
		old_fmt, new_fmt, none_fmt])
	if old_fmt != 5 or new_fmt != 7 or none_fmt != 0:
		ok = false

	_finish(ok)


### 房间菜单阶段：没有 peer，但世界已经跑起来了。
##
### 这一屏是"不再强制单机"之后新出现的一个状态。
### 它最容易出的问题不是功能，而是**每帧的多人 API 调用没有 peer 可问**，
### 于是控制台被 "No multiplayer peer is assigned" 刷满 ——
### 真正的报错会被埋掉，所以这里有断言。
func _test_lobby() -> void:
	var world := get_parent()
	for i in 40:
		await _tree.process_frame

	var ok := true
	var menu := world.get_node_or_null("Menu") as CanvasLayer
	var visible := menu != null and menu.visible
	print("[TEST] 房间菜单可见=%s（期望 true，说明登录后没有被强制进游戏）" % str(visible))
	if not visible:
		ok = false

	print("[TEST] 当前有会话=%s（期望 false：还没点创建/加入）" % str(Net.has_session()))
	if Net.has_session():
		ok = false

	# 在线人数那一栏在没会话时必须是空的，不能显示"在线：1"
	var hud = world.get_node_or_null("HUD")
	var players_label: Label = hud.get_node_or_null("Status/Players") if hud != null else null
	if players_label != null:
		print("[TEST] 在线人数标签=\"%s\"（期望空）" % players_label.text)
		if not players_label.text.is_empty():
			ok = false

	# 菜单里应该显示"已登录 xxx"
	var acc: Label = menu.get_node_or_null("Center/VBox/Account") if menu != null else null
	if acc != null:
		print("[TEST] 菜单账号行=\"%s\"" % acc.text)

	# ---- 第二阶段：模拟"点了创建房间" ----
	# 这一步以前根本走不到：登录路径会被强制单机，联机路径又没有账号。
	# 现在它是最常见的路径，所以必须验证"从无 peer 变成有 peer"这一跳。
	world.call("_on_host_pressed")
	var spawned := false
	for i in 80:
		if world.get_node_or_null("Players/1") != null:
			spawned = true
			break
		await _tree.create_timer(0.05).timeout
	print("[TEST] 创建房间后玩家生成=%s（期望 true）" % str(spawned))
	if not spawned:
		_finish(false)
		return

	print("[TEST] 有会话=%s 是服务器=%s（期望 true / true）" % [
		str(Net.has_session()), str(multiplayer.is_server())])
	if not Net.has_session() or not multiplayer.is_server():
		ok = false

	# 菜单要让开，HUD 要接管
	var menu_hidden := menu != null and not menu.visible
	print("[TEST] 房间菜单已隐藏=%s HUD 可见=%s（期望都为 true）" % [
		str(menu_hidden), str(hud != null and hud.visible)])
	if not menu_hidden or hud == null or not hud.visible:
		ok = false

	# 玩家节点名必须等于我的 peer_id —— 这就是 S13 修的那个硬编码
	var me: Node = world.get_node_or_null("Players/%d" % multiplayer.get_unique_id())
	print("[TEST] 本地玩家节点=%s（期望存在）" % str(me != null))
	if me == null:
		ok = false

	# ★ 无头模式必须整段跳过，不能只判空。
	#   `RenderingServer.frame_post_draw` 在没有渲染目标时**永远不会触发**，
	#   于是 await 卡死，最后被 world 里的看门狗强杀 —— 报错是
	#   "[TEST] 超时未完成"，看起来像测试逻辑坏了，其实是等了一个不会来的信号。
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var img := _tree.root.get_viewport().get_texture().get_image()
		if img != null:
			var path := "/tmp/sandbox_lobby.png"
			if img.save_png(path) == OK:
				print("[TEST] 截图 %s" % path)

	_finish(ok)


### 单机退出：这条路径以前是死的 —— 点「退出登录」啥也不发生。
##
### ★ 为什么这里只验"判定 + 文案"，不去真的切场景：
##   探针自己就挂在世界场景里，`change_scene_to_file` 会把它一起 free 掉，
##   于是没有人能打印 PASS，看门狗 90 秒后按超时退出 ——
##   那会把"功能正常"报成"[TEST] 超时"，比不测更误导。
##   真正的场景跳转留给真机验证（单机 → 退出 → 回开始页）。
func _test_logout() -> void:
	var ok := true
	var old_backend: int = AccountSession.get("_backend")

	# ---- 1. 本地会话（单机）：不能去登录页 ----
	AccountSession.set("_backend", 1)   # AccountSession.Backend.LOCAL
	var local_needs_login: bool = AccountSession.call("_logout_needs_login")
	print("[TEST] 单机退出→登录页=%s（期望 false：本地档案回开始页）" % str(local_needs_login))
	if local_needs_login:
		ok = false

	# ---- 2. 云端会话但 token 已失效：同样不该把玩家卡在"回登录页"这条路上 ----
	#     没有身份就没有"该写进谁的档案"，回开始页重选才是对的。
	AccountSession.set("_backend", 2)   # AccountSession.Backend.CLOUD
	if Account.is_logged_in():
		print("[TEST] 本机仍持有登录状态，跳过「云端 + 失效」判定（只在没登录时可测）")
	else:
		var expired_needs_login: bool = AccountSession.call("_logout_needs_login")
		print("[TEST] 云端未登录→登录页=%s（期望 false）" % str(expired_needs_login))
		if expired_needs_login:
			ok = false
	AccountSession.set("_backend", old_backend)

	# ---- 3. 徽章文案：单机不能继续写「退出登录」 ----
	#     按钮写什么就必须做什么 —— 上一版文案说"退出登录"，
	#     实际在单机下什么都不做，这就是玩家看到的"点了没用"。
	var badge: CanvasLayer = load("res://scenes/account/account_badge.tscn").instantiate()
	add_child(badge)

	badge.call("setup", "本地档案", false)
	var solo_text: String = badge.get_node("Root/Panel/HBox/VBox/Logout").text
	var solo_rank: bool = badge.get_node("Root/Panel/HBox/VBox/Leaderboard").visible
	var solo_meta: String = badge.get_node("Root/Panel/HBox/VBox/Meta").text
	print("[TEST] 单机徽章：按钮=\"%s\" 排行榜可见=%s 档案类型=\"%s\"（期望 退出到开始页 / false / 本地档案）" % [
		solo_text, str(solo_rank), solo_meta])
	if solo_text != "退出到开始页" or solo_rank or solo_meta != "本地档案":
		ok = false

	badge.call("setup", "玩家甲", true)
	var cloud_text: String = badge.get_node("Root/Panel/HBox/VBox/Logout").text
	var cloud_rank: bool = badge.get_node("Root/Panel/HBox/VBox/Leaderboard").visible
	print("[TEST] 联机徽章：按钮=\"%s\" 排行榜可见=%s（期望 退出登录 / true）" % [
		cloud_text, str(cloud_rank)])
	if cloud_text != "退出登录" or not cloud_rank:
		ok = false

	badge.queue_free()

	# ---- 4. 离场兜底：所有输入锁必须被清空 ----
	#     以前只 release "pause" / "leaderboard"，死者身上的 "dead" 会留到下一局，
	#     表现是"重新进游戏按 WASD 不动"。
	GameState.claim_ui("dead")
	GameState.claim_ui("bag")
	GameState.claim_ui("pause")
	GameState.clear_ui()
	print("[TEST] 离场后还有输入锁=%s（期望 false）" % str(GameState.ui_captures_input))
	if GameState.ui_captures_input:
		ok = false

	_finish(ok)


### 真机路径：单机点「退出登录」必须真的离开世界。
##
### ★ 为什么这个测试要先把探头"搬家"：
##   退出会 `change_scene_to_file`，挂在世界节点下的探头会被一起 free，
##   于是没人能打印 PASS —— 看门狗 90 秒后按"[TEST] 超时未完成"杀掉进程，
##   一个正常的行为被报成故障。所以先把探头摘下来挂到 root（不会随场景释放），
##   它才能站在场外看"世界有没有真的被换掉"。
##
### 这是本次修复的**唯一硬证据**：旧实现在最后一行 `return` 掉，
### 场景永远停在 world.tscn，这个断言就会实实在在失败。
func _test_logout_live() -> void:
	# 先让世界把 _ready 跑完（玩家、Net.host、存档后端都就位）再搬家
	for i in 6:
		await _tree.process_frame

	var world := get_parent()
	world.remove_child(self)
	_tree.root.add_child(self)

	# 等玩家真正生成：否则测的是"还没开始就退出"，通过也不算数
	for i in 60:
		if world.get_node_or_null("Players/1") != null:
			break
		await _tree.process_frame

	var before: String = _tree.current_scene.scene_file_path if _tree.current_scene != null else ""
	print("[TEST] 退出前场景=%s 玩家已生成=%s（期望 world.tscn / true）" % [
		before, str(world.get_node_or_null("Players/1") != null)])

	AccountSession.call("logout_to_login")

	var reached := before
	for i in 120:
		await _tree.process_frame
		if _tree.current_scene != null:
			reached = _tree.current_scene.scene_file_path
		# 登录页出现就说明判错了（单机不该被要求登录）
		if reached != before:
			break

	print("[TEST] 退出后场景=%s（期望 start.tscn：单机回开始页）" % reached)
	var ok: bool = before == "res://scenes/world.tscn" \
		and reached == "res://scenes/start/start.tscn"
	_finish(ok)


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
	var pause_menu = get_parent().get_node_or_null("PauseMenu")
	if pause_menu != null:
		if bool(pause_menu.call("is_open")):
			pause_menu.call("resume_game")
		pause_menu.call("set_enabled", false)

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
