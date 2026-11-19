package com.jbw.game.dto;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;

public record SavePutRequest(
        @NotNull(message = "equipmentData 不能为空")
        Object equipmentData,

        @NotNull(message = "gameProgress 不能为空")
        Object gameProgress,

        @NotNull(message = "characterStats 不能为空")
        Object characterStats,

        @Min(value = 1, message = "saveVersion 必须大于 0")
        Integer saveVersion
) {
}
