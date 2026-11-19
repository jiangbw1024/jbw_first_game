package com.jbw.game.mapper;

import org.apache.ibatis.annotations.Select;

import java.time.LocalDateTime;

/**
 * 只用于基础设施自检的查询，不绑定业务表。
 */
public interface SystemMapper {

    @Select("SELECT VERSION()")
    String selectVersion();

    @Select("SELECT @@version_comment")
    String selectVersionComment();

    @Select("SELECT DATABASE()")
    String selectDatabaseName();

    @Select("SELECT CURRENT_USER()")
    String selectCurrentUser();

    @Select("SELECT NOW(3)")
    LocalDateTime selectServerTime();
}
