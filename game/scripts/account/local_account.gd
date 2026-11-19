extends Node
## 账号服务（Autoload，全局名 `Account`）
##
## 第三阶段起，账号与存档都交给后端，本机只保留登录凭证：
##   user://auth_session.json  {token, user_id, username, expires_at}
##
## ★ 为什么本机不保存密码：
##   token 已经能代表这次登录，密码落盘只会平白多一份泄露面。
##   密码只在登录/注册的那一次请求里出现，由后端 BCrypt 校验。
##
## ★ 为什么 token 放在 user://：
##   Godot 的 user:// 是每个平台标准的可写目录，卸载/清理应用数据时
##   会和游戏配置一起被处理。自动登录只依赖这个文件，不需要再问密码。
##
## ★ 为什么退出登录只清本地：
##   后端 JWT 是无状态的，/api/auth/logout 没有服务端会话可销毁。
##   客户端删除 token 后，旧 token 即使被复制也只能撑到过期时间。

signal account_changed(username: String)
signal logged_out()

const SESSION_PATH := "user://auth_session.json"
const SESSION_VERSION := 2

const USERNAME_MIN := 3
const USERNAME_MAX := 32
const PASSWORD_MIN := 6
const PASSWORD_MAX := 64
const BCRYPT_MAX_BYTES := 72

var _current: Dictionary = {}
var _pending_save: Dictionary = {}
var _username_pattern := RegEx.new()


func _ready() -> void:
	_restore_session()


# ------------------------------------------------------------
# 对外查询
# ------------------------------------------------------------
func is_logged_in() -> bool:
	return not _current.is_empty() and HttpManager.has_token()


func username() -> String:
	return String(_current.get("username", ""))


func account_id() -> String:
	return String(_current.get("user_id", ""))


func has_session() -> bool:
	return FileAccess.file_exists(SESSION_PATH)


# ------------------------------------------------------------
# 注册 / 登录 / 自动登录 / 退出
# ------------------------------------------------------------
### 注册成功后立刻登录，和原来的交互保持一致。返回 {ok, reason, username}
func register(username_text: String, password: String, confirm: String) -> Dictionary:
	var name := username_text.strip_edges()
	var name_error := _validate_username(name)
	if not name_error.is_empty():
		return _fail(name_error)
	var password_error := _validate_password(password)
	if not password_error.is_empty():
		return _fail(password_error)
	if password != confirm:
		return _fail("两次输入的密码不一致")

	var result: Dictionary = await HttpManager.post_json("/api/auth/register", {
		"username": name,
		"password": password,
	})
	if not bool(result.get("ok", false)):
		return _fail(_result_message(result))

	return await login(name, password)


### 调后端登录并保存 token。返回 {ok, reason, username}
func login(username_text: String, password: String) -> Dictionary:
	var name := username_text.strip_edges()
	if name.is_empty():
		return _fail("请输入账号")
	if password.is_empty():
		return _fail("请输入密码")

	var result: Dictionary = await HttpManager.post_json("/api/auth/login", {
		"username": name,
		"password": password,
	})
	if not bool(result.get("ok", false)):
		return _fail(_result_message(result))

	var data: Variant = result.get("data", {})
	if not data is Dictionary:
		return _fail("服务器返回的登录数据不完整")
	var login_data: Dictionary = data
	var token := String(login_data.get("accessToken", ""))
	if token.is_empty():
		return _fail("服务器没有返回登录凭证")

	var user: Variant = login_data.get("user", {})
	if not user is Dictionary:
		user = {}
	var user_data: Dictionary = user
	var user_id := str(int(user_data.get("id", 0)))
	var display_name := String(user_data.get("username", name))
	var expires_in := int(login_data.get("expiresInSeconds", 0))
	var expires_at := 0
	if expires_in > 0:
		expires_at = int(Time.get_unix_time_from_system()) + expires_in

	_current = {
		"user_id": user_id,
		"username": display_name,
		"token": token,
		"expires_at": expires_at,
	}
	HttpManager.set_token(token)
	_pending_save = {}

	var err := _write_session()
	if err != OK:
		push_warning("[账号] 登录凭证写入失败：%s" % error_string(err))
	account_changed.emit(display_name)
	return {"ok": true, "reason": "", "username": display_name}


