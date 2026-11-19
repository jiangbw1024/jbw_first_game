extends Node
## 程序化音效（Autoload 名 `Sfx`）
##
## 为什么不用音频素材？
##   ① 这个工程从零开始，没有任何 .wav/.ogg，下载素材在这台机器上很慢
##   ② 枪声的物理构成其实很固定，可以"合成"出来：
##        爆裂（高频噪声，极快衰减）+ 轰鸣（低频正弦，中速衰减）+ 尾音（低通噪声，慢衰减）
##      理解了这三层，你调任何枪的"重量感"都只是改三个数
##   ③ 程序合成可以**每次播放随机微调音高**，这是消除"机关枪复读感"的关键
##
## 代价：听起来不如录制的真实。灰盒阶段够用，等有美术素材再替换成文件，
## 接口（`play` / `play_ui`）不用改。

const SR := 44100                 # 采样率
const POOL_3D := 16               # 3D 播放器池（世界里的声音）
const POOL_2D := 6                # 2D 播放器池（界面音）

var _cache: Dictionary = {}       # 名字 → AudioStreamWAV
var _p3d: Array[AudioStreamPlayer3D] = []
var _p2d: Array[AudioStreamPlayer] = []
var _i3d := 0
var _i2d := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 0xC0FFEE
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 10.0
		p.max_distance = 90.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_p3d.append(p)
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_p2d.append(p)


# ------------------------------------------------------------
# 播放接口
# ------------------------------------------------------------
### 在世界的某个位置发声。pitch_jitter 让同一段音效每次听起来略有不同
func play(sound: String, pos: Vector3, vol_db := 0.0, pitch := 1.0, pitch_jitter := 0.06) -> void:
	var s := _stream_for(sound)
	if s == null:
		return
	var p := _p3d[_i3d]
	_i3d = (_i3d + 1) % _p3d.size()
	p.stream = s
	p.global_position = pos
	p.volume_db = vol_db
	p.pitch_scale = pitch * (1.0 + _rng.randf_range(-pitch_jitter, pitch_jitter))
	p.play()


### 界面音（击中反馈、空仓、换弹）—— 不需要空间定位，永远在耳边
func play_ui(sound: String, vol_db := 0.0, pitch := 1.0, pitch_jitter := 0.03) -> void:
	var s := _stream_for(sound)
	if s == null:
		return
	var p := _p2d[_i2d]
	_i2d = (_i2d + 1) % _p2d.size()
	p.stream = s
	p.volume_db = vol_db
	p.pitch_scale = pitch * (1.0 + _rng.randf_range(-pitch_jitter, pitch_jitter))
	p.play()


func _stream_for(sound: String) -> AudioStreamWAV:
	if not _cache.has(sound):
		var built := _build(sound)
		if built == null:
			push_warning("[Sfx] 未知音效：%s" % sound)
			return null
		_cache[sound] = built
	return _cache[sound]


# ------------------------------------------------------------
# 音效表
# ------------------------------------------------------------
func _build(sound: String) -> AudioStreamWAV:
	match sound:
		"shot_pistol":  return _gun(0.42, 0.070, 95.0, 11.0, 4.0, 0.95)
		"shot_rifle":   return _gun(0.38, 0.090, 118.0, 14.0, 6.0, 1.00)
		"shot_shotgun": return _gun(0.62, 0.045, 68.0, 7.0, 3.0, 1.10)
		"hit_flesh":    return _flesh_hit()
		"hit_head":     return _head_hit()
		"hit_wall":     return _wall_hit()
		"dry_fire":     return _dry_fire()
		"reload_out":   return _clack(0.16, 420.0, 0.55)
		"reload_in":    return _clack(0.20, 300.0, 0.75)
		"shove":        return _whoosh()
		"chop_wood":    return _chop_wood()
		# S12 蝴蝶刀：出刀金属声、轻/重挥砍、命中
		"knife_draw":   return _knife_draw()
		"knife_slash":  return _knife_whoosh(false)
		"knife_stab":   return _knife_whoosh(true)
		"knife_hit":    return _knife_hit()
		"shell_drop":   return _shell()
		"zombie_growl": return _growl(0.85, 78.0, 1.0)
		"zombie_hit":   return _growl(0.28, 120.0, 0.7)
		"zombie_die":   return _growl(1.10, 62.0, 1.15)
		# 玩家受伤：比"打中敌人"更闷、更低。
		# 高频会听起来像"金属碰撞"，而受伤要的是身体里的钝痛感
		"player_hurt":  return _growl(0.24, 46.0, 0.85)
		"player_die":   return _growl(1.40, 38.0, 1.20)
		# S11 拾荒
		"pickup":       return _pickup()
		"loot_open":    return _loot_open()
		_: return null


