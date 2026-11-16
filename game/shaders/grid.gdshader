// ============================================================
// 地面网格着色器
// ------------------------------------------------------------
// 为什么用着色器而不是贴一张网格图片？
//   1. 零资源依赖 —— 不用下载纹理文件，工程保持干净
//   2. 无限分辨率 —— 放大到 1 米内网格线依然锐利，贴图会糊成马赛克
//   3. 抗锯齿是"算"出来的：用 fwidth 感知当前像素覆盖多大世界距离，
//      自动让远处的线变淡，不会产生摩尔纹
//
// 这段代码在 S1 里还顺便演示了"材质"到底是什么：
//   ALBEDO  = 这像素反射什么颜色
//   ROUGHNESS = 表面粗糙度（0 像镜子，1 像水泥）
// 光打上去之后的最终颜色，是光照 × 这些参数算出来的。
// ============================================================
shader_type spatial;

uniform vec3 base_color : source_color = vec3(0.15, 0.16, 0.19);
uniform vec3 line_color : source_color = vec3(0.30, 0.33, 0.38);
uniform float cell_size = 1.0;        // 一格代表多少米
uniform float meters_per_uv = 60.0;   // 地面总边长，用来把 UV 换算成米
uniform float line_width = 1.0;       // 线宽（单位：像素）

void fragment() {
	// UV 是 0..1 的贴图坐标，乘上边长就变成"以米为单位的坐标"
	vec2 p = UV * meters_per_uv / cell_size;

	// 经典网格公式：fract 取小数部分得到 0..1 的循环，
	// 再算它到格子中心的距离；除以 fwidth 把距离换算成"像素"。
	vec2 g = abs(fract(p - 0.5) - 0.5) / fwidth(p);

	// g 越小 = 离格子边越近。取两轴最小值，得到一条 1px 宽的线
	float line = 1.0 - min(min(g.x, g.y) / line_width, 1.0);

	ALBEDO = mix(base_color, line_color, line);
	ROUGHNESS = 0.92;
	SPECULAR = 0.1;
}
