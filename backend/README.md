# jbw-game-server

联机沙盒游戏的 Java 后端：MySQL 数据层、Spring Boot 分层结构、账号认证、云存档与排行榜接口。

本目录独立于 Godot 游戏，不修改 `game/` 下任何代码。

## 1. 技术栈

| 组件 | 版本 / 说明 |
| --- | --- |
| JDK | 21+（本机使用 27 验证） |
| Spring Boot | 4.1.2 |
| MyBatis-Plus | 3.5.18.1（Spring Boot 4 starter） |
| MySQL | 8.0+（本机使用 26.10 验证） |
| 密码哈希 | BCrypt（`spring-security-crypto`） |
| Token | JJWT 0.13.0 |

## 2. 目录结构

```text
backend/
├── pom.xml
├── sql/
│   ├── schema.sql              # 建库 + 三张表
│   └── dev-user.sql            # 本地开发数据库账号
└── src/main/
    ├── java/com/jbw/game/
    │   ├── JbwGameServerApplication.java
    │   ├── config/             # MyBatis-Plus / Mapper 扫描
    │   ├── controller/         # HTTP 入口，只做参数与响应
    │   ├── dto/                # 接口返回对象
    │   ├── entity/             # 与数据库表一一对应
    │   ├── exception/          # 业务异常与全局异常处理
    │   ├── mapper/             # SQL / MyBatis 接口
    │   ├── security/           # JWT 拦截器与认证属性
    │   ├── service/            # 业务规则与事务边界
    │   └── utils/              # BCrypt、JWT 等无状态工具
    └── resources/application.yml
```

## 3. 三张表为什么这样拆

### `game_user`

只保存“能不能登录”的身份数据。用户名唯一，密码只保存 BCrypt 哈希。账号是根实体，另外两张表通过 `user_id` 关联它。

### `player_save`

保存“这个账号玩到哪里”。`user_id` 上的唯一索引把它限制成一账号一份存档，即一对一。

三类内容用 JSON 分开存：

- `equipment_data`：直接承接 Godot 现有装备结构，后续不需要把 `peer_id -> item_id` 拆成新表；
- `game_progress`：关卡、任务、位置、朝向等会随版本变化的数据；
- `character_stats`：生命值、背包、弹药等角色属性。

JSON 的代价是不能直接给内部字段建普通索引。如果以后要按“某件装备”查玩家，应增加生成列或独立装备表，而不是在 JSON 上做全表扫描。

### `leaderboard`

保存“排行榜要展示什么”。当前赛季一人一条，只放排序需要的战力、最高关卡、关卡进度和更新时间。名次通过查询计算，不存冗余的 `rank` 字段，避免每次分数变化都批量更新名次。

### 关联关系

```text
game_user 1 ──── 1 player_save
game_user 1 ──── 1 leaderboard
```

两张子表都是 `user_id` 唯一 + 外键 `ON DELETE CASCADE`：删除账号时存档和排行榜记录一起清理，不会留下孤儿数据。

## 4. 分层职责

- `entity`：数据库行的 Java 映射，不加业务逻辑；
- `mapper`：MyBatis-Plus 的 CRUD 与自定义 SQL，只关心“怎么查/写”；
- `service`：业务规则、事务边界、跨表组合；
- `controller`：HTTP 路由、参数接收、响应返回，不直接操作 Mapper；
- `utils`：BCrypt、JWT 等与请求上下文无关的工具；
- `config`：Mapper 扫描、后续分页/拦截器等基础设施配置。

## 5. 启动

### 5.1 建库建表

```bash
mysql -u root -p < sql/schema.sql
mysql -u root -p < sql/dev-user.sql
```

如果不想创建开发账号，也可以直接用自己的 MySQL 用户，并通过环境变量覆盖连接信息。

### 5.2 配置

默认值已经写在 `application.yml`：

```text
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=jbw_game
DB_USERNAME=jbw_app
DB_PASSWORD=jbw_dev_2026
SERVER_PORT=8080
```

生产环境至少应覆盖 `DB_PASSWORD` 与 `JWT_SECRET`。

### 5.3 运行

```bash
mvn spring-boot:run
```

### 5.4 验证数据库连接

```bash
curl http://127.0.0.1:8080/api/system/db-version
```

期望返回：

```json
{
  "success": true,
  "code": "OK",
  "message": "success",
  "data": {
    "version": "26.10.0",
    "versionComment": "MySQL Community Server - GPL",
    "schema": "jbw_game",
    "currentUser": "jbw_app@127.0.0.1",
    "serverTime": "2026-11-17T15:00:00.000"
  },
  "timestamp": "2026-11-17T15:00:00.000"
}
```

## 6. 业务接口

### 6.1 接口清单

