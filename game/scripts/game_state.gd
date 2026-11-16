extends Node
## 全局小状态（Autoload，名字 `GameState`）
##
## 为什么需要它：
##   界面（HUD）和角色（Player）是两棵互不相识的节点树。
##   聊天框打开时，角色的 WASD 必须停下来 —— 但这件事没法靠"事件拦截"解决：
##   `Input.get_vector()` 读的是**设备状态**，不是事件流。
##   你把 Enter 事件消费掉，键盘状态依然是"W 被按着"，角色照样往前走。
##
##   所以必须有一个显式的"谁在抢输入"的开关，让角色主动闭嘴。

var ui_captures_input: bool:
	get:
		return not _claims.is_empty()

## 谁在抢输入：`"chat"` / `"shop"` …
## 为什么不是裸 bool？因为聊天和商店可能**同时开着**。
## 裸 bool 下，关掉聊天会把开关无条件写成 false，
## 于是商店还开着、角色却能动 —— 这种"关一个 UI 把另一个 UI 放开"的 bug
## 排查起来非常费劲，因为每个 UI 的代码单看都是对的。
var _claims: Dictionary = {}

## 建造模式是否开启。交互探测看到它为真就让路（否则瞄着墙想放砖时会弹出商店提示）
var build_active := false

## 屏幕下方的交互提示（准心正下方）。空字符串表示不显示。
signal prompt_changed(text: String)
var _prompt := ""

## 请求打开商店面板。由 ShopNpc 发出，ShopPanel 接收 ——
## 中间隔一个信号，是为了让 NPC 不需要知道 UI 的存在。
signal shop_requested(npc_id: int)

## 请求购买。由 ShopPanel 发出，ShopService 接收 ——
## 同理：面板不知道服务器在哪，服务不知道按钮长什么样。
signal buy_requested(item_id: int)

## 一次性提示（HUD 会接成 toast）
##
## ★ 为什么带 secs：不同消息的"读完需要多久"差很多 ——
##   "背包已满"三个字看半秒就够，而"搜到：布料 ×2、废金属 ×3、急救包 ×1"
##   需要三秒才能扫完。固定 2 秒的后果是后者永远读不完就消失了。
##   信号里带时长，而不是让 HUD 按字符串长度猜 —— 猜出来的时间一定不对。
signal notify(text: String, secs: float)

## 弹药变化（HUD 的右下角计数器）
signal ammo_changed(mag: int, reserve: int, reloading: bool)

## 当前武器槽变化（HUD 的武器名/弹药区）
signal weapon_changed(slot: int, label: String)

## 确认命中（HUD 的击中标记 + 音效）。headshot 决定标记的样式
signal hit_confirmed(headshot: bool)

## 当前扩散角（度）。由 Combat 每帧写入，准心按它张开
var crosshair_spread := 0.0

## 玩家血量（S10 接血量系统后由 Health 写入）
var player_health := 100.0
var player_health_max := 100.0

## 血量变化（HUD 血条）。hp 已经扣完，是"结果"不是"变化量"
signal health_changed(hp: float, max_hp: float)

## 挨了一下（HUD 的红边闪 + 方向指示）
## dir_deg 是"攻击来自哪个方向"，相对玩家朝向：0 = 正前方，90 = 右侧
signal hurt(dir_deg: float, amount: float)

## 死亡状态切换（HUD 的死亡遮罩）
signal death_changed(dead: bool)

## 背包变化（S11）。
##
## ★ 为什么直接把 `Inventory` 对象传出来，而不是传一份数组：
##   背包是只读展示给 HUD 的（只有服务器能改），传引用最省事、也不会不同步。
##   如果哪天 HUD 需要改背包，也必须绕回"发 RPC 给服务器"，
##   而不是在这个对象上直接动手 —— 这条线要守住。
signal inventory_changed(inv)


func claim_ui(who: String) -> void:
	_claims[who] = true


func release_ui(who: String) -> void:
	_claims.erase(who)


func set_prompt(text: String) -> void:
	if _prompt == text:
		return
	_prompt = text
	prompt_changed.emit(text)


func _ready() -> void:
	_install_cjk_font()


### 装上中文字体
##
## Godot 自带字体不含中文，不处理的话所有中文都渲染成 □。
##
## 走过的两条弯路（实测记录，省得以后再试一遍）：
##   ① 项目设置 `gui/theme/custom_font` 指向 SystemFont 资源 —— 会被当成
##      "字体文件路径"去加载，得到空路径，刷一屏 FreeType 报错。
##   ② `ThemeDB.fallback_font = SystemFont.new()` —— 在 macOS 上按族名查不到
##      （PingFang 并不在常规字体目录），同样是空路径 + 报错。
##
## 可靠的写法是**按路径**加载字体文件，并检查 get_height() 是否真的出来了。
## 系统字体不打包进游戏，也就不涉及字体授权问题。
const CJK_FONT_PATHS := [
	"/System/Library/Fonts/PingFang.ttc",              # macOS 苹方
	"/System/Library/Fonts/Hiragino Sans GB.ttc",      # macOS 冬青黑
	"/System/Library/Fonts/Supplemental/Songti.ttc",   # macOS 宋体
	"C:/Windows/Fonts/msyh.ttc",                       # Windows 微软雅黑
	"C:/Windows/Fonts/simhei.ttf",                     # Windows 黑体
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
]

func _install_cjk_font() -> void:
	for path in CJK_FONT_PATHS:
		if not FileAccess.file_exists(path):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(path) == OK and f.get_height(16) > 0.0:
			# ★ 必须改**默认主题**的 default_font，而不是只设 ThemeDB.fallback_font。
			#   原因：默认主题里自带一个字体（Open Sans），它优先于 fallback ——
			#   fallback 只在"主题里根本找不到字体"时才生效。我们所有 Label 都没
			#   显式指定字体，于是全都用上了那个不含中文的默认字体。
			ThemeDB.get_default_theme().default_font = f
			ThemeDB.fallback_font = f
			print("[字体] 已加载 %s" % path)
			return
	push_warning("[字体] 未找到中文字体，界面中文会显示为方块")
