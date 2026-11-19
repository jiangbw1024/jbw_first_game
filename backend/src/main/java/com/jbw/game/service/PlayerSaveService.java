package com.jbw.game.service;

import com.baomidou.mybatisplus.spring.service.impl.ServiceImpl;
import com.jbw.game.dto.SavePatchRequest;
import com.jbw.game.dto.SavePutRequest;
import com.jbw.game.dto.SaveResponse;
import com.jbw.game.entity.PlayerSave;
import com.jbw.game.exception.BusinessException;
import com.jbw.game.mapper.PlayerSaveMapper;
import com.jbw.game.utils.JsonUtil;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.util.Optional;

@Service
public class PlayerSaveService extends ServiceImpl<PlayerSaveMapper, PlayerSave> {

    public Optional<PlayerSave> findByUserId(Long userId) {
        return lambdaQuery().eq(PlayerSave::getUserId, userId).oneOpt();
    }

    public PlayerSave getOrCreate(Long userId) {
        Optional<PlayerSave> existing = findByUserId(userId);
        if (existing.isPresent()) {
            return existing.get();
        }
        try {
            return createDefault(userId);
        } catch (DuplicateKeyException ex) {
            return findByUserId(userId).orElseThrow(() -> new BusinessException(
                    HttpStatus.INTERNAL_SERVER_ERROR, "SAVE_CREATE_FAILED", "创建默认存档失败"
            ));
        }
    }

    public PlayerSave createDefault(Long userId) {
        PlayerSave save = new PlayerSave();
        save.setUserId(userId);
        save.setEquipmentData("{}");
        save.setGameProgress("{}");
        save.setCharacterStats("{}");
        save.setSaveVersion(1);
        save(save);
        return save;
    }

    public SaveResponse getForUser(Long userId) {
        return toResponse(getOrCreate(userId));
    }

    public SaveResponse replaceForUser(Long userId, SavePutRequest request) {
        PlayerSave save = getOrCreate(userId);
        save.setEquipmentData(JsonUtil.write(request.equipmentData()));
        save.setGameProgress(JsonUtil.write(request.gameProgress()));
        save.setCharacterStats(JsonUtil.write(request.characterStats()));
        save.setSaveVersion(request.saveVersion() == null ? 1 : request.saveVersion());
        updateById(save);
        return toResponse(save);
    }

    public SaveResponse patchForUser(Long userId, SavePatchRequest request) {
        if (request.equipmentData() == null
                && request.gameProgress() == null
                && request.characterStats() == null
                && request.saveVersion() == null) {
            throw new BusinessException(
                    HttpStatus.BAD_REQUEST,
                    "EMPTY_SAVE_PATCH",
                    "至少提供一个要更新的字段"
            );
        }

        PlayerSave save = getOrCreate(userId);
        if (request.equipmentData() != null) {
            save.setEquipmentData(JsonUtil.write(request.equipmentData()));
        }
        if (request.gameProgress() != null) {
            save.setGameProgress(JsonUtil.write(request.gameProgress()));
        }
        if (request.characterStats() != null) {
            save.setCharacterStats(JsonUtil.write(request.characterStats()));
        }
        if (request.saveVersion() != null) {
            save.setSaveVersion(request.saveVersion());
        }
        updateById(save);
        return toResponse(save);
    }

    private SaveResponse toResponse(PlayerSave save) {
        return new SaveResponse(
                save.getUserId(),
                JsonUtil.read(save.getEquipmentData()),
                JsonUtil.read(save.getGameProgress()),
                JsonUtil.read(save.getCharacterStats()),
                save.getSaveVersion(),
                save.getUpdatedAt()
        );
    }
}
