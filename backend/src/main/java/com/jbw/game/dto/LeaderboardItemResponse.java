package com.jbw.game.dto;

import java.math.BigDecimal;
import java.time.LocalDateTime;

public record LeaderboardItemResponse(
        long rank,
        String username,
        Long combatPower,
        Integer clearedStage,
        BigDecimal clearProgress,
        LocalDateTime rankUpdatedAt
) {
}