### 启动时用本地 token 调一次受保护接口：
##   - 成功：token 有效，同时把存档一起拿到，进主场景不用再请求一次；
##   - 401：token 失效，清除本地记录并回到登录页；
##   - 网络错误：保留 token（可能只是后端没启动），本次先显示登录页。
func auto_login() -> Dictionary:
	if _current.is_empty():
		_restore_session()
	if _current.is_empty():
		return _fail("")
	if HttpManager.has_token() and _is_expired():
		_clear_session()
		return _fail("登录已过期，请重新登录")

	var result: Dictionary = await fetch_save()
	if bool(result.get("ok", false)):
		_pending_save = result.get("data", {})
		account_changed.emit(username())
		return {
			"ok": true,
			"reason": "",
			"username": username(),
			"save": _pending_save,
		}

	if int(result.get("status", 0)) == 401:
		_clear_session()
		return _fail("登录已失效，请重新登录")
	return _fail(String(result.get("reason", "无法验证登录状态")))


### 只有玩家主动点「退出登录」时才调用它。
func logout() -> void:
	_current = {}
	_pending_save = {}
	HttpManager.clear_token()
	_remove_file(SESSION_PATH)
	logged_out.emit()


# ------------------------------------------------------------
# 云存档 / 排行榜（AccountSession 调用）
# ------------------------------------------------------------
### 登录后拉取当前账号的完整存档。
func fetch_save() -> Dictionary:
	if not is_logged_in():
		return {"ok": false, "status": 401, "reason": "未登录"}
	var result: Dictionary = await HttpManager.get_json("/api/saves/me")
	if bool(result.get("ok", false)):
		return {
			"ok": true,
			"status": int(result.get("status", 200)),
			"reason": "",
			"data": result.get("data", {}),
		}
	if int(result.get("status", 0)) == 401:
		_clear_session()
	return {
		"ok": false,
		"status": int(result.get("status", 0)),
		"reason": _result_message(result),
		"network_error": bool(result.get("network_error", false)),
	}


### 把客户端拆分后的存档写回服务端。payload 由 AccountSession 按原结构拆分。
func push_save(payload: Dictionary) -> Dictionary:
	if not is_logged_in():
		return {"ok": false, "status": 401, "reason": "未登录"}
	var result: Dictionary = await HttpManager.patch_json("/api/saves/me", payload)
	if not bool(result.get("ok", false)) and int(result.get("status", 0)) == 401:
		_clear_session()
	return {
		"ok": bool(result.get("ok", false)),
		"status": int(result.get("status", 0)),
		"reason": _result_message(result),
		"data": result.get("data", null),
	}


func push_leaderboard(combat_power: int, cleared_stage: int, clear_progress: float) -> Dictionary:
	if not is_logged_in():
		return {"ok": false, "status": 401, "reason": "未登录"}
	var result: Dictionary = await HttpManager.put_json("/api/leaderboard/me", {
		"combatPower": combat_power,
		"clearedStage": cleared_stage,
		"clearProgress": clear_progress,
	})
	if not bool(result.get("ok", false)) and int(result.get("status", 0)) == 401:
		_clear_session()
	return {
		"ok": bool(result.get("ok", false)),
		"status": int(result.get("status", 0)),
		"reason": _result_message(result),
	}


### 自动登录时已经拉过存档，交给 AccountSession 消费一次，避免重复请求。
func take_prefetched_save() -> Dictionary:
	var save := _pending_save
	_pending_save = {}
	return save


