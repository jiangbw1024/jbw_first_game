extends Node
## 后端 HTTP 统一入口（Autoload，全局名 `HttpManager`）
##
## 所有业务请求都从这里走，页面不直接碰 HTTPRequest：
##   - 统一拼接 base URL、Content-Type / Accept、Bearer token；
##   - 统一解析后端 {success, code, message, data} 结构；
##   - 统一把网络失败、HTTP 错误、业务错误收敛成同一个字典。
##
## 返回结构（所有请求方法一致）：
##   {ok, status, code, message, data, raw, network_error}
##
## ★ base URL 为什么允许环境变量覆盖：
##   本地开发默认 127.0.0.1:8080；换机器或部署测试环境时不用改代码：
##     JBW_API_BASE=http://192.168.1.20:8080 Godot --path game

const DEFAULT_BASE_URL := "http://127.0.0.1:8080"
const REQUEST_TIMEOUT := 8.0

var base_url := DEFAULT_BASE_URL

var _token := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var override := OS.get_environment("JBW_API_BASE").strip_edges()
	if not override.is_empty():
		base_url = override.trim_suffix("/")


func set_token(token: String) -> void:
	_token = token


func clear_token() -> void:
	_token = ""


func has_token() -> bool:
	return not _token.is_empty()


## GET 封装。query 只接受能被 str() 表达的标量，例如 {"page": 1, "size": 10}。
func get_json(path: String, query: Dictionary = {}) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, path, query, null)


func post_json(path: String, body: Dictionary = {}) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, path, {}, body)


func put_json(path: String, body: Dictionary = {}) -> Dictionary:
	return await _request(HTTPClient.METHOD_PUT, path, {}, body)


func patch_json(path: String, body: Dictionary = {}) -> Dictionary:
	return await _request(HTTPClient.METHOD_PATCH, path, {}, body)


func _request(method: int, path: String, query: Dictionary, body: Variant) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT
	add_child(http)

	var headers := PackedStringArray([
		"Accept: application/json",
		"Content-Type: application/json",
	])
	if not _token.is_empty():
		headers.append("Authorization: Bearer %s" % _token)

	var body_text := ""
	if body is Dictionary:
		body_text = JSON.stringify(body)

	var err := http.request(_build_url(path, query), headers, method, body_text)
	if err != OK:
		http.queue_free()
		return _failure(
			"NETWORK_ERROR",
			"无法发起请求：%s" % error_string(err),
			true
		)

	var response: Array = await http.request_completed
	http.queue_free()

	var result_code := int(response[0])
	var status := int(response[1])
	var raw := (response[3] as PackedByteArray).get_string_from_utf8()
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return _failure(
			"NETWORK_ERROR",
			_network_reason(result_code),
			true,
			0,
			raw
		)

	var parsed: Variant = JSON.parse_string(raw) if not raw.strip_edges().is_empty() else {}
	if not parsed is Dictionary:
		return _failure(
			"BAD_RESPONSE",
			"服务器返回的不是有效 JSON（HTTP %d）" % status,
			false,
			status,
			raw
		)

	var payload: Dictionary = parsed
	var success := bool(payload.get("success", status >= 200 and status < 300))
	var code := String(payload.get("code", "OK" if success else "HTTP_%d" % status))
	var message := String(payload.get("message", ""))
	if message.is_empty():
		message = "请求成功" if success else "请求失败（HTTP %d）" % status

	return {
		"ok": success and status >= 200 and status < 300,
		"status": status,
		"code": code,
		"message": message,
		"data": payload.get("data", null),
		"raw": raw,
		"network_error": false,
	}


func _build_url(path: String, query: Dictionary) -> String:
	var url := base_url + path
	if query.is_empty():
		return url
	var parts := PackedStringArray()
	for key in query:
		parts.append("%s=%s" % [str(key).uri_encode(), str(query[key]).uri_encode()])
	return "%s?%s" % [url, "&".join(parts)]


func _network_reason(result_code: int) -> String:
	match result_code:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "无法连接服务器，请确认后端已启动"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "无法解析服务器地址"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接服务器失败"
		HTTPRequest.RESULT_TIMEOUT:
			return "请求超时，请稍后重试"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS 握手失败"
		_:
			return "网络请求失败（%d）" % result_code


func _failure(
	code: String,
	message: String,
	network_error: bool,
	status: int = 0,
	raw: String = ""
) -> Dictionary:
	return {
		"ok": false,
		"status": status,
		"code": code,
		"message": message,
		"data": null,
		"raw": raw,
		"network_error": network_error,
	}
