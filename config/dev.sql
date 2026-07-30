-- ============================================================================
-- MySQL 分区自动管理 - dev 环境配置
-- 保留 7 天, 预创建 3 个月/6 个半月分区
-- ============================================================================

USE partition_mgr;

UPDATE partition_config SET
    retain_days     = 7,
    precreate_count = CASE WHEN partition_interval = 'MONTH' THEN 3 ELSE 6 END,
    enabled         = 1
WHERE table_schema IN ('light_vision_radar', 'wechat_idc', 'life_radar_platform');

SELECT
    table_schema AS '库',
    table_name AS '表',
    partition_interval AS '间隔',
    retain_days AS '保留天数',
    precreate_count AS '预创建数'
FROM partition_config
ORDER BY table_schema, table_name;
