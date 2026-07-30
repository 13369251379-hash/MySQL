-- ============================================================================
-- MySQL 分区自动管理 - 手动运维工具箱
-- 版本: 1.0
-- 说明: 常用运维命令，无需改表时可直接使用
-- ============================================================================

USE partition_mgr;

-- ============================================================================
-- 一、手动执行一次分区整理
-- ============================================================================

-- CALL partition_mgr.proc_manage_partitions();
-- SELECT '手动执行完成，查看日志:' AS info;
-- SELECT * FROM partition_log ORDER BY executed_at DESC LIMIT 30;


-- ============================================================================
-- 二、清理日志表 (保留最近 90 天)
-- ============================================================================

-- DELETE FROM partition_log
-- WHERE executed_at < DATE_SUB(NOW(), INTERVAL 90 DAY);
-- SELECT ROW_COUNT() AS deleted_log_rows;


-- ============================================================================
-- 三、禁用 / 启用某张表的分区管理
-- ============================================================================

-- -- 禁用 sleep_record
-- UPDATE partition_config SET enabled = 0
-- WHERE table_schema = 'light_vision_radar' AND table_name = 'sleep_record';

-- -- 重新启用
-- UPDATE partition_config SET enabled = 1
-- WHERE table_schema = 'light_vision_radar' AND table_name = 'sleep_record';

-- -- 查看禁用列表
-- SELECT table_schema, table_name, updated_at
-- FROM partition_config WHERE enabled = 0;


-- ============================================================================
-- 四、调整某张表的保留天数
-- ============================================================================

-- -- 将 sleep_record 保留期改为 30 天
-- UPDATE partition_config SET retain_days = 30
-- WHERE table_schema = 'light_vision_radar' AND table_name = 'sleep_record';


-- ============================================================================
-- 五、查看 Event Scheduler 状态
-- ============================================================================

SELECT 'Event Scheduler 全局状态' AS info;
SHOW VARIABLES LIKE 'event_scheduler';

SELECT 'evt_auto_partition 状态' AS info;
SELECT
    EVENT_NAME,
    STATUS,
    EVENT_TYPE,
    INTERVAL_VALUE,
    INTERVAL_FIELD,
    STARTS,
    LAST_EXECUTED,
    EVENT_DEFINITION
FROM information_schema.events
WHERE EVENT_SCHEMA = 'partition_mgr'
  AND EVENT_NAME = 'evt_auto_partition'\G

-- -- 手动启用
-- ALTER EVENT partition_mgr.evt_auto_partition ENABLE;

-- -- 手动禁用
-- ALTER EVENT partition_mgr.evt_auto_partition DISABLE;


-- ============================================================================
-- 六、检查是否有执行失败的操作
-- ============================================================================

SELECT
    table_schema AS '库',
    table_name AS '表',
    action AS '操作',
    partition_name AS '分区',
    error_msg AS '错误',
    executed_at AS '时间'
FROM partition_log
WHERE status = 'FAILED'
  AND executed_at > DATE_SUB(NOW(), INTERVAL 7 DAY)
ORDER BY executed_at DESC;


-- ============================================================================
-- 七、统计各表分区操作频次 (最近 30 天)
-- ============================================================================

SELECT
    table_schema AS '库',
    table_name AS '表',
    action AS '操作',
    COUNT(*) AS '次数',
    MAX(executed_at) AS '最后执行时间'
FROM partition_log
WHERE executed_at > DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND table_schema != 'SYSTEM'
GROUP BY table_schema, table_name, action
ORDER BY table_schema, table_name, action;


-- ============================================================================
-- 八、查看某张表的所有操作历史
-- ============================================================================

-- SET @target_schema = 'light_vision_radar';
-- SET @target_table  = 'sleep_record';

-- SELECT
--     action, partition_name, status, error_msg,
--     executed_at, duration_ms
-- FROM partition_log
-- WHERE table_schema = @target_schema AND table_name = @target_table
-- ORDER BY executed_at DESC
-- LIMIT 50;
