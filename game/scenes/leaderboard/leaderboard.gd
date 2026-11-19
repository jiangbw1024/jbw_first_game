extends CanvasLayer
## 排行榜覆盖层
##
## 不切主场景：它挂在 world 下面，关闭后玩家还站在原地，装备和世界状态都不丢。
## 打开时暂停场景树并显示鼠标；关闭时由 AccountSession 恢复打开前的暂停状态。

signal close_requested()

const PAGE_SIZE := 10

const COLOR_TEXT := Color(0.937, 0.914, 0.867)
const COLOR_MUTED := Color(0.647, 0.627, 0.592)
const COLOR_FAINT := Color(0.52, 0.50, 0.47)
const COLOR_ACCENT := Color(0.86, 0.70, 0.39)
const COLOR_DANGER := Color(0.88, 0.48, 0.42)

@onready var _close_button: Button = $Root/Center/Panel/Margin/VBox/Header/Close
@onready var _rows: VBoxContainer = $Root/Center/Panel/Margin/VBox/Scroll/Rows
@onready var _empty: Label = $Root/Center/Panel/Margin/VBox/Empty
@onready var _status: Label = $Root/Center/Panel/Margin/VBox/Footer/Status
@onready var _refresh_button: Button = $Root/Center/Panel/Margin/VBox/Footer/Refresh
@onready var _prev_button: Button = $Root/Center/Panel/Margin/VBox/Footer/Prev
@onready var _page_label: Label = $Root/Center/Panel/Margin/VBox/Footer/Page
@onready var _next_button: Button = $Root/Center/Panel/Margin/VBox/Footer/Next

var _page := 1
var _total_pages := 1
var _total := 0
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_close_button.pressed.connect(_request_close)
	_refresh_button.pressed.connect(_on_refresh)
	_prev_button.pressed.connect(_on_prev)
	_next_button.pressed.connect(_on_next)
	_empty.visible = false
	call_deferred("_load_page")


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	_request_close()
	get_viewport().set_input_as_handled()


func _request_close() -> void:
	close_requested.emit()


func _on_refresh() -> void:
	_load_page()


func _on_prev() -> void:
	if _busy or _page <= 1:
		return
	_page -= 1
	_load_page()


func _on_next() -> void:
	if _busy or _page >= maxi(1, _total_pages):
		return
	_page += 1
	_load_page()


func _load_page() -> void:
	if _busy:
		return
	_busy = true
	_sync_buttons()
	_set_status("正在读取排行榜…", COLOR_MUTED)

	var result: Dictionary = await HttpManager.get_json("/api/leaderboard", {
		"page": _page,
		"size": PAGE_SIZE,
	})
	if not is_inside_tree():
		return
	_busy = false

	if not bool(result.get("ok", false)):
		if int(result.get("status", 0)) == 401:
			_set_status("登录已失效，请返回游戏重新登录", COLOR_DANGER)
		else:
			_set_status("读取失败：%s" % String(result.get("message", "未知错误")), COLOR_DANGER)
		_sync_buttons()
		return

	var data: Variant = result.get("data", {})
	if not data is Dictionary:
		_set_status("排行榜数据格式不正确", COLOR_DANGER)
		_sync_buttons()
		return
	var page_data: Dictionary = data
	var items: Variant = page_data.get("items", [])
	if not items is Array:
		items = []

	_total = int(page_data.get("total", 0))
	_total_pages = int(page_data.get("totalPages", 0))
	if _total_pages > 0 and _page > _total_pages:
		_page = _total_pages
		_busy = false
		call_deferred("_load_page")
		return

	_populate(items)
	_page_label.text = "第 %d / %d 页" % [_page, maxi(1, _total_pages)]
	_set_status("共 %d 位幸存者" % _total, COLOR_MUTED)
	_sync_buttons()


func _populate(items: Array) -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()

	_empty.visible = items.is_empty()
	for index in items.size():
		var item: Variant = items[index]
		if item is Dictionary:
			_rows.add_child(_make_row(item, index))


func _make_row(item: Dictionary, index: int) -> PanelContainer:
	var rank := int(item.get("rank", index + 1))
	var username := String(item.get("username", "—"))
	var power := int(item.get("combatPower", 0))
	var stage := int(item.get("clearedStage", 0))
	var clear_progress := int(round(float(item.get("clearProgress", 0.0))))
	var rank_color := COLOR_ACCENT if rank <= 3 else COLOR_FAINT

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 44)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.94, 0.91, 0.86, 0.035 if index % 2 == 0 else 0.06)
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_right = 7
	style.corner_radius_bottom_left = 7
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	row.add_child(_cell("#%d" % rank, 64, HORIZONTAL_ALIGNMENT_CENTER, rank_color, 14))
	row.add_child(_cell(username, 0, HORIZONTAL_ALIGNMENT_LEFT, COLOR_TEXT, 14, true))
	row.add_child(_cell(_format_int(power), 160, HORIZONTAL_ALIGNMENT_RIGHT, COLOR_TEXT, 14))
	row.add_child(_cell(
		"%d 段 · %d%%" % [stage, clampi(clear_progress, 0, 100)],
		150,
		HORIZONTAL_ALIGNMENT_RIGHT,
		COLOR_MUTED,
		13
	))
	return panel


func _cell(
	text: String,
	width: float,
	align: HorizontalAlignment,
	color: Color,
	font_size: int,
	expand: bool = false
) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0)
	label.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL if expand else Control.SIZE_FILL
	)
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", font_size)
	return label


func _sync_buttons() -> void:
	_refresh_button.disabled = _busy
	_prev_button.disabled = _busy or _page <= 1
	_next_button.disabled = _busy or _page >= maxi(1, _total_pages)


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _format_int(value: int) -> String:
	var negative := value < 0
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if negative else "") + out
