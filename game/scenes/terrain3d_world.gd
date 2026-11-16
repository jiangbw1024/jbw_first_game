extends TerrainBase
## S7 · Terrain3D 大世界
##
## 和 S5 那个手搓版的关系：
##   同一个契约（height_at），完全不同的实现。
##   world.gd / build.gd 一行都没改 —— 这就是 terrain_base.gd 存在的理由。
##
## Terrain3D 到底替我们做了什么：
##   ① clipmap LOD：以"观察者"为中心一圈圈往外铺网格，远处顶点稀疏
##   ② 分块（region）：地形按 1024 顶点分块，只渲染/碰撞视野内的块
##   ③ 碰撞体生成：按需在观察者附近生成 HeightMapShape
##   ④ 纹理混合：草/土/岩按坡度自动过渡（auto_slope）
##
## 代价也要说清楚：
##   - 它是 GDExtension（C++ 编译产物），换个 Godot 大版本可能要重新编译
##   - 数据不是我们自己的 _heights 数组了，改高度要走它的 API
##   - 界面参数很多，调试时要读文档

const SEED := 20261111
const WORLD_SIZE := 2048.0      # 世界边长（米）—— 4.2 平方公里
const IMAGE_SIZE := 1024        # 高度图分辨率（顶点数）
const VERTEX_SPACING := 2.0     # 每个顶点隔多远（米）
const HEIGHT_SCALE := 150.0     # 噪声 0..1 映射到多高
const HEIGHT_OFFSET := -35.0    # 整体下沉，让低处低于海平面

var _terrain: Terrain3D
var _viewer: Node3D


func _ready() -> void:
	var t0 := Time.get_ticks_msec()

	_terrain = Terrain3D.new()
	_terrain.name = "Terrain3D"
	# 材质是运行时创建的，没有存成 .tres 文件；
	# 这个开关默认开着会在退出时尝试"释放编辑器贴图"并抱怨找不到文件
	_terrain.free_editor_textures = false
	add_child(_terrain)

	# 区域大小与顶点间距必须在导入数据之前设置 ——
	# 它们决定了"一张 1024 像素的图会铺开多大"
	_terrain.region_size = Terrain3D.SIZE_1024
	_terrain.vertex_spacing = VERTEX_SPACING

	# 关掉它自带的世界背景球，我们自己有 Environment 天空
	_terrain.material.world_background = Terrain3DMaterial.NONE
	_terrain.material.auto_shader_enabled = true
	# auto_slope / blend_sharpness 是"自动坡度混合"的参数。
	# 现在只注册了一层材质，它们没有第二层可混，留着也无害；
	# 但真正该记住的是：**自动坡度不能替代控制图**，见下面那段注释。
	_terrain.material.set_shader_param("auto_slope", 28.0)
	_terrain.material.set_shader_param("blend_sharpness", 0.75)

	# 只注册一层地面材质。
	#
	# 踩过的坑，值得记下来：
	#   Terrain3D 的多层混合靠"控制图"（每个像素 4 个通道 = 4 层权重）。
	#   导入高度图时把控制图传 null，它**不会**当成"全用第一层"，
	#   而是拿高度图本身去当控制图用 —— 于是地形的高度轮廓被直接翻译成
	#   "这里长草、那里是石头"，平地上出现大片灰白色斑块，形状跟等高线走。
	#   我先后试了 auto_slope=90（斑块不变）、把岩石材质改成纯红（斑块变红），
	#   才确认"斑块 = 第二层材质"，再回头查到控制图为空。
	#
	#   自己补一张控制图也不简单：全 0 会整片变黑（权重和为零），
	#   通道语义在不同版本里还不一致。与其赌，不如先把品类减少：
	#   一层"草+土"的贴图，靠颜色噪声和法线做出层次，山体也能看。
	#   等以后真需要裸岩，正确做法是用笔刷按区域刷控制图，而不是自动坡度。
	var ground := _make_texture(
		"Ground", 0.010, 0.22,
		_gradient3(
			Color(0.11, 0.15, 0.055),    # 暗处：湿草
			Color(0.21, 0.26, 0.115),    # 中间调：干草
			Color(0.32, 0.31, 0.185)),   # 亮处：裸土
		2.4)
	_terrain.assets.set_texture_asset(0, ground)

	# clipmap 和碰撞都围绕"观察者"生成。玩家还没出生时先指向自己，
	# 否则第一帧会报 "Cannot find clipmap target"（不致命，但很吵）。
	_terrain.clipmap_target = self
	_terrain.collision_target = self

	_import_heightmap()

	var ms := Time.get_ticks_msec() - t0
	print("[S7] %s | 生成耗时 %d ms" % [describe(), ms])
	print("[S7] 原点高度 %.1f m，600 米外 %.1f m" % [
		height_at(0, 0), height_at(600, 600)])


