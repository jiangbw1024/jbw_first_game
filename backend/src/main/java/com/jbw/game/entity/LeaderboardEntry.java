package com.jbw.game.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 排行榜实体，对应 leaderboard 表。
 */
@Data
@TableName("leaderboard")
public class LeaderboardEntry {

    @TableId(type = IdType.AUTO)
    private Long id;

    private Long userId;

    private Long combatPower;

    private Integer clearedStage;

    private BigDecimal clearProgress;

    private LocalDateTime rankUpdatedAt;

    private LocalDateTime createdAt;
}
