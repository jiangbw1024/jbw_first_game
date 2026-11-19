package com.jbw.game.dto;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;

public record LeaderboardUpdateRequest(
        @NotNull(message = "combatPower 不能为空")
        @Min(value = 0, message = "combatPower 不能为负数")
        Long combatPower,

        @NotNull(message = "clearedStage 不能为空")
        @Min(value = 0, message = "clearedStage 不能为负数")
        Integer clearedStage,

        @NotNull(message = "clearProgress 不能为空")
        @DecimalMin(value = "0.0", message = "clearProgress 不能小于 0")
        @DecimalMax(value = "100.0", message = "clearProgress 不能大于 100")
        BigDecimal clearProgress
) {
}