| 方法 | 路径 | 是否需要 token | 作用 |
| --- | --- | --- | --- |
| POST | `/api/auth/register` | 否 | 注册账号 |
| POST | `/api/auth/login` | 否 | 登录并返回 JWT |
| POST | `/api/auth/logout` | 是 | 退出登录提示，客户端删除 token |
| GET | `/api/saves/me` | 是 | 查询当前账号存档 |
| PUT | `/api/saves/me` | 是 | 全量保存装备、进度、角色属性 |
| PATCH | `/api/saves/me` | 是 | 部分更新存档字段 |
| PUT | `/api/leaderboard/me` | 是 | 更新当前账号战力与通关进度 |
| GET | `/api/leaderboard?page=1&size=10` | 是 | 按战力降序分页查询 |
| GET | `/api/system/db-version` | 否 | 数据库连通性自检 |

受保护接口统一携带：

```text
Authorization: Bearer <accessToken>
```

### 6.2 注册与登录

```bash
curl -X POST http://127.0.0.1:8080/api/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"alice-pass-123"}'

curl -X POST http://127.0.0.1:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"alice-pass-123"}'
```

登录返回的 `data.accessToken` 用于后续请求。`data.expiresInSeconds` 是 token 有效期。

### 6.3 存档读写

```bash
TOKEN='<登录返回的 accessToken>'

curl http://127.0.0.1:8080/api/saves/me \
  -H "Authorization: Bearer $TOKEN"

curl -X PUT http://127.0.0.1:8080/api/saves/me \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "equipmentData": {"1": 3, "2": 7},
    "gameProgress": {"level": 4, "position": [10, 2, 30]},
    "characterStats": {"hp": 88, "ammo": 42},
    "saveVersion": 2
  }'

curl -X PATCH http://127.0.0.1:8080/api/saves/me \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"gameProgress":{"level":5}}'
```

接口路径中不接收 `userId`，服务端只使用 JWT 中的当前账号 ID 查询和写入存档，因此不存在通过修改请求参数读取他人存档的入口。

### 6.4 排行榜

```bash
curl -X PUT http://127.0.0.1:8080/api/leaderboard/me \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"combatPower":5000,"clearedStage":3,"clearProgress":75.5}'

curl 'http://127.0.0.1:8080/api/leaderboard?page=1&size=10' \
  -H "Authorization: Bearer $TOKEN"
```

排序固定为：战力降序 → 最高关卡降序 → 关卡进度降序 → 排名更新时间升序。`rank` 按分页偏移计算，不写回数据库。

### 6.5 统一错误结构

```json
{
  "success": false,
  "code": "UNAUTHORIZED",
  "message": "未登录或 token 已失效",
  "data": null,
  "timestamp": "2026-11-17T19:37:35.506"
}
```

常见业务码：

- `VALIDATION_ERROR`：参数校验失败，HTTP 400；
- `USERNAME_EXISTS`：用户名重复，HTTP 409；
- `INVALID_CREDENTIALS`：账号或密码错误，HTTP 401；
- `UNAUTHORIZED`：缺少、伪造或过期 token，HTTP 401；
- `EMPTY_SAVE_PATCH`：PATCH 未提供任何字段，HTTP 400；
- `INTERNAL_ERROR`：未预期服务端错误，HTTP 500。

## 7. JWT、BCrypt 与越权防护

### JWT 为什么能实现自动登录

JWT 由三段组成：Header、Payload、Signature。登录成功后，服务端用密钥签发一个包含 `userId`、用户名、签发时间和过期时间的 token。客户端保存 token，下次请求放入 `Authorization` 头。服务端只需重新计算签名并检查过期时间，不需要保存会话，因此可以识别“这个请求属于哪个用户”。

当前实现是无状态 JWT：退出登录由客户端删除 token；服务端没有黑名单，所以旧 token 在过期前仍能通过校验。若需要“立即失效”，后续应增加 token 版本号、黑名单或短期 access token + refresh token。

### BCrypt 为什么不能存明文

BCrypt 每次加密都会生成随机盐，并对密码做多轮计算。数据库泄露时，攻击者不能直接看到密码，也不能用一次哈希计算批量比对常见密码。校验时用 `matches(原文, 哈希)`，不能直接比较字符串。BCrypt 只使用前 72 字节，因此注册接口额外拒绝超过 72 字节的密码。

### 越权访问怎么防

受保护接口不接收客户端传入的 `userId`。`JwtAuthInterceptor` 验证 token 后，把当前用户 ID 放进请求属性；Controller 只能拿这个 ID 查询自己的存档和排行榜记录。客户端即使修改请求体，也无法改变服务端认定的当前用户。

## 8. 后续接入顺序

1. Godot 端新增 HTTP 客户端，把本地存档映射到 `/api/saves/me`；
2. 视需要增加 refresh token、token 黑名单或账号封禁；
3. 排行榜数据量上来后增加赛季、缓存或定时快照；
4. 引入 Flyway/Liquibase 管理后续表结构迁移。
