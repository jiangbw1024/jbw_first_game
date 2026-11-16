class_name TargetDummy
extends StaticBody3D
## 靶子：S9 用来验证枪感的临时目标，S10 会被真正的丧尸替换
##
## 但它已经把"可被击中"的契约定下来了，丧尸照抄即可：
##   `take_hit(damage, position, direction, shape_index, head_mult) -> Dictionary`
## 返回 `{ "hit": true, "head": bool, "killed": bool }`
##
## 为什么用两个 CollisionShape 而不是两个子节点：
##   射线只会返回一个 collider 和一个 **shape 索引**。
##   两个子节点意味着两套碰撞体、两次处理；一个 body 两个形状更轻，
##   而且"头和身体属于同一个东西"这件事在结构上就是对的。
##   约定：shape 0 = 身体，shape 1 = 头。**顺序不能改**。

@export var max_hp := 100.0
@export var respawn_time := 3.0

var hp := 100.0
var dead := false
## 给自检用：记录最近一次被推击的力度
var last_knockback := 0.0

var _body_mat: StandardMaterial3D
var _head_mat: StandardMaterial3D
var _cloth_mat: StandardMaterial3D
var _flash := 0.0
var _label: Label3D
## [材质, 原本的颜色]。受击闪红时所有部件一起闪，
## 只改 _body_mat 的话，外套和手臂还是绿的，看起来像"只有肚子在流血"
var _mats: Array = []


