class_name StepAssist
extends RefCounted
## 台阶辅助：让 CharacterBody3D 能迈上小幅错台
##
## 为什么必须有这个东西：
##   `CharacterBody3D` **没有任何**自动上台阶能力，1 厘米的竖直错台也算一堵墙。
##   而现实里的门廊、路沿、坡道与地形的接缝、甚至台阶每一级的边沿，
##   全都是这种"差一点点"的错台。不加这一步，玩家会被自己造的门廊卡住。
##
## 为什么写成静态工具而不是 player.gd 里的一段：
##   无头探针 `--selftest porch` 要用**同一份逻辑**去验证"人真的能走上去"。
##   探针里复制一份，就会变成"改了一边忘了另一边"的经典漂移。
##
## 算法（标准做法）：被竖直面挡住 → 抬高 step_height 试走一步 →
## 走得通且落点下面有地 → 落下去；走不通说明真的是墙，放弃。

static func try_step(body: CharacterBody3D, step_height: float) -> void:
	if not body.is_on_floor() or not body.is_on_wall():
		return
	if absf(body.get_wall_normal().y) > 0.4:
		return                     # 被斜面挡住，不是台阶

	var motion := Vector3(body.velocity.x, 0.0, body.velocity.z) \
		* body.get_physics_process_delta_time()
	if motion.length() < 0.001:
		return
	# 至少要往前挪一点才跨得过台沿（位移太短等于"原地抬腿"）
	motion = motion.normalized() * maxf(motion.length(), 0.15)

	var lifted := body.global_transform.translated(Vector3.UP * step_height)
	if body.test_move(lifted, motion):
		return                     # 抬起来还是撞 → 这是一堵墙

	var ahead := lifted.translated(motion)
	# 落点下面必须有地，否则就是"翻墙"—— 迈出去会摔下去
	if not body.test_move(ahead, Vector3.DOWN * (step_height + 0.08)):
		return
	body.global_position = ahead.origin
