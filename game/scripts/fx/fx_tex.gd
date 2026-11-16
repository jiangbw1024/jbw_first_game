class_name FxTex
## 程序生成的贴图（无外部素材）
##
## 为什么需要它：只有 QuadMesh + 纯色材质时，粒子是**硬边方块**。
## 枪口火光会变成一块黄色方纸片，血雾会变成一堆小红点 —— 一眼假。
## 一张 64×64 的径向渐变贴图就能解决：中心亮、边缘透明，加法混合下就是"光"。
##
## 生成一次、全局复用（static var），不要在每次开火时重新算像素。

static var _radial: ImageTexture


### 径向渐变：中心不透明，边缘完全透明，衰减用 pow 让光晕更"聚"
static func radial() -> ImageTexture:
	if _radial != null:
		return _radial
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var a := clampf(1.0 - r, 0.0, 1.0)
			# ★ 指数越大，只有中心一点点不透明 —— 粒子看起来就"只剩几个小点"。
			#   1.5 是在"柔和光晕"和"看得见"之间调出来的值。
			a = pow(a, 1.5)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_radial = ImageTexture.create_from_image(img)
	return _radial
