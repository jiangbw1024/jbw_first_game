package com.jbw.game.dto;

import java.time.LocalDateTime;

public record SaveResponse(
        Long userId,
        Object equipmentData,
        Object gameProgress,
        Object characterStats,
        Integer saveVersion,
        LocalDateTime updatedAt
) {
}
