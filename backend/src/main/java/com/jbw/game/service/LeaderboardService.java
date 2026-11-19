package com.jbw.game.service;

import com.baomidou.mybatisplus.spring.service.impl.ServiceImpl;
import com.jbw.game.dto.LeaderboardItemResponse;
import com.jbw.game.dto.LeaderboardRow;
import com.jbw.game.dto.LeaderboardUpdateRequest;
import com.jbw.game.dto.PageResponse;
import com.jbw.game.entity.LeaderboardEntry;
import com.jbw.game.mapper.LeaderboardMapper;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

@Service
public class LeaderboardService extends ServiceImpl<LeaderboardMapper, LeaderboardEntry> {

    public Optional<LeaderboardEntry> findByUserId(Long userId) {
        return lambdaQuery().eq(LeaderboardEntry::getUserId, userId).oneOpt();
    }

    public LeaderboardEntry updateForUser(Long userId, LeaderboardUpdateRequest request) {
        LeaderboardEntry entry = findByUserId(userId).orElseGet(() -> {
            LeaderboardEntry created = new LeaderboardEntry();
            created.setUserId(userId);
            return created;
        });
        entry.setCombatPower(request.combatPower());
        entry.setClearedStage(request.clearedStage());
        entry.setClearProgress(request.clearProgress());
        entry.setRankUpdatedAt(LocalDateTime.now());

        if (entry.getId() == null) {
            save(entry);
        } else {
            updateById(entry);
        }
        return entry;
    }

    public PageResponse<LeaderboardItemResponse> page(int page, int size) {
        long total = baseMapper.countRanking();
        long offset = (long) (page - 1) * size;
        List<LeaderboardRow> rows = total == 0
                ? List.of()
                : baseMapper.selectRanking(size, offset);

        List<LeaderboardItemResponse> items = new ArrayList<>(rows.size());
        long rank = offset + 1;
        for (LeaderboardRow row : rows) {
            items.add(new LeaderboardItemResponse(
                    rank++,
                    row.getUsername(),
                    row.getCombatPower(),
                    row.getClearedStage(),
                    row.getClearProgress(),
                    row.getRankUpdatedAt()
            ));
        }
        return PageResponse.of(items, page, size, total);
    }
}
