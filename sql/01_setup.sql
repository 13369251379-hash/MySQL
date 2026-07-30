-- ============================================================================
-- MySQL 分区自动管理 - 部署脚本
-- 版本: 1.0
-- 适用版本: MySQL 8.0+
-- 说明: 创建 partition_mgr 数据库、配置表、日志表、存储过程和定时任务
-- ============================================================================

-- 1. 创建管理数据库
CREATE DATABASE IF NOT EXISTS partition_mgr
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE partition_mgr;

-- ============================================================================
-- 2. 分区配置表
-- ============================================================================
CREATE TABLE IF NOT EXISTS partition_config (
    id                  BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '主键',
    table_schema        VARCHAR(64)  NOT NULL COMMENT '库名',
    table_name          VARCHAR(64)  NOT NULL COMMENT '表名',
    partition_column    VARCHAR(128) NOT NULL COMMENT '分区键字段名',
    partition_type      VARCHAR(32)  NOT NULL COMMENT '分区语法类型: RANGE_COLUMNS | RANGE_TO_DAYS',
    partition_interval  VARCHAR(32)  NOT NULL DEFAULT 'MONTH' COMMENT '分区间隔: MONTH | HALF_MONTH',
    partition_prefix    VARCHAR(16)  NOT NULL DEFAULT 'p' COMMENT '分区名前缀',
    maxvalue_part_name  VARCHAR(64)  NOT NULL COMMENT 'MAXVALUE 分区名 (p_future / pMaxValue 等)',
    retain_days         INT          NOT NULL DEFAULT 7 COMMENT '分区保留天数',
    precreate_count     INT          NOT NULL DEFAULT 3 COMMENT '预创建数量 (MONTH=月数, HALF_MONTH=分区数)',
    enabled             TINYINT      NOT NULL DEFAULT 1 COMMENT '是否启用: 1=启用, 0=禁用',
    created_at          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_table (table_schema, table_name),
    KEY idx_enabled (enabled)
) ENGINE=InnoDB COMMENT='分区管理配置表';

-- ============================================================================
-- 3. 操作日志表
-- ============================================================================
CREATE TABLE IF NOT EXISTS partition_log (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '主键',
    table_schema    VARCHAR(64)   NOT NULL COMMENT '库名',
    table_name      VARCHAR(64)   NOT NULL COMMENT '表名',
    action          VARCHAR(32)   NOT NULL COMMENT '操作类型: ADD | DROP | SKIP',
    partition_name  VARCHAR(512)  DEFAULT NULL COMMENT '操作的分区名 (多个逗号分隔)',
    boundary_info   VARCHAR(512)  DEFAULT NULL COMMENT '分区边界信息',
    sql_text        TEXT          DEFAULT NULL COMMENT '执行的 SQL 语句',
    status          VARCHAR(16)   NOT NULL DEFAULT 'SUCCESS' COMMENT '执行状态: SUCCESS | FAILED',
    error_msg       TEXT          DEFAULT NULL COMMENT '错误信息',
    executed_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '执行时间',
    duration_ms     DECIMAL(10,2) DEFAULT NULL COMMENT '耗时 (毫秒)',
    KEY idx_table (table_schema, table_name),
    KEY idx_action (action, status),
    KEY idx_executed (executed_at),
    KEY idx_status (status, executed_at)
) ENGINE=InnoDB COMMENT='分区操作日志表';

-- ============================================================================
-- 4. 核心存储过程
-- ============================================================================

DELIMITER $$

-- --------------------------------------------------------------------------
-- 4.1 辅助函数: 解析 TO_DAYS 分区边界为 DATE
-- 输入: PARTITION_DESCRIPTION (整数或日期字符串)
-- 输出: DATE 类型
-- --------------------------------------------------------------------------
CREATE FUNCTION parse_partition_date(
    p_boundary_desc VARCHAR(255),
    p_type          VARCHAR(32)
) RETURNS DATE
    DETERMINISTIC
    READS SQL DATA
BEGIN
    DECLARE v_date DATE;

    IF p_type = 'RANGE_TO_DAYS' THEN
        -- TO_DAYS 整数 → DATE
        SET v_date = FROM_DAYS(CAST(p_boundary_desc AS UNSIGNED));
    ELSE
        -- RANGE_COLUMNS: 日期字符串 'YYYY-MM-DD'
        -- 去掉首尾空格和引号
        SET v_date = STR_TO_DATE(TRIM(BOTH '\'' FROM p_boundary_desc), '%Y-%m-%d');
    END IF;

    RETURN v_date;
END$$

