package com.jbw.game.controller;

import com.jbw.game.dto.ApiResponse;
import com.jbw.game.dto.SavePatchRequest;
import com.jbw.game.dto.SavePutRequest;
import com.jbw.game.dto.SaveResponse;
import com.jbw.game.security.AuthAttributes;
import com.jbw.game.service.PlayerSaveService;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/saves")
public class SaveController {

    private final PlayerSaveService playerSaveService;

    public SaveController(PlayerSaveService playerSaveService) {
        this.playerSaveService = playerSaveService;
    }

    @GetMapping("/me")
    public ApiResponse<SaveResponse> getMySave(
            @RequestAttribute(AuthAttributes.USER_ID) Long userId
    ) {
        return ApiResponse.success(playerSaveService.getForUser(userId));
    }

    @PutMapping("/me")
    public ApiResponse<SaveResponse> replaceMySave(
            @RequestAttribute(AuthAttributes.USER_ID) Long userId,
            @Valid @RequestBody SavePutRequest request
    ) {
        return ApiResponse.success("存档已保存", playerSaveService.replaceForUser(userId, request));
    }

    @PatchMapping("/me")
    public ApiResponse<SaveResponse> patchMySave(
            @RequestAttribute(AuthAttributes.USER_ID) Long userId,
            @Valid @RequestBody SavePatchRequest request
    ) {
        return ApiResponse.success("存档已更新", playerSaveService.patchForUser(userId, request));
    }
}