# ------------------------------------------------------------
# 会话文件
# ------------------------------------------------------------
func _restore_session() -> void:
	_current = {}
	HttpManager.clear_token()
	if not FileAccess.file_exists(SESSION_PATH):
		return
	var data := _read_json(SESSION_PATH)
	var token := String(data.get("token", ""))
	if token.is_empty():
		_remove_file(SESSION_PATH)
		return
	_current = {
		"user_id": String(data.get("user_id", "")),
		"username": String(data.get("username", "")),
		"token": token,
		"expires_at": int(data.get("expires_at", 0)),
	}
	HttpManager.set_token(token)
	if _is_expired():
		_clear_session()


func _write_session() -> Error:
	return _write_json(SESSION_PATH, {
		"version": SESSION_VERSION,
		"user_id": account_id(),
		"username": username(),
		"token": String(_current.get("token", "")),
		"expires_at": int(_current.get("expires_at", 0)),
		"saved_at": int(Time.get_unix_time_from_system()),
	})


func _is_expired() -> bool:
	var expires_at := int(_current.get("expires_at", 0))
	return expires_at > 0 and int(Time.get_unix_time_from_system()) >= expires_at


func _clear_session() -> void:
	_current = {}
	_pending_save = {}
	HttpManager.clear_token()
	_remove_file(SESSION_PATH)


# ------------------------------------------------------------
# 校验 / 错误文案
# ------------------------------------------------------------
func _validate_username(name: String) -> String:
	if name.is_empty():
		return "请输入账号"
	if name.length() < USERNAME_MIN or name.length() > USERNAME_MAX:
		return "账号需要 %d–%d 个字符" % [USERNAME_MIN, USERNAME_MAX]
	if _username_pattern.get_pattern().is_empty():
		var err := _username_pattern.compile("^[\\p{L}\\p{N}_-]+$")
		if err != OK:
			# 正则不可用时退回最小检查，后端仍会做最终校验。
			if name.contains(" ") or name.contains("/") or name.contains("\\"):
				return "账号只能包含字母、数字、下划线或短横线"
			return ""
	if _username_pattern.search(name) == null:
		return "账号只能包含字母、数字、下划线或短横线"
	return ""


func _validate_password(password: String) -> String:
	if password.is_empty():
		return "请输入密码"
	if password.length() < PASSWORD_MIN:
		return "密码至少 %d 位" % PASSWORD_MIN
	if password.length() > PASSWORD_MAX:
		return "密码最多 %d 位" % PASSWORD_MAX
	if password.to_utf8_buffer().size() > BCRYPT_MAX_BYTES:
		return "密码过长（UTF-8 不能超过 %d 字节）" % BCRYPT_MAX_BYTES
	return ""


func _result_message(result: Dictionary) -> String:
	var code := String(result.get("code", ""))
	match code:
		"INVALID_CREDENTIALS":
			return "账号或密码错误"
		"USERNAME_EXISTS":
			return "这个账号已经存在"
		"UNAUTHORIZED":
			return "登录已失效，请重新登录"
		"PASSWORD_TOO_LONG":
			return "密码过长（UTF-8 不能超过 72 字节）"
		"VALIDATION_ERROR":
			var detail := String(result.get("message", "输入内容不符合要求"))
			var split := detail.find(": ")
			if split >= 0:
				detail = detail.substr(split + 2)
			return detail
		"NETWORK_ERROR":
			return String(result.get("message", "无法连接服务器"))
		_:
			var message := String(result.get("message", ""))
			if message.is_empty() or message == "success":
				return "操作失败，请稍后重试"
			return message


# ------------------------------------------------------------
# JSON / 文件
# ------------------------------------------------------------
func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


func _write_json(path: String, data: Dictionary) -> Error:
	var dir := path.get_base_dir()
	if not dir.is_empty():
		var dir_err := DirAccess.make_dir_recursive_absolute(dir)
		if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
			return dir_err

	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	file.close()

	var err := DirAccess.rename_absolute(tmp_path, path)
	if err == OK:
		return OK
	DirAccess.remove_absolute(path)
	err = DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		push_warning("[账号] 写入失败：%s（%s）" % [path, error_string(err)])
	return err


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "username": ""}
