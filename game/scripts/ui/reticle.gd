extends Control
## 准心 + 击中标记
##
## 为什么要用 `_draw()` 画，而不是贴一张准心图片：
##   ① 准心要**跟着扩散实时张开**，图片做不到连续变化（除非准备几十张）
##   ② 占位阶段没有美术资源，矢量线反而更干净
##   ③ 这段代码就是全部，改一个数就能调大小 —— 不用等美术出图
##
## 关键的一行是 `gap = 5 + spread * 7`：
##   把"扩散角（度）"换算成"像素间距"。屏幕上 1 度大约 8 像素（fov 88 / 720p），
##   取 7 稍保守一点，让准心看起来比真实散布略收敛 —— 这是射击游戏的惯例，
##   玩家会觉得"我瞄得挺准"，实际命中率也确实更高一点。

const GAP_BASE := 5.0
const DEG_TO_PX := 7.0
const TICK := 7.0

var _hit_t := 0.0
var _hit_head := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	GameState.hit_confirmed.connect(_on_hit)


func _on_hit(headshot: bool) -> void:
	_hit_t = 0.20
	_hit_head = headshot


func _process(delta: float) -> void:
	if _hit_t > 0.0:
		_hit_t -= delta
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var gap := GAP_BASE + maxf(0.0, GameState.crosshair_spread) * DEG_TO_PX

	# 四根短线。中间留空，不挡视线
	var col := Color(1.0, 1.0, 1.0, 0.88)
	for d in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(c + d * gap, c + d * (gap + TICK), col, 2.0)

	# 中心点：暗底 + 亮点，保证在亮背景和暗背景上都看得见
	draw_circle(c, 1.6, Color(0.0, 0.0, 0.0, 0.55))
	draw_circle(c, 0.9, Color(1.0, 1.0, 1.0, 0.95))

	# 击中标记：四道斜线，向外闪一下
	if _hit_t > 0.0:
		var a := clampf(_hit_t / 0.20, 0.0, 1.0)
		var hc := Color(1.0, 0.92, 0.35, a) if _hit_head else Color(1.0, 1.0, 1.0, a)
		for d in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			draw_line(c + d * 8.0, c + d * 14.0, hc, 2.4)
