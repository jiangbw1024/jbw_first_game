package com.jbw.game.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/**
 * 玩家存档实体，对应 player_save 表。
 *
 * <p>三个 JSON 字段先以字符串映射，业务层负责序列化/反序列化。
 * 这样不依赖特定 JSON 库的 MyBatis 类型处理器，后续换 JSON 结构时
 * 数据库层和实体层不需要跟着改。</p>
 */
@Data
@TableName("player_save")
public class PlayerSave {

    @TableId(type = IdType.AUTO)
    private Long id;

    private Long userId;

    private String equipmentData;

    private String gameProgress;

    private String characterStats;

    private Integer saveVersion;

    private LocalDateTime createdAt;

    private LocalDateTime updatedAt;
}
