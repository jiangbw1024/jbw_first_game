class_name Interactable
extends StaticBody3D
## 可交互物的"契约"（抽象基类）
##
## GDScript 没有 interface，最接近的两种写法是：
##   ① 基类 + `is Interactable` 类型判断   ← 用这个
##   ② 靠 `has_method("interact")` 鸭子类型
##
## 选 ① 的理由：拼错方法名会在**解析期**报错；② 要等到运行时才炸，
## 而且 `has_method` 通过之后还得再 call 一次，等于把类型检查推迟了。
##
## 基类顺便统一了碰撞层设置：可交互物放在 INTERACT 层、mask 为 0，
## 这样玩家不会撞到 NPC，但射线能打到它。

@export var display_name := "物体"
@export var interact_reach := 3.5


func _ready() -> void:
	# 只在 INTERACT 层：射线打得到，身体撞不到
	collision_layer = Layers.INTERACT
	collision_mask = 0


### 抬头显示的动作文案。键位统一写在 game/CONTROLS.md，不放进游戏画面。
func prompt_text(_who: Node3D) -> String:
	return "与「%s」交互" % display_name


### 是否允许此刻交互（比如"钱不够"就可以在这里拒绝，连提示都不给）
func can_interact(_who: Node3D) -> bool:
	return true


### 真正执行。**只在本机玩家这一侧被调用**，
### 需要服务器裁决的事情请在里面发 RPC，不要在这里直接改世界状态。
func interact(_who: Node3D) -> void:
	pass