# ------------------------------------------------------------
# 合成核心
# ------------------------------------------------------------
### 枪声 = 爆裂 + 轰鸣 + 尾音，三层叠起来才有"重量"
## dur      总长（秒）
## crack    爆裂层衰减速度（越大越"脆"，手枪约 0.07，霰弹枪约 0.045 更闷）
## thump_hz 低频轰鸣的频率（60-120，越低越"沉"）
## thump    轰鸣层衰减
## tail     尾音层衰减（越小尾巴越长，室内混响感更强）
func _gun(dur: float, crack: float, thump_hz: float, thump: float, tail: float, gain: float) -> AudioStreamWAV:
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 991
	var lp := 0.0          # 低通状态（尾音用）
	var hp_prev := 0.0     # 高通状态（爆裂用）
	for i in n:
		var t := float(i) / SR

		# ① 爆裂：白噪声 × 指数衰减。高通一下，去掉闷在低频里的部分
		var white := rng.randf_range(-1.0, 1.0)
		hp_prev = lerp(hp_prev, white, 0.55)
		var high := white - hp_prev
		var crack_s := high * exp(-t / crack) * 1.15

		# ② 轰鸣：低频正弦，带一点点下滑（听感上像"咚"）
		var f := thump_hz * (1.0 - 0.25 * t)
		var thump_s := sin(TAU * f * t) * exp(-t * thump) * 0.95

		# ③ 尾音：低通噪声慢衰减，模拟墙面反射
		lp = lerp(lp, white, 0.05)
		var tail_s := lp * exp(-t * tail) * 0.55

		var s := crack_s + thump_s + tail_s
		# 软削波：把峰值压圆，听起来更"厚"而不是"刺"
		s = tanh(s * 1.7)
		buf[i] = s * gain
	return _encode(buf, 0.92)


### 命中血肉：闷、短、有低频冲击
func _flesh_hit() -> AudioStreamWAV:
	var dur := 0.20
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var lp := 0.0
	for i in n:
		var t := float(i) / SR
		var white := rng.randf_range(-1.0, 1.0)
		lp = lerp(lp, white, 0.10)
		var body := lp * exp(-t / 0.045) * 0.9
		var thud := sin(TAU * 96.0 * t) * exp(-t * 26.0) * 0.8
		buf[i] = tanh((body + thud) * 1.4) * 0.85
	return _encode(buf, 0.9)


### 爆头：比血肉更脆、更高，给"打对了"的确认感
func _head_hit() -> AudioStreamWAV:
	var dur := 0.26
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	for i in n:
		var t := float(i) / SR
		var white := rng.randf_range(-1.0, 1.0)
		var crack := white * exp(-t / 0.020) * 0.55
		var ping := sin(TAU * 1450.0 * t) * exp(-t * 30.0) * 0.45
		var thud := sin(TAU * 150.0 * t) * exp(-t * 22.0) * 0.6
		buf[i] = tanh((crack + ping + thud) * 1.5) * 0.85
	return _encode(buf, 0.9)


### 打墙：只有一声短促的"啪"，没有低频
func _wall_hit() -> AudioStreamWAV:
	var dur := 0.10
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	for i in n:
		var t := float(i) / SR
		buf[i] = rng.randf_range(-1.0, 1.0) * exp(-t / 0.012) * 0.7
	return _encode(buf, 0.75)


### 空仓：两下金属撞击，第二下更轻
func _dry_fire() -> AudioStreamWAV:
	var dur := 0.12
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 55
	for i in n:
		var t := float(i) / SR
		var s := 0.0
		if t < 0.03:
			s += rng.randf_range(-1.0, 1.0) * exp(-t / 0.004) * 0.7
			s += sin(TAU * 2300.0 * t) * exp(-t * 160.0) * 0.5
		var t2 := t - 0.055
		if t2 > 0.0 and t2 < 0.02:
			s += rng.randf_range(-1.0, 1.0) * exp(-t2 / 0.003) * 0.35
		buf[i] = s
	return _encode(buf, 0.8)


### 砍木：钝刀进木头的"咚" + 木屑的"嚓" + 一点空腔共鸣
##
### ★ 为什么不能直接用打墙音（_wall_hit）：
###   打墙是"硬碰硬"，只有一记高频爆裂；砍木是"钝器陷进纤维"，
###   所以主体必须是**低频**（180Hz 的木质共鸣），高频只做点缀。
###   反过来会给玩家"我在敲石头"的错觉 —— 而这一下要换木材。
func _chop_wood() -> AudioStreamWAV:
	var dur := 0.22
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	var lp := 0.0
	for i in n:
		var t := float(i) / SR
		var white := rng.randf_range(-1.0, 1.0)
		# ① 木质共鸣：低频、衰减较快，是"咚"的本体
		var body := sin(TAU * 180.0 * t) * exp(-t * 34.0) * 0.75
		# ② 木屑：被高通滤过的噪声，极快衰减
		lp = lerp(lp, white, 0.35)
		var crack := (white - lp) * exp(-t / 0.012) * 0.55
		# ③ 空腔：320Hz 短鸣，让声音"有厚度"而不是"薄薄一片"
		var ring := sin(TAU * 320.0 * t) * exp(-t * 48.0) * 0.22
		buf[i] = tanh((body + crack + ring) * 1.5) * 0.85
	return _encode(buf, 0.9)


