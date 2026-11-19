package com.jbw.game.service;

import com.baomidou.mybatisplus.spring.service.impl.ServiceImpl;
import com.jbw.game.entity.User;
import com.jbw.game.mapper.UserMapper;
import org.springframework.stereotype.Service;

import java.util.Optional;

@Service
public class UserService extends ServiceImpl<UserMapper, User> {

    public Optional<User> findByUsername(String username) {
        return lambdaQuery().eq(User::getUsername, username).oneOpt();
    }
}
