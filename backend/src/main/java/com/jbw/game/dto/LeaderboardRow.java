package com.jbw.game.dto;

import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 排行榜联表查询的数据库行。
 */
@Data
public class LeaderboardRow {

    private String username;
    private Long combatPower;
    private Integer clearedStage;
    private BigDecimal clearProgress;
    private LocalDateTime rankUpdatedAt;
}