-- --------------------------------------------------------------------------
-- 4.2 辅助函数: 根据分区日期和间隔类型生成下一个分区名
-- 输入: boundary_date=当前边界日期, p_interval=MONTH|HALF_MONTH, p_prefix=前缀
-- 输出: 新分区名 (如 p202609 或 p20260802)
-- --------------------------------------------------------------------------
CREATE FUNCTION generate_next_part_name(
    p_boundary_date DATE,
    p_interval      VARCHAR(32),
    p_prefix        VARCHAR(16)
) RETURNS VARCHAR(64)
    DETERMINISTIC
    NO SQL
BEGIN
    DECLARE v_part_name VARCHAR(64);
    DECLARE v_day INT;

    SET v_day = DAY(p_boundary_date);

    IF p_interval = 'MONTH' THEN
        -- 边界日期就是新分区的起始月份，分区名用该月
        -- 例如 boundary=2026-09-01 → p202609
        SET v_part_name = CONCAT(p_prefix, DATE_FORMAT(p_boundary_date, '%Y%m'));

    ELSEIF p_interval = 'HALF_MONTH' THEN
        IF v_day = 16 THEN
            -- 边界=16号 → 该月下半月分区 pYYYYMM02
            SET v_part_name = CONCAT(p_prefix, DATE_FORMAT(p_boundary_date, '%Y%m'), '02');
        ELSE
            -- 边界=1号 → 该月上半月分区 pYYYYMM01
            SET v_part_name = CONCAT(p_prefix, DATE_FORMAT(p_boundary_date, '%Y%m'), '01');
        END IF;
    END IF;

    RETURN v_part_name;
END$$

-- --------------------------------------------------------------------------
-- 4.3 辅助函数: 生成下一个边界日期
-- 输入: current_boundary=当前分区边界, p_interval=MONTH|HALF_MONTH
-- 输出: 下一个边界日期
-- --------------------------------------------------------------------------
CREATE FUNCTION generate_next_boundary(
    p_current_boundary DATE,
    p_interval         VARCHAR(32)
) RETURNS DATE
    DETERMINISTIC
    NO SQL
BEGIN
    DECLARE v_next DATE;
    DECLARE v_day INT;

    SET v_day = DAY(p_current_boundary);

    IF p_interval = 'MONTH' THEN
        -- 每月1号 → 下个月1号
        SET v_next = p_current_boundary + INTERVAL 1 MONTH;

    ELSEIF p_interval = 'HALF_MONTH' THEN
        IF v_day = 1 THEN
            -- 1号 → 本月16号
            SET v_next = DATE_ADD(p_current_boundary, INTERVAL 15 DAY);
        ELSE
            -- 16号 → 下月1号
            SET v_next = DATE_ADD(LAST_DAY(p_current_boundary), INTERVAL 1 DAY);
        END IF;
    END IF;

    RETURN v_next;
END$$

-- --------------------------------------------------------------------------
-- 4.4 辅助函数: 生成 VALUES LESS THAN 子句
-- 输入: p_boundary=边界日期, p_type=RANGE_COLUMNS|RANGE_TO_DAYS
-- 输出: VALUES LESS THAN (...) 完整子句
-- --------------------------------------------------------------------------
CREATE FUNCTION format_boundary_clause(
    p_boundary DATE,
    p_type     VARCHAR(32)
) RETURNS VARCHAR(255)
    DETERMINISTIC
    NO SQL
