-- ============================================================================
-- MySQL 分区自动管理 - 预览模式
-- 版本: 1.0
-- 说明: 只查询不修改，展示即将执行的新增/删除操作，供人工审核
-- 使用: 上生产前必须执行本脚本确认
-- ============================================================================

USE partition_mgr;

-- ============================================================================
-- 1. 配置概览
-- ============================================================================
SELECT '配置概览' AS section;
SELECT
    table_schema AS '库',
    table_name AS '表',
    partition_type AS '语法',
    partition_interval AS '间隔',
    retain_days AS '保留天数',
    precreate_count AS '预创建数',
    CASE enabled WHEN 1 THEN '启用' ELSE '禁用' END AS '状态'
FROM partition_config
ORDER BY table_schema, table_name;

-- ============================================================================
-- 2. 每张表的当前分区状态 (最后一个非 MAXVALUE 分区)
-- ============================================================================
SELECT '当前分区状态' AS section;

SELECT
    c.table_schema AS '库',
    c.table_name AS '表',
    c.partition_interval AS '间隔',
    p.PARTITION_NAME AS '最后分区',
    p.PARTITION_DESCRIPTION AS '边界值',
    CASE
        WHEN c.partition_type = 'RANGE_TO_DAYS'
        THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
        ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
    END AS '边界日期',
    CASE
        WHEN c.partition_interval = 'MONTH'
        THEN CONCAT('数据区间: ',
            DATE_FORMAT(
                DATE_SUB(
                    CASE WHEN c.partition_type = 'RANGE_TO_DAYS'
                    THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
                    ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
                    END,
                    INTERVAL 1 MONTH
                ), '%Y-%m-%d'
            ), ' ~ ',
            DATE_FORMAT(
                DATE_SUB(
                    CASE WHEN c.partition_type = 'RANGE_TO_DAYS'
                    THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
                    ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
                    END,
                    INTERVAL 1 DAY
                ), '%Y-%m-%d')
        )
        ELSE CONCAT('数据区间: ~',
            DATE_FORMAT(
                DATE_SUB(
                    CASE WHEN c.partition_type = 'RANGE_TO_DAYS'
                    THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
                    ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
                    END,
                    INTERVAL 1 DAY
                ), '%Y-%m-%d')
        )
    END AS '数据范围'
FROM partition_config c
JOIN information_schema.partitions p
    ON c.table_schema = p.TABLE_SCHEMA
   AND c.table_name = p.TABLE_NAME
WHERE c.enabled = 1
  AND p.PARTITION_DESCRIPTION != 'MAXVALUE'
  AND p.PARTITION_ORDINAL_POSITION = (
    SELECT MAX(q.PARTITION_ORDINAL_POSITION)
    FROM information_schema.partitions q
    WHERE q.TABLE_SCHEMA = c.table_schema
      AND q.TABLE_NAME = c.table_name
      AND q.PARTITION_DESCRIPTION != 'MAXVALUE'
  )
ORDER BY c.table_schema, c.table_name;

-- ============================================================================
-- 3. 各表分区数量分布
-- ============================================================================
SELECT '分区数量统计' AS section;

SELECT
    p.TABLE_SCHEMA AS '库',
    p.TABLE_NAME AS '表',
    COUNT(*) AS '总分区数',
    SUM(CASE WHEN p.PARTITION_DESCRIPTION = 'MAXVALUE' THEN 1 ELSE 0 END) AS 'MAXVALUE分区',
    SUM(CASE WHEN p.PARTITION_DESCRIPTION != 'MAXVALUE' THEN 1 ELSE 0 END) AS '数据分区数',
    MIN(CASE WHEN p.PARTITION_DESCRIPTION != 'MAXVALUE' THEN p.PARTITION_NAME END) AS '最早分区',
    MAX(CASE WHEN p.PARTITION_DESCRIPTION != 'MAXVALUE' THEN p.PARTITION_NAME END) AS '最新分区'
FROM information_schema.partitions p
WHERE p.TABLE_SCHEMA IN ('light_vision_radar', 'wechat_idc', 'life_radar_platform')
  AND p.PARTITION_NAME IS NOT NULL
GROUP BY p.TABLE_SCHEMA, p.TABLE_NAME
ORDER BY p.TABLE_SCHEMA, p.TABLE_NAME;