### 拾取：两下上行的短音 + 一点点沙沙
##
### ★ 为什么是"上行"：两个音里第二个比第一个高，听觉上天然读作"得到"；
###   反过来（下行）听起来像"失去/失败"。
###   这是拾取音效的通用语言，和语音里的疑问句上扬是同一个道理。
func _pickup() -> AudioStreamWAV:
	var dur := 0.18
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 606
	for i in n:
		var t := float(i) / SR
		var s := 0.0
		if t < 0.09:
			s += sin(TAU * 1180.0 * t) * exp(-t / 0.035) * 0.42
		var t2 := t - 0.052
		if t2 > 0.0:
			s += sin(TAU * 1620.0 * t2) * exp(-t2 / 0.045) * 0.32
		# 一点噪声沙沙：纯正弦听起来像手机提示音，加了它才像"翻到了实物"
		s += rng.randf_range(-1.0, 1.0) * exp(-t / 0.010) * 0.16
		buf[i] = tanh(s * 1.3) * 0.8
	return _encode(buf, 0.85)


### 开箱：木盖翻起的"吱呀" + 落到底的一记闷响
##
### ★ 两段式：前半是摩擦（带通噪声 + 上升的共振峰），后半是撞击（低频正弦）。
###   只有"吱呀"没有落地声，听起来会像门没关上；只有撞击声则少了"打开"的过程感。
func _loot_open() -> AudioStreamWAV:
	var dur := 0.46
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 909
	var lp := 0.0
	for i in n:
		var t := float(i) / SR
		var white := rng.randf_range(-1.0, 1.0)
		lp = lerp(lp, white, 0.20)
		# 共振峰从 240Hz 一路升到 660Hz：频率上升 = 盖子在加速翻转
		var creak := lp * sin(TAU * (240.0 + 640.0 * t) * t) \
			* clampf(1.0 - t / dur * 1.3, 0.0, 1.0) * 0.34
		var knock := 0.0
		var tk := t - 0.30
		if tk > 0.0:
			knock = sin(TAU * 108.0 * tk) * exp(-tk * 24.0) * 0.52
		buf[i] = tanh((creak + knock) * 1.4) * 0.8
	return _encode(buf, 0.88)


### 机械咔嗒（换弹用）：噪声脉冲 + 一个共振峰
func _clack(dur: float, hz: float, level: float) -> AudioStreamWAV:
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hz)
	for i in n:
		var t := float(i) / SR
		var noise := rng.randf_range(-1.0, 1.0) * exp(-t / 0.010) * 0.6
		var ring := sin(TAU * hz * t) * exp(-t * 55.0) * 0.35
		var ring2 := sin(TAU * hz * 2.7 * t) * exp(-t * 90.0) * 0.18
		buf[i] = (noise + ring + ring2) * level
	return _encode(buf, 0.85)


### 推击：一团被扫过的空气（低通中心频率先高后低）
func _whoosh() -> AudioStreamWAV:
	var dur := 0.22
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	var lp := 0.0
	for i in n:
		var t := float(i) / SR
		var k := 0.35 * (1.0 - t / dur) + 0.03
		lp = lerp(lp, rng.randf_range(-1.0, 1.0), k)
		var env := sin(PI * clampf(t / dur, 0.0, 1.0))
		buf[i] = lp * env * 1.6
	return _encode(buf, 0.7)


