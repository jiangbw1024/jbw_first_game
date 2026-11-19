package com.jbw.game.service;

import com.jbw.game.dto.LoginRequest;
import com.jbw.game.dto.LoginResponse;
import com.jbw.game.dto.RegisterRequest;
import com.jbw.game.dto.UserResponse;
import com.jbw.game.entity.User;
import com.jbw.game.exception.BusinessException;
import com.jbw.game.utils.JwtUtil;
import com.jbw.game.utils.PasswordUtil;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;

@Service
public class AuthService {

    private static final int BCRYPT_MAX_BYTES = 72;

    private final UserService userService;
    private final PlayerSaveService playerSaveService;
    private final JwtUtil jwtUtil;

    public AuthService(UserService userService, PlayerSaveService playerSaveService, JwtUtil jwtUtil) {
        this.userService = userService;
        this.playerSaveService = playerSaveService;
        this.jwtUtil = jwtUtil;
    }

    @Transactional
    public UserResponse register(RegisterRequest request) {
        String username = request.username().trim();
        validatePasswordBytes(request.password());

        if (userService.findByUsername(username).isPresent()) {
            throw new BusinessException(HttpStatus.CONFLICT, "USERNAME_EXISTS", "用户名已存在");
        }

        User user = new User();
        user.setUsername(username);
        user.setPasswordHash(PasswordUtil.encode(request.password()));
        try {
            userService.save(user);
        } catch (DuplicateKeyException ex) {
            throw new BusinessException(HttpStatus.CONFLICT, "USERNAME_EXISTS", "用户名已存在");
        }

        playerSaveService.createDefault(user.getId());
        User saved = userService.getById(user.getId());
        return UserResponse.from(saved == null ? user : saved);
    }

    public LoginResponse login(LoginRequest request) {
        User user = userService.findByUsername(request.username().trim())
                .orElseThrow(this::invalidCredentials);

        if (!PasswordUtil.matches(request.password(), user.getPasswordHash())) {
            throw invalidCredentials();
        }

        String token = jwtUtil.createToken(user.getId(), user.getUsername());
        return new LoginResponse(
                token,
                "Bearer",
                jwtUtil.getExpirationSeconds(),
                UserResponse.from(user)
        );
    }

    private void validatePasswordBytes(String password) {
        if (password.getBytes(StandardCharsets.UTF_8).length > BCRYPT_MAX_BYTES) {
            throw new BusinessException(
                    HttpStatus.BAD_REQUEST,
                    "PASSWORD_TOO_LONG",
                    "密码 UTF-8 长度不能超过 72 字节"
            );
        }
    }

    private BusinessException invalidCredentials() {
        return new BusinessException(
                HttpStatus.UNAUTHORIZED,
                "INVALID_CREDENTIALS",
                "用户名或密码错误"
        );
    }
}
