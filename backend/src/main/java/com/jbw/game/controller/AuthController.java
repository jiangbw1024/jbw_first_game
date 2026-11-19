package com.jbw.game.controller;

import com.jbw.game.dto.ApiResponse;
import com.jbw.game.dto.LoginRequest;
import com.jbw.game.dto.LoginResponse;
import com.jbw.game.dto.RegisterRequest;
import com.jbw.game.dto.UserResponse;
import com.jbw.game.service.AuthService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private final AuthService authService;

    public AuthController(AuthService authService) {
        this.authService = authService;
    }

    @PostMapping("/register")
    @ResponseStatus(HttpStatus.CREATED)
    public ApiResponse<UserResponse> register(@Valid @RequestBody RegisterRequest request) {
        return ApiResponse.success("注册成功", authService.register(request));
    }

    @PostMapping("/login")
    public ApiResponse<LoginResponse> login(@Valid @RequestBody LoginRequest request) {
        return ApiResponse.success("登录成功", authService.login(request));
    }

    /**
     * JWT 无服务端会话，退出登录由客户端删除 token。
     * 服务端仍保留签名与过期校验，旧 token 在过期前理论上仍可用。
     */
    @PostMapping("/logout")
    public ApiResponse<Void> logout() {
        return ApiResponse.success("已退出登录，请客户端删除本地 token", null);
    }
}