func _ready() -> void:
	# 只在敌人层：子弹射线打得到，交互射线打不到
	collision_layer = Layers.ENEMY
	collision_mask = 0
	hp = max_hp
	_body_mat = _make_mat(Color(0.33, 0.34, 0.28))     # 皮肤：脏灰绿
	_head_mat = _make_mat(Color(0.38, 0.39, 0.32))
	_cloth_mat = _make_mat(Color(0.155, 0.165, 0.13))  # 衣服：暗橄榄
	$Body.material_override = _body_mat
	$Head.material_override = _head_mat
	_build_silhouette()

	_label = Label3D.new()
	_label.position = Vector3(0, 2.25, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 96
	_label.pixel_size = 0.004
	_label.outline_size = 10
	_label.modulate = Color(1, 0.85, 0.35)
	_label.text = ""
	add_child(_label)


### 给胶囊"穿衣服"，把剪影从药丸变成人。
##
## 胶囊 + 球的组合在远处看就是个雪人 —— 这是"模型粗糙"最直观的来源之一。
## 但碰撞体不能动（自检依赖 shape 0/1 的顺序），所以只在视觉层加零件：
## 外套给出直角肩线，手臂打破圆柱感，下摆和腿把"一整根柱子"切成三段。
## 这些全是纯几何，没有贴图，但剪影一建立，大脑就不会再把它读成雪人。
func _build_silhouette() -> void:
	# 躯干外套：比胶囊略宽，边缘是方的 —— 方肩是"人"最重要的识别特征
	_box(Vector3(0.58, 0.86, 0.40), Vector3(0, 1.06, 0), _cloth_mat)
	_box(Vector3(0.62, 0.32, 0.44), Vector3(0, 0.66, 0), _cloth_mat)        # 下摆
	_box(Vector3(0.19, 0.22, 0.28), Vector3(-0.31, 1.41, 0), _cloth_mat)     # 左肩
	_box(Vector3(0.19, 0.22, 0.28), Vector3(0.31, 1.41, 0), _cloth_mat)      # 右肩
	_cyl(0.075, 0.36, Vector3(-0.36, 1.22, -0.02), _cloth_mat, -0.55)        # 左上臂（前伸）
	_cyl(0.075, 0.36, Vector3(0.36, 1.22, -0.02), _cloth_mat, -0.35)
	_cyl(0.062, 0.34, Vector3(-0.40, 0.98, -0.18), _body_mat, -0.9)          # 左小臂（灰绿 = 露出的皮肤）
	_cyl(0.062, 0.34, Vector3(0.40, 0.98, -0.12), _body_mat, -0.7)
	_cyl(0.085, 0.14, Vector3(0, 1.58, 0), _body_mat)                        # 脖子
	_cyl(0.10, 0.52, Vector3(-0.14, 0.28, 0), _cloth_mat)                    # 左腿
	_cyl(0.10, 0.52, Vector3(0.14, 0.28, 0), _cloth_mat)
	_box(Vector3(0.17, 0.09, 0.30), Vector3(-0.14, 0.05, -0.05), _cloth_mat) # 左鞋
	_box(Vector3(0.17, 0.09, 0.30), Vector3(0.14, 0.05, -0.05), _cloth_mat)

	# 血迹：几块扁平的暗红面片，贴在衣服正面。不用贴图，几何色块就够读
	var blood := _make_mat(Color(0.22, 0.045, 0.035))
	_box(Vector3(0.20, 0.26, 0.03), Vector3(0.10, 1.12, -0.205), blood)
	_box(Vector3(0.11, 0.13, 0.03), Vector3(-0.13, 0.86, -0.215), blood)

	# 头略压扁一点，比正球更像头骨
	$Head.scale = Vector3(0.94, 1.06, 0.96)


func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _cyl(radius: float, height: float, pos: Vector3, mat: Material, tilt := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = radius * 0.9     # 上细下粗，避免看起来像管子
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = 8
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	# 圆柱默认沿 Y；绕 X 转 90° 变成沿 Z。tilt 再往前倒一点，做出丧尸那种前倾
	mi.rotation = Vector3(PI * 0.5 + tilt, 0, 0)
	add_child(mi)
	return mi


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 5.0)
		var k := 1.0 - _flash
		for e in _mats:
			e.mat.albedo_color = Color(1.0, 0.35, 0.3).lerp(e.base, k)
	if _label.text != "":
		_label.position.y = move_toward(_label.position.y, 2.6, delta * 0.9)
		_label.modulate.a = maxf(0.0, _label.modulate.a - delta * 0.8)
		if _label.modulate.a <= 0.01:
			_label.text = ""


# ------------------------------------------------------------
# 受击契约
# ------------------------------------------------------------
func take_hit(dmg: float, pos: Vector3, _dir: Vector3, shape_idx: int, head_mult := 1.0) -> Dictionary:
	if dead:
		return {"hit": true, "head": false, "killed": false}

	var is_head := shape_idx == 1
	var amount := dmg * (head_mult if is_head else 1.0)
	hp -= amount

	_flash = 1.0
	_body_mat.albedo_color = Color(1.0, 0.35, 0.3)
	_show_damage(amount, is_head, pos)

	var killed := hp <= 0.0
	if killed:
		_die()
	return {"hit": true, "head": is_head, "killed": killed}


func _show_damage(amount: float, is_head: bool, pos: Vector3) -> void:
	_label.text = ("%d!" if is_head else "%d") % int(round(amount))
	_label.modulate = Color(1.0, 0.45, 0.35, 1.0) if is_head else Color(1, 0.9, 0.6, 1.0)
	_label.position = Vector3(pos.x, pos.y + 0.25, pos.z)
	_label.global_position = Vector3(pos.x, pos.y + 0.25, pos.z)


func knockback(dir: Vector3, force: float) -> void:
	last_knockback = force
	# 静态体推不动，但可以"晃一下"，让玩家看见推击生效了
	var t := create_tween()
	t.tween_property(self, "rotation:x", deg_to_rad(-8.0) * dir.z, 0.06)
	t.tween_property(self, "rotation:x", 0.0, 0.18)


func _die() -> void:
	dead = true
	Sfx.play("zombie_die", global_position, 0.0, 1.05)
	Sfx.play("hit_flesh", global_position, -2.0, 0.75)
	# 死亡要比"命中"更夸张：连喷几团，位置分散在胸腹，读起来才像"倒下去"
	var fx := get_tree().get_first_node_in_group("fx")
	if fx != null:
		for i in 4:
			var p := global_position + Vector3(
				randf_range(-0.25, 0.25), randf_range(0.6, 1.4), randf_range(-0.25, 0.25))
			fx.spawn_impact(p, Vector3(0, 1, 0), true, true)
	var t := create_tween()
	t.tween_property(self, "rotation:x", deg_to_rad(-82.0), 0.45).set_trans(Tween.TRANS_QUAD)
	t.tween_interval(respawn_time)
	t.tween_property(self, "rotation:x", 0.0, 0.3)
	t.tween_callback(_revive)


func _revive() -> void:
	dead = false
	hp = max_hp
	_flash = 0.0
	for e in _mats:
		e.mat.albedo_color = e.base


func _make_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	_mats.append({"mat": m, "base": color})
	return m
