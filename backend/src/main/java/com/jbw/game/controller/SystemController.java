package com.jbw.game.controller;

import com.jbw.game.dto.ApiResponse;
import com.jbw.game.dto.DatabaseInfoResponse;
import com.jbw.game.service.SystemService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 基础设施自检接口。
 *
 * <p>只验证 HTTP -> Service -> Mapper -> MySQL 这条链路是否打通。</p>
 */
@RestController
@RequestMapping("/api/system")
public class SystemController {

    private final SystemService systemService;

    public SystemController(SystemService systemService) {
        this.systemService = systemService;
    }

    @GetMapping("/db-version")
    public ApiResponse<DatabaseInfoResponse> dbVersion() {
        return ApiResponse.success(systemService.databaseInfo());
    }
}
