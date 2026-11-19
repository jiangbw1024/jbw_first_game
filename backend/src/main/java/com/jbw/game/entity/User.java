package com.jbw.game.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/**
 * 用户账号实体，对应 game_user 表。
 */
@Data
@TableName("game_user")
public class User {

    @TableId(type = IdType.AUTO)
    private Long id;

    private String username;

    /**
     * BCrypt 哈希，不是明文密码。
     */
    private String passwordHash;

    private LocalDateTime createdAt;

    private LocalDateTime updatedAt;
}
