package com.jbw.game.config;

import org.mybatis.spring.annotation.MapperScan;
import org.springframework.context.annotation.Configuration;

/**
 * MyBatis-Plus 基础配置。
 *
 * <p>Mapper 接口集中放在 com.jbw.game.mapper，避免每个接口都写 @Mapper。</p>
 */
@Configuration
@MapperScan("com.jbw.game.mapper")
public class MybatisPlusConfig {
}
