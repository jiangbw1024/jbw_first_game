-- ============================================================
-- 联机沙盒 · 第一阶段数据库结构
-- 适用版本：MySQL 8.0+（本机已验证 MySQL 26.10）
-- 执行方式：
--   mysql -u root -p < sql/schema.sql
-- 说明：
--   1. 使用 IF NOT EXISTS，重复执行不会删除已有数据。
--   2. 三张表统一使用 InnoDB + utf8mb4，支持中文用户名与 JSON。
-- ============================================================

CREATE DATABASE IF NOT EXISTS `jbw_game`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE `jbw_game`;

-- ------------------------------------------------------------
-- 1. 用户账号表
-- 一个用户只有一条账号记录；id 是后续两张表关联的业务主键。
-- username 使用表默认的大小写不敏感排序规则，避免 "Alice" / "alice"
-- 注册出两个实际相同的账号。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `game_user` (
  `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '账号主键，内部关联使用',
  `username`      VARCHAR(32)     NOT NULL                COMMENT '登录用户名，唯一，大小写不敏感',
  `password_hash` VARCHAR(100)    NOT NULL                COMMENT 'BCrypt 加盐哈希，禁止存明文密码',
  `created_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '注册时间',
  `updated_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                                  ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '最后更新时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_game_user_username` (`username`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '用户账号表';

-- ------------------------------------------------------------
-- 2. 玩家存档表
-- 与 game_user 一对一：user_id 上的唯一索引保证一个账号最多一条存档。
-- 三类数据使用 JSON：
--   equipment_data  -> Godot 现有 equipment 结构（peer_id -> item_id）
--   game_progress   -> 关卡、任务、位置、朝向等进度
--   character_stats -> 生命值、背包、弹药等角色属性
-- JSON 让游戏版本迭代时不必频繁改表；需要检索的字段应另加生成列和索引。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `player_save` (
  `id`               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '存档主键',
  `user_id`          BIGINT UNSIGNED NOT NULL                COMMENT '所属账号，一对一绑定',
  `equipment_data`   JSON            NOT NULL                COMMENT '装备数据（JSON）',
  `game_progress`    JSON            NOT NULL                COMMENT '游戏进度（JSON）',
  `character_stats`  JSON            NOT NULL                COMMENT '角色属性（JSON）',
  `save_version`     INT UNSIGNED    NOT NULL DEFAULT 1      COMMENT '存档结构版本，便于后续迁移',
  `created_at`       DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '首次创建时间',
  `updated_at`       DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                                     ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '最后保存时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_player_save_user` (`user_id`),
  CONSTRAINT `fk_player_save_user`
    FOREIGN KEY (`user_id`) REFERENCES `game_user` (`id`)
    ON DELETE CASCADE
    ON UPDATE RESTRICT
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '玩家存档表，与用户一对一';

-- ------------------------------------------------------------
-- 3. 排行榜表
-- 当前设计为“当前赛季一人一条”的战力快照，user_id 唯一。
-- 排名不落库，查询时按战力、关卡、进度排序并用窗口函数计算名次；
-- 这样避免每次更新分数都去重写所有玩家名次。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `leaderboard` (
  `id`              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '排行榜记录主键',
  `user_id`         BIGINT UNSIGNED NOT NULL                COMMENT '关联账号，一人一条当前赛季记录',
  `combat_power`    BIGINT UNSIGNED NOT NULL DEFAULT 0      COMMENT '战力值，主要排序字段',
  `cleared_stage`   INT UNSIGNED    NOT NULL DEFAULT 0      COMMENT '已通关最高关卡，次级排序字段',
  `clear_progress`  DECIMAL(5, 2)   NOT NULL DEFAULT 0.00   COMMENT '当前关卡进度百分比 0.00-100.00',
  `rank_updated_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                                    ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '排名数据最后更新时间',
  `created_at`      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '首次上榜时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_leaderboard_user` (`user_id`),
  KEY `idx_leaderboard_rank` (`combat_power` DESC, `cleared_stage` DESC, `clear_progress` DESC, `rank_updated_at` ASC),
  CONSTRAINT `chk_leaderboard_progress`
    CHECK (`clear_progress` >= 0.00 AND `clear_progress` <= 100.00),
  CONSTRAINT `fk_leaderboard_user`
    FOREIGN KEY (`user_id`) REFERENCES `game_user` (`id`)
    ON DELETE CASCADE
    ON UPDATE RESTRICT
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '排行榜表，关联用户并保存战力与通关进度';
