-- 本地开发用数据库账号。生产环境请改用独立密钥管理，并限制来源 IP。
-- 执行前先把密码替换成自己的值，并同步设置环境变量 DB_PASSWORD。

CREATE USER IF NOT EXISTS 'jbw_app'@'localhost' IDENTIFIED BY 'jbw_dev_2026';
ALTER USER 'jbw_app'@'localhost' IDENTIFIED BY 'jbw_dev_2026';

CREATE USER IF NOT EXISTS 'jbw_app'@'127.0.0.1' IDENTIFIED BY 'jbw_dev_2026';
ALTER USER 'jbw_app'@'127.0.0.1' IDENTIFIED BY 'jbw_dev_2026';

GRANT SELECT, INSERT, UPDATE, DELETE ON `jbw_game`.* TO 'jbw_app'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON `jbw_game`.* TO 'jbw_app'@'127.0.0.1';

FLUSH PRIVILEGES;
