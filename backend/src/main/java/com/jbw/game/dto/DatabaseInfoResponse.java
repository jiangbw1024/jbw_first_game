package com.jbw.game.dto;

import java.time.LocalDateTime;

/**
 * 数据库自检接口的返回结构。
 */
public record DatabaseInfoResponse(
        String version,
        String versionComment,
        String schema,
        String currentUser,
        LocalDateTime serverTime
) {
}