BEGIN
    DECLARE v_clause VARCHAR(255);

    IF p_type = 'RANGE_TO_DAYS' THEN
        SET v_clause = CONCAT('VALUES LESS THAN (TO_DAYS(''',
                              DATE_FORMAT(p_boundary, '%Y-%m-%d'), '''))');
    ELSE
        SET v_clause = CONCAT('VALUES LESS THAN (''',
                              DATE_FORMAT(p_boundary, '%Y-%m-%d'), ''')');
    END IF;

    RETURN v_clause;
END$$

-- --------------------------------------------------------------------------
-- 4.5 主存储过程: 自动分区管理
-- --------------------------------------------------------------------------
CREATE PROCEDURE proc_manage_partitions()
    MODIFIES SQL DATA
    SQL SECURITY DEFINER
BEGIN
    DECLARE v_done         INT DEFAULT FALSE;
    DECLARE v_start_ts     DATETIME(3);
    DECLARE v_op_start     DATETIME(3);
    DECLARE v_duration     DECIMAL(10,2);

    -- 配置变量
    DECLARE v_schema       VARCHAR(64);
    DECLARE v_table        VARCHAR(64);
    DECLARE v_column       VARCHAR(128);
    DECLARE v_type         VARCHAR(32);
    DECLARE v_interval     VARCHAR(32);
    DECLARE v_prefix       VARCHAR(16);
    DECLARE v_maxpart      VARCHAR(64);
    DECLARE v_retain       INT;
    DECLARE v_precreate    INT;

    -- 运行时变量
    DECLARE v_last_name    VARCHAR(64);
    DECLARE v_last_desc    VARCHAR(255);
    DECLARE v_boundary     DATE;
    DECLARE v_target       DATE;
    DECLARE v_next_bound   DATE;
    DECLARE v_new_name     VARCHAR(64);
    DECLARE v_bound_clause VARCHAR(255);
    DECLARE v_reorg_sql    TEXT;
    DECLARE v_drop_sql     VARCHAR(512);
    DECLARE v_parts_added  INT;
    DECLARE v_parts_dropped INT;
    DECLARE v_part_list    TEXT;
    DECLARE v_bound_list   TEXT;
    DECLARE v_cutoff       DATE;
    DECLARE v_drop_name    VARCHAR(64);
    DECLARE v_drop_desc    VARCHAR(255);
    DECLARE v_drop_bound   DATE;
    DECLARE v_count_after  INT;
    DECLARE v_err_msg      TEXT;

    -- 游标: 遍历启用的配置
    DECLARE cur_config CURSOR FOR
        SELECT table_schema, table_name, partition_column,
               partition_type, partition_interval, partition_prefix,
               maxvalue_part_name, retain_days, precreate_count
        FROM partition_config
        WHERE enabled = 1
        ORDER BY table_schema, table_name;

    -- 处理游标结束
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- 异常处理: 不中断整体流程，记录错误后继续
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_err_msg = MESSAGE_TEXT;
        INSERT INTO partition_log (table_schema, table_name, action, status, error_msg, duration_ms)
        VALUES (IFNULL(v_schema, 'SYSTEM'), IFNULL(v_table, 'SYSTEM'), 'ERROR', 'FAILED', v_err_msg,
                TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
    END;

    -- ======================================================================
    -- 主逻辑开始
    -- ======================================================================
    SET v_start_ts = NOW(3);

    -- 汇总日志: 开始
    INSERT INTO partition_log (table_schema, table_name, action, partition_name, status)
    VALUES ('SYSTEM', 'SYSTEM', 'INFO', '=== BATCH START ===', 'SUCCESS');

    OPEN cur_config;

    config_loop: LOOP
        FETCH cur_config INTO v_schema, v_table, v_column, v_type, v_interval,
                              v_prefix, v_maxpart, v_retain, v_precreate;

        IF v_done THEN
            LEAVE config_loop;
        END IF;

        SET v_op_start = NOW(3);

        -- ------------------------------------------------------------------
        -- Step 1: 找到最后一个非 MAXVALUE 分区及其边界
        -- ------------------------------------------------------------------
        SELECT PARTITION_NAME, PARTITION_DESCRIPTION
        INTO v_last_name, v_last_desc
        FROM information_schema.partitions
        WHERE TABLE_SCHEMA = v_schema
          AND TABLE_NAME   = v_table
          AND PARTITION_DESCRIPTION != 'MAXVALUE'
          AND PARTITION_NAME IS NOT NULL
        ORDER BY PARTITION_ORDINAL_POSITION DESC
        LIMIT 1;

        -- 如果没有非 MAXVALUE 分区 (极端情况)，跳过
        IF v_last_name IS NULL THEN
            INSERT INTO partition_log (table_schema, table_name, action, partition_name,
                                        status, error_msg, duration_ms)
            VALUES (v_schema, v_table, 'SKIP', NULL, 'FAILED',
                    'No non-MAXVALUE partition found',
                    TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
            ITERATE config_loop;
        END IF;

        -- 解析边界日期
        SET v_boundary = parse_partition_date(v_last_desc, v_type);

        IF v_boundary IS NULL THEN
            INSERT INTO partition_log (table_schema, table_name, action, partition_name,
                                        status, error_msg, duration_ms)
            VALUES (v_schema, v_table, 'SKIP', v_last_name, 'FAILED',
                    CONCAT('Cannot parse boundary: ', v_last_desc),
                    TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
            ITERATE config_loop;
        END IF;

        -- ------------------------------------------------------------------
        -- Step 2: REORGANIZE MAXVALUE — 补齐未来分区
        -- ------------------------------------------------------------------
        -- 计算目标边界日期
        IF v_interval = 'MONTH' THEN
            SET v_target = DATE_ADD(CURDATE(), INTERVAL v_precreate MONTH);
        ELSE
            -- HALF_MONTH: precreate_count 是分区个数
            SET v_target = CURDATE();
            -- 简单估算: 每月2个分区，precreate_count/2 个月
            SET v_target = DATE_ADD(v_target, INTERVAL CEIL(v_precreate / 2) MONTH);
        END IF;

        SET v_reorg_sql = '';
        SET v_parts_added = 0;
        SET v_part_list = '';
        SET v_bound_list = '';

        WHILE v_boundary < v_target DO
            -- 推算下一个边界和分区名
            SET v_next_bound = generate_next_boundary(v_boundary, v_interval);
            SET v_new_name   = generate_next_part_name(v_boundary, v_interval, v_prefix);
            SET v_bound_clause = format_boundary_clause(v_next_bound, v_type);

            -- 拼接 REORGANIZE 中的分区定义
            IF v_reorg_sql = '' THEN
                SET v_reorg_sql = CONCAT(
                    'ALTER TABLE `', v_schema, '`.`', v_table, '` ',
                    'REORGANIZE PARTITION `', v_maxpart, '` INTO (',
                    '  PARTITION `', v_new_name, '` ', v_bound_clause
                );
            ELSE
                SET v_reorg_sql = CONCAT(v_reorg_sql, ',  PARTITION `', v_new_name, '` ', v_bound_clause);
            END IF;

            -- 收集分区名列表 (用于日志)
            IF v_part_list = '' THEN
                SET v_part_list = v_new_name;
                SET v_bound_list = CONCAT(v_new_name, ':', DATE_FORMAT(v_next_bound, '%Y-%m-%d'));
            ELSE
                SET v_part_list = CONCAT(v_part_list, ',', v_new_name);
                SET v_bound_list = CONCAT(v_bound_list, ' | ', v_new_name, ':', DATE_FORMAT(v_next_bound, '%Y-%m-%d'));
            END IF;

            SET v_parts_added = v_parts_added + 1;
            SET v_boundary = v_next_bound;
        END WHILE;

        -- 如果有新分区要加
        IF v_parts_added > 0 THEN
            -- 补上 MAXVALUE 分区作为最后一个
            SET v_reorg_sql = CONCAT(v_reorg_sql, ',  PARTITION `', v_maxpart, '` VALUES LESS THAN (MAXVALUE)');
            SET v_reorg_sql = CONCAT(v_reorg_sql, ')');

            -- 执行 REORGANIZE (带错误处理)
            BLOCK_REORG: BEGIN
                DECLARE EXIT HANDLER FOR SQLEXCEPTION
                BEGIN
                    GET DIAGNOSTICS CONDITION 1 v_err_msg = MESSAGE_TEXT;
                    INSERT INTO partition_log (table_schema, table_name, action,
                                                partition_name, sql_text, status, error_msg, duration_ms)
                    VALUES (v_schema, v_table, 'ADD', v_part_list, v_reorg_sql,
                            'FAILED', v_err_msg,
                            TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
                END;

                SET @sql = v_reorg_sql;
                PREPARE stmt FROM @sql;
                EXECUTE stmt;
                DEALLOCATE PREPARE stmt;

                INSERT INTO partition_log (table_schema, table_name, action,
                                            partition_name, boundary_info, sql_text, status, duration_ms)
                VALUES (v_schema, v_table, 'ADD', v_part_list, v_bound_list,
                        v_reorg_sql, 'SUCCESS',
                        TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
            END BLOCK_REORG;
        ELSE
            INSERT INTO partition_log (table_schema, table_name, action, partition_name, status, duration_ms)
            VALUES (v_schema, v_table, 'SKIP', CONCAT('Already up to date, last=', v_last_name),
                    'SUCCESS', TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
        END IF;

        -- ------------------------------------------------------------------
        -- Step 3: DROP 过期分区
        -- ------------------------------------------------------------------
        SET v_cutoff = DATE_SUB(CURDATE(), INTERVAL v_retain DAY);

        -- 统计非 MAXVALUE 分区数 (删除前)
        SELECT COUNT(*) INTO v_count_after
        FROM information_schema.partitions
        WHERE TABLE_SCHEMA = v_schema
          AND TABLE_NAME   = v_table
          AND PARTITION_DESCRIPTION != 'MAXVALUE'
          AND PARTITION_NAME IS NOT NULL;

        SET v_parts_dropped = 0;

        -- 游标遍历所有非 MAXVALUE 分区, 按边界从小到大
        BLOCK_DROP: BEGIN
            DECLARE v_drop_done INT DEFAULT FALSE;
            DECLARE cur_drop CURSOR FOR
                SELECT PARTITION_NAME, PARTITION_DESCRIPTION
                FROM information_schema.partitions
                WHERE TABLE_SCHEMA = v_schema
                  AND TABLE_NAME   = v_table
                  AND PARTITION_DESCRIPTION != 'MAXVALUE'
                  AND PARTITION_NAME IS NOT NULL
                ORDER BY PARTITION_ORDINAL_POSITION ASC;
            DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_drop_done = TRUE;

            OPEN cur_drop;

            drop_loop: LOOP
                FETCH cur_drop INTO v_drop_name, v_drop_desc;

                IF v_drop_done THEN
                    LEAVE drop_loop;
                END IF;

                -- 解析边界日期
                SET v_drop_bound = parse_partition_date(v_drop_desc, v_type);

                IF v_drop_bound IS NULL THEN
                    ITERATE drop_loop;
                END IF;

                -- 检查是否过期: 分区的边界日期 <= 截止日期
                IF v_drop_bound <= v_cutoff THEN
                    -- 安全检查: 至少保留 1 个非 MAXVALUE 分区
                    IF v_count_after > 1 THEN
                        SET v_drop_sql = CONCAT(
                            'ALTER TABLE `', v_schema, '`.`', v_table, '` ',
                            'DROP PARTITION `', v_drop_name, '`'
                        );

                        BLOCK_DROP_EXEC: BEGIN
                            DECLARE EXIT HANDLER FOR SQLEXCEPTION
                            BEGIN
                                GET DIAGNOSTICS CONDITION 1 v_err_msg = MESSAGE_TEXT;
                                INSERT INTO partition_log (table_schema, table_name, action,
                                                            partition_name, sql_text, status, error_msg, duration_ms)
                                VALUES (v_schema, v_table, 'DROP', v_drop_name, v_drop_sql,
                                        'FAILED', v_err_msg,
                                        TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
                            END;

                            SET @sql = v_drop_sql;
                            PREPARE stmt FROM @sql;
                            EXECUTE stmt;
                            DEALLOCATE PREPARE stmt;

                            SET v_parts_dropped = v_parts_dropped + 1;
                            SET v_count_after = v_count_after - 1;

                            INSERT INTO partition_log (table_schema, table_name, action,
                                                        partition_name, sql_text, status, duration_ms)
                            VALUES (v_schema, v_table, 'DROP', v_drop_name, v_drop_sql,
                                    'SUCCESS', TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
                        END BLOCK_DROP_EXEC;
                    ELSE
                        INSERT INTO partition_log (table_schema, table_name, action,
                                                    partition_name, status, duration_ms)
                        VALUES (v_schema, v_table, 'SKIP',
                                CONCAT(v_drop_name, ' (keep last partition)'),
                                'SUCCESS', TIMESTAMPDIFF(MICROSECOND, v_op_start, NOW(3)) / 1000);
                    END IF;
                END IF;
            END LOOP;

            CLOSE cur_drop;
        END BLOCK_DROP;

        -- 如果本轮有 DROP 操作，已逐条记录; 没有则无需额外日志
        IF v_parts_dropped = 0 AND v_parts_added = 0 THEN
            -- 无事发生, 已经在上面记录了 SKIP
            BEGIN END;
        END IF;

    END LOOP config_loop;

    CLOSE cur_config;

    -- 汇总日志: 结束
    SET v_duration = TIMESTAMPDIFF(MICROSECOND, v_start_ts, NOW(3)) / 1000;
    INSERT INTO partition_log (table_schema, table_name, action, partition_name, status, duration_ms)
    VALUES ('SYSTEM', 'SYSTEM', 'INFO', CONCAT('=== BATCH END (', v_duration, ' ms) ==='), 'SUCCESS', v_duration);

END$$

DELIMITER ;

-- ============================================================================
-- 5. 定时任务 (Event Scheduler)
-- ============================================================================

-- 确保 Event Scheduler 开启
SET GLOBAL event_scheduler = ON;

-- 创建每日定时任务 (默认 DISABLE，部署确认后手动 ENABLE)
CREATE EVENT IF NOT EXISTS evt_auto_partition
    ON SCHEDULE EVERY 1 DAY
    STARTS CONCAT(CURDATE() + INTERVAL 1 DAY, ' 02:00:00')
    ON COMPLETION PRESERVE
    DISABLE
    COMMENT '每日凌晨 2:00 自动执行分区管理'
DO
    CALL partition_mgr.proc_manage_partitions();

-- ============================================================================
-- 完成
-- ============================================================================
SELECT 'partition_mgr 部署完成' AS status,
       '请执行 02_discovery.sql 自动发现分区表' AS next_step;
