package com.jbw.game.service;

import com.jbw.game.dto.DatabaseInfoResponse;
import com.jbw.game.mapper.SystemMapper;
import org.springframework.stereotype.Service;

@Service
public class SystemService {

    private final SystemMapper systemMapper;

    public SystemService(SystemMapper systemMapper) {
        this.systemMapper = systemMapper;
    }

    public DatabaseInfoResponse databaseInfo() {
        return new DatabaseInfoResponse(
                systemMapper.selectVersion(),
                systemMapper.selectVersionComment(),
                systemMapper.selectDatabaseName(),
                systemMapper.selectCurrentUser(),
                systemMapper.selectServerTime()
        );
    }
}
