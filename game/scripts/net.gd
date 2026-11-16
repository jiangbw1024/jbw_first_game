extends Node
## 网络会话管理（Autoload 单例，全局名 `Net`）
##
## 为什么单独抽一个 Autoload：
##   联机相关的"会话状态"（谁是主机、端口多少、连没连上）不属于任何一个场景。
##   如果塞进 world.gd，将来换关卡、回主菜单、多房间都会跟着它一起死。
##   放到 Autoload，它活得比场景久，场景只是"使用它"。

signal session_started(role: String)   # role = "host" / "client"
signal session_failed(reason: String)

const PORT := 7777
const MAX_PLAYERS := 8


func _ready() -> void:
	# 这三个信号是 MultiplayerAPI 的原生信号。
	# 注意：create_client() 返回 OK 只代表"本地参数没问题"，
	# 真正的连接结果是异步回来的，必须靠信号才知道成功还是失败。
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


### 创建房间：把自己变成服务端（同时也是玩家，peer_id 固定为 1）
func host() -> Error:
	var peer := ENetMultiplayerPeer.new()
	# ENet 是 UDP 上的可靠/不可靠混合协议。
	# 为什么游戏不用 TCP？TCP 的"丢包重传"会让后面的包全部等前面 ——
	# 一个包丢了，你的位置更新要等它重传回来，画面直接卡住。
	# 玩家宁可要"偶尔丢一帧位置"，也不要"卡住 200ms"。
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		session_failed.emit("创建房间失败：%s" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	session_started.emit("host")
	return OK


### 加入房间
func join(ip: String) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		session_failed.emit("连接失败：%s" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	session_started.emit("client")
	return OK


func _on_connected_to_server() -> void:
	print("[S3] 已连接到服务器 | 本机 peer_id = %d" % multiplayer.get_unique_id())


func _on_connection_failed() -> void:
	session_failed.emit("连不上服务器，检查 IP 和防火墙")


func _on_server_disconnected() -> void:
	session_failed.emit("与服务器断开连接")
