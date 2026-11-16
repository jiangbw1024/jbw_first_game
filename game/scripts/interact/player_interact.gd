extends Node
## 本地玩家的交互探测（挂在 player.tscn 的 `Interact` 子节点）
##
## 为什么不做进 player.gd？
##   player.gd 已经管着移动、视角、相机三条逻辑，再塞交互就成上帝对象了。
##   拆成子节点后，"只有本机玩家做探测"就退化成一行 `is_local()` 判断，
##   不需要 build.gd 里那种 `_local_player()` 反查。

const AIM_DISTANCE := 24.0      # 交互射线长度（比手臂长，因为相机在身后 4.2 米）

var _player                     # 不写死类型：需要调用 player.gd 的 is_local()
var _target: Interactable = null


func _ready() -> void:
	_player = get_parent()


func _physics_process(_delta: float) -> void:
	if _player == null or not _player.is_local():
		return
	# 聊天/商店抢了输入，或者正在建造模式 —— 都暂时让路
	if GameState.ui_captures_input or GameState.build_active:
		_clear_target()
		return

	var exclude: Array[RID] = [_player.get_rid()]
	var hit := AimRay.cast(get_viewport(), exclude, AIM_DISTANCE, Layers.AIM_MASK)

	var found: Interactable = null
	if not hit.is_empty():
		var collider = hit.collider
		if collider is Interactable:
			var it := collider as Interactable
			# ★ 二次距离校验：射线从相机出发，相机在角色身后 4.2 米。
			#   不做这一步会出现"站在 5 米外能开 3 米内的箱子"。
			if it.can_interact(_player) \
					and _player.global_position.distance_to(hit.position) <= it.interact_reach:
				found = it

	if found == _target:
		return
	_target = found
	GameState.set_prompt("" if _target == null else _target.prompt_text(_player))


func _unhandled_input(event: InputEvent) -> void:
	if _player == null or not _player.is_local():
		return
	if GameState.ui_captures_input or GameState.build_active:
		return
	if event.is_action_pressed("interact") and _target != null:
		_target.interact(_player)
		get_viewport().set_input_as_handled()


func _clear_target() -> void:
	if _target != null:
		_target = null
		GameState.set_prompt("")