### 出刀：两下金属咔嗒 + 刀柄翻转的风声
##
### 为什么是两下：蝴蝶刀展开不是"一下弹出来"，而是手腕甩开、
### 刀柄撞到限位。两声之间留 0.14 秒，耳朵才能读出"翻转"这个过程。
func _knife_draw() -> AudioStreamWAV:
	var dur := 0.42
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1717
	var lp := 0.0
	for i in n:
		var t := float(i) / SR
		var s := 0.0

		# 第一下：枢轴/刀柄的金属碰撞
		s += rng.randf_range(-1.0, 1.0) * exp(-t / 0.005) * 0.62
		s += sin(TAU * 2350.0 * t) * exp(-t * 95.0) * 0.34

		# 第二下：刀柄甩到位，比第一下低一点
		var t2 := t - 0.14
		if t2 > 0.0:
			s += rng.randf_range(-1.0, 1.0) * exp(-t2 / 0.006) * 0.46
			s += sin(TAU * 1750.0 * t2) * exp(-t2 * 82.0) * 0.30

		# 翻转过程的风声：带通噪声，包络先起后收
		var k := 0.05 + 0.20 * clampf(t / dur, 0.0, 1.0)
		lp = lerp(lp, rng.randf_range(-1.0, 1.0), k)
		var env := sin(PI * clampf((t - 0.02) / 0.32, 0.0, 1.0))
		s += lp * env * 0.92

		buf[i] = tanh(s * 1.4) * 0.85
	return _encode(buf, 0.90)


### 挥砍：轻击更尖、更快；重击更低、更长。
func _knife_whoosh(heavy: bool) -> AudioStreamWAV:
	var dur := 0.30 if heavy else 0.20
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026 if heavy else 2025
	var lp := 0.0
	var base := 88.0 if heavy else 150.0
	for i in n:
		var t := float(i) / SR
		var u := t / dur
		var k := (0.28 if heavy else 0.38) * (1.0 - u) + 0.025
		lp = lerp(lp, rng.randf_range(-1.0, 1.0), k)
		var env := sin(PI * clampf(u, 0.0, 1.0))
		var low := sin(TAU * base * (1.0 - 0.30 * u) * t) * exp(-u * 3.0) * 0.34
		buf[i] = tanh((lp * 1.65 + low) * 1.25) * 0.78
	return _encode(buf, 0.80)


### 刀命中：湿闷的肉体撞击 + 一点金属余鸣
func _knife_hit() -> AudioStreamWAV:
	var dur := 0.18
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4243
	var lp := 0.0
	for i in n:
		var t := float(i) / SR
		lp = lerp(lp, rng.randf_range(-1.0, 1.0), 0.18)
		var body := lp * exp(-t / 0.035) * 0.95
		var thud := sin(TAU * 105.0 * t) * exp(-t * 24.0) * 0.70
		var ring := sin(TAU * 1900.0 * t) * exp(-t * 55.0) * 0.22
		buf[i] = tanh((body + thud + ring) * 1.5) * 0.86
	return _encode(buf, 0.88)


### 弹壳落地：高频金属短鸣
func _shell() -> AudioStreamWAV:
	var dur := 0.18
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 606
	for i in n:
		var t := float(i) / SR
		var ping := sin(TAU * 2650.0 * t) * exp(-t * 42.0) * 0.5
		var ping2 := sin(TAU * 4100.0 * t) * exp(-t * 60.0) * 0.25
		var tick := rng.randf_range(-1.0, 1.0) * exp(-t / 0.004) * 0.4
		buf[i] = (ping + ping2 + tick) * 0.7
	return _encode(buf, 0.7)


### 丧尸嗓音：锯齿波 + 抖动 + 噪声，频率随时间下滑（像泄气）
## 用锯齿而不是正弦，是因为人声带有很多谐波，正弦听起来像电子音
func _growl(dur: float, hz: float, gain: float) -> AudioStreamWAV:
	var n := int(dur * SR)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hz * 13)
	var lp := 0.0
	var phase := 0.0
	for i in n:
		var t := float(i) / SR
		var u := t / dur
		# 音高：先微升再持续下滑，加一点抖动（活物感）
		var f: float = hz * (1.0 + 0.18 * sin(TAU * 5.5 * t)) * (1.0 - 0.45 * u)
		phase += f / SR
		phase = fmod(phase, 1.0)
		var saw := phase * 2.0 - 1.0
		# 嗓音的"沙"：噪声经低通，跟锯齿叠加
		lp = lerp(lp, rng.randf_range(-1.0, 1.0), 0.12)
		var s := saw * 0.55 + lp * 0.45
		# 包络：起音快、尾部慢
		var env := minf(u / 0.06, 1.0) * (1.0 - u) * (1.0 - u)
		buf[i] = tanh(s * 1.8) * env * gain * 0.8
	return _encode(buf, 0.85)


# ------------------------------------------------------------
# 编码
# ------------------------------------------------------------
func _encode(buf: PackedFloat32Array, peak: float) -> AudioStreamWAV:
	# 先找峰值再归一化 —— 否则不同音效响度差一倍，混在一起像坏了
	var mx := 0.0001
	for v in buf:
		mx = maxf(mx, absf(v))
	var k := peak / mx

	var n := buf.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		var v := clampf(buf[i] * k, -1.0, 1.0)
		bytes.encode_s16(i * 2, int(v * 32767.0))

	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = SR
	s.stereo = false
	s.data = bytes
	return s