# ------------------------------------------------------------
# 高度图：噪声 → 24 位灰度图 → 交给 Terrain3D
# ------------------------------------------------------------
func _import_heightmap() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = SEED
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	# 频率要配合世界尺寸看：2048 米的世界用 0.0032 ≈ 每 310 米一个起伏，
	# 再叠 5 层分形就有山脊和细碎地形。频率太低（0.001）整张图只有一个缓坡。
	noise.frequency = 0.0032
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.45

	# ★ 关键的性能选择：用 Noise.get_image() 而不是自己 for 循环算。
	#   1M 个像素在 GDScript 里逐个 get_noise_2d + set_pixel 要好几秒，
	#   而 get_image() 是在 C++ 里一次跑完，几十毫秒。
	var img: Image = noise.get_image(IMAGE_SIZE, IMAGE_SIZE)
	# 灰度 8 位 → 32 位浮点。RF 格式的像素值仍然是 0..1，
	# 高度由 import_images 的 scale/offset 决定，所以换格式只影响精度不影响量级。
	img.convert(Image.FORMAT_RF)

	# 导入。参数含义：
	#   1) [高度图, 控制图, 颜色图]
	#   2) 图片左上角对应的世界坐标
	#   3) 高度偏移  4) 高度缩放
	#
	# 控制图传 null：现在我们只注册了一层材质，控制图没有意义。
	# 但要知道代价 —— 传 null 时 Terrain3D 会拿高度图当控制图，
	# 只在"有多层材质"时才会暴露成灰白斑块。等以后真的加第二层（裸岩/雪），
	# 必须同时提供一张真正的控制图，或者用笔刷涂，不能只靠 auto_slope。
	var ctrl := Image.create(IMAGE_SIZE, IMAGE_SIZE, false, Image.FORMAT_RGBA8)
	ctrl.fill(Color(0.0, 0.0, 0.0, 1.0))

	var origin := Vector3(-WORLD_SIZE * 0.5, 0.0, -WORLD_SIZE * 0.5)
	_terrain.data.import_images([img, ctrl, null], origin, HEIGHT_OFFSET, HEIGHT_SCALE)


func _gradient(a: Color, b: Color) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, a)
	g.set_color(1, b)
	return g


### 三段渐变：暗 / 中 / 亮。
## 两段渐变的色彩变化太"线性"，铺在地面上只有两种颜色来回拉，很像塑料。
## 加一个中间调之后，三种颜色互相穿插，才有"草里混着土"的杂乱感。
func _gradient3(a: Color, b: Color, c: Color) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.52, 1.0])
	g.colors = PackedColorArray([a, b, c])
	return g


### 程序化生成一张"看起来像草地/岩石"的贴图（无外部素材依赖）
##
## 注意这里没有用 await：NoiseTexture2D 的生成是异步的，
## 在 _ready 里 await 会让地形晚一步就绪，而玩家已经在那一刻要出生点高度了。
## 改成同步生成 256×256，几十毫秒，顺序确定。
##
## ★ 三个参数的配合关系（这一段是"纹理难看"的根源，值得记住）：
##   uv     —— 一张纹理在世界上铺多大。uv=0.22 表示每 1/0.22 ≈ 4.5 米重复一次。
##             uv 太小（比如 0.015 = 66 米一次），一个像素就占 26 厘米，
##             贴图会被放大成"十几米一个的大色斑"，看起来像塑料布。
##   freq   —— **低频**噪声，只负责大块颜色起伏。频率要低，因为纹理重复得密，
##             图案一旦明显就会看到"同一朵云反复出现"的接缝感。
##   normal —— **高频**噪声，负责表面颗粒感。它和 albedo 用两套频率，
##             视觉上才有"远看颜色自然、近看有颗粒"的层次。
func _make_texture(asset_name: String, freq: float, uv: float, grad: Gradient,
		normal_strength: float) -> Terrain3DTextureAsset:
	var n := FastNoiseLite.new()
	n.seed = SEED + int(freq * 100000.0)
	n.frequency = freq
	n.fractal_octaves = 3

	var albedo_img: Image = n.get_image(256, 256)
	albedo_img.convert(Image.FORMAT_RGBA8)
	for x in 256:
		for y in 256:
			var c: Color = grad.sample(albedo_img.get_pixel(x, y).r)
			c.a = 0.9          # Terrain3D 用 A 通道存"粗糙度"
			albedo_img.set_pixel(x, y, c)
	albedo_img.generate_mipmaps()

	# 法线单独用高频噪声，别复用 albedo 那张（否则凹凸和色斑完全同步，很假）
	var nn := FastNoiseLite.new()
	nn.seed = SEED + 77
	nn.frequency = freq * 6.0
	nn.fractal_octaves = 4
	var normal_img: Image = nn.get_image(256, 256)
	normal_img.convert(Image.FORMAT_RGBA8)
	normal_img.bump_map_to_normal_map(normal_strength)
	normal_img.generate_mipmaps()

	var ta := Terrain3DTextureAsset.new()
	ta.name = asset_name
	ta.albedo_texture = ImageTexture.create_from_image(albedo_img)
	ta.normal_texture = ImageTexture.create_from_image(normal_img)
	ta.uv_scale = uv
	return ta


# ------------------------------------------------------------
# 观察者：clipmap 和碰撞都围绕它生成
# ------------------------------------------------------------
### 由 world.gd 在本地玩家出现时调用。
## 为什么必须调？Terrain3D 不会渲染整个世界 —— 它只在"观察者"周围生成几圈网格。
## 不告诉它谁是观察者，你会看到一片空。
func attach_viewer(node: Node3D) -> void:
	if node == null or node == _viewer:
		return
	_viewer = node
	_terrain.clipmap_target = node
	_terrain.collision_target = node


# ------------------------------------------------------------
# TerrainBase 契约
# ------------------------------------------------------------
func height_at(x: float, z: float) -> float:
	if _terrain == null:
		return 0.0
	# 注意：这里要传**世界坐标**。Terrain3D 内部按 region 定位再插值，
	# 传局部坐标会得到"另一个地方的地面高度"——一个非常隐蔽的错。
	return _terrain.data.get_height(Vector3(x, 0.0, z))


func playable_radius() -> float:
	return WORLD_SIZE * 0.5 - 24.0


func describe() -> String:
	return "Terrain3D %.0f 米见方（%d×%d 高度图，%.0f 米/顶点，clipmap LOD）" % [
		WORLD_SIZE, IMAGE_SIZE, IMAGE_SIZE, VERTEX_SPACING]