-- ============================================================================
-- 4. 预测: 哪些分区将被删除 (基于当前配置的保留天数)
-- ============================================================================
SELECT '预测将被删除的分区' AS section;

SELECT
    c.table_schema AS '库',
    c.table_name AS '表',
    c.retain_days AS '保留天数',
    c.partition_interval AS '间隔',
    p.PARTITION_NAME AS '分区名',
    p.PARTITION_DESCRIPTION AS '边界值',
    CASE
        WHEN c.partition_type = 'RANGE_TO_DAYS'
        THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
        ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
    END AS '边界日期',
    DATE_SUB(CURDATE(), INTERVAL c.retain_days DAY) AS '截止日期',
    CASE
        WHEN CASE
            WHEN c.partition_type = 'RANGE_TO_DAYS'
            THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
            ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
        END <= DATE_SUB(CURDATE(), INTERVAL c.retain_days DAY)
        THEN '✓ 将删除'
        ELSE '✗ 保留'
    END AS '预测操作'
FROM partition_config c
JOIN information_schema.partitions p
    ON c.table_schema = p.TABLE_SCHEMA
   AND c.table_name = p.TABLE_NAME
WHERE c.enabled = 1
  AND p.PARTITION_DESCRIPTION != 'MAXVALUE'
ORDER BY c.table_schema, c.table_name, p.PARTITION_ORDINAL_POSITION;

-- ============================================================================
-- 5. 预测: 需要新增的分区
-- ============================================================================
SELECT '预测需要新增的分区' AS section;

SELECT
    c.table_schema AS '库',
    c.table_name AS '表',
    c.partition_interval AS '间隔',
    c.precreate_count AS '预创建数',
    p.PARTITION_NAME AS '当前最后分区',
    CASE
        WHEN c.partition_type = 'RANGE_TO_DAYS'
        THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
        ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
    END AS '当前边界日期',
    CASE
        WHEN c.partition_type = 'RANGE_TO_DAYS'
        THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
        ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d')
    END < CURDATE() AS '已落后?(1=是)',
    CASE
        WHEN c.partition_interval = 'MONTH'
        THEN CONCAT('需补齐到 ', DATE_FORMAT(DATE_ADD(CURDATE(), INTERVAL c.precreate_count MONTH), '%Y-%m'), ' 共约 ',
            CAST(TIMESTAMPDIFF(MONTH,
                CASE WHEN c.partition_type = 'RANGE_TO_DAYS'
                THEN FROM_DAYS(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED))
                ELSE STR_TO_DATE(TRIM(BOTH '\'' FROM p.PARTITION_DESCRIPTION), '%Y-%m-%d') END,
                DATE_ADD(CURDATE(), INTERVAL c.precreate_count MONTH)
            ) AS CHAR), ' 个月')
        ELSE CONCAT('需补齐 ', c.precreate_count, ' 个半月分区')
    END AS '预估新增量'
FROM partition_config c
JOIN information_schema.partitions p
    ON c.table_schema = p.TABLE_SCHEMA
   AND c.table_name = p.TABLE_NAME
WHERE c.enabled = 1
  AND p.PARTITION_DESCRIPTION != 'MAXVALUE'
  AND p.PARTITION_ORDINAL_POSITION = (
    SELECT MAX(q.PARTITION_ORDINAL_POSITION)
    FROM information_schema.partitions q
    WHERE q.TABLE_SCHEMA = c.table_schema
      AND q.TABLE_NAME = c.table_name
      AND q.PARTITION_DESCRIPTION != 'MAXVALUE'
  )
ORDER BY c.table_schema, c.table_name;

-- ============================================================================
-- 6. 最近操作日志 (最近 20 条)
-- ============================================================================
SELECT '最近操作日志' AS section;

SELECT
    id,
    table_schema AS '库',
    table_name AS '表',
    action AS '操作',
    partition_name AS '分区',
    status AS '状态',
    error_msg AS '错误信息',
    executed_at AS '执行时间',
    duration_ms AS '耗时(ms)'
FROM partition_log
ORDER BY executed_at DESC
LIMIT 20;

-- ============================================================================
-- 提示
-- ============================================================================
SELECT '预览完成。确认无误后, 执行 CALL partition_mgr.proc_manage_partitions() 手动运行一次, 或 ENABLE Event 自动执行' AS next_step;
