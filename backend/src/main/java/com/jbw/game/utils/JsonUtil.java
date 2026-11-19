package com.jbw.game.utils;

import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;

import java.util.Map;

/**
 * 存档 JSON 字段与 Java 对象之间的转换。
 */
public final class JsonUtil {

    private static final ObjectMapper MAPPER = JsonMapper.shared();

    private JsonUtil() {
    }

    public static String write(Object value) {
        try {
            return MAPPER.writeValueAsString(value);
        } catch (JacksonException ex) {
            throw new IllegalStateException("存档 JSON 序列化失败", ex);
        }
    }

    public static Object read(String json) {
        if (json == null || json.isBlank()) {
            return Map.of();
        }
        try {
            return MAPPER.readValue(json, Object.class);
        } catch (JacksonException ex) {
            throw new IllegalStateException("存档 JSON 解析失败", ex);
        }
    }
}
