package com.jbw.game.controller;

import com.jbw.game.dto.ApiResponse;
import com.jbw.game.dto.LeaderboardItemResponse;
import com.jbw.game.dto.LeaderboardUpdateRequest;
import com.jbw.game.dto.PageResponse;
import com.jbw.game.security.AuthAttributes;
import com.jbw.game.service.LeaderboardService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@Validated
@RestController
@RequestMapping("/api/leaderboard")
public class LeaderboardController {

    private final LeaderboardService leaderboardService;

    public LeaderboardController(LeaderboardService leaderboardService) {
        this.leaderboardService = leaderboardService;
    }

    @PutMapping("/me")
    public ApiResponse<Void> updateMyRank(
            @RequestAttribute(AuthAttributes.USER_ID) Long userId,
            @Valid @RequestBody LeaderboardUpdateRequest request
    ) {
        leaderboardService.updateForUser(userId, request);
        return ApiResponse.success("排行榜数据已更新", null);
    }

    @GetMapping
    public ApiResponse<PageResponse<LeaderboardItemResponse>> list(
            @RequestParam(defaultValue = "1") @Min(1) int page,
            @RequestParam(defaultValue = "10") @Min(1) @Max(100) int size
    ) {
        return ApiResponse.success(leaderboardService.page(page, size));
    }
}
