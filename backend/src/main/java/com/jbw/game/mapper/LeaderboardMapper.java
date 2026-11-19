package com.jbw.game.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.jbw.game.dto.LeaderboardRow;
import com.jbw.game.entity.LeaderboardEntry;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

import java.util.List;

public interface LeaderboardMapper extends BaseMapper<LeaderboardEntry> {

    @Select("""
            SELECT u.username,
                   l.combat_power,
                   l.cleared_stage,
                   l.clear_progress,
                   l.rank_updated_at
            FROM leaderboard l
            JOIN game_user u ON u.id = l.user_id
            ORDER BY l.combat_power DESC,
                     l.cleared_stage DESC,
                     l.clear_progress DESC,
                     l.rank_updated_at ASC,
                     l.user_id ASC
            LIMIT #{limit} OFFSET #{offset}
            """)
    List<LeaderboardRow> selectRanking(@Param("limit") int limit, @Param("offset") long offset);

    @Select("SELECT COUNT(*) FROM leaderboard")
    long countRanking();
}
