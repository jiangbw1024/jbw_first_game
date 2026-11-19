package com.jbw.game.dto;

import jakarta.validation.constraints.Min;

public record SavePatchRequest(
        Object equipmentData,
        Object gameProgress,
        Object characterStats,

        @Min(value = 1, message = "saveVersion 必须大于 0")
        Integer saveVersion
) {
}
