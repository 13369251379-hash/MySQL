-- ============================================================================
-- MySQL 分区自动管理 - 自动发现脚本
-- 版本: 1.0
-- 说明: 扫描 information_schema.partitions, 自动发现分区表并填充配置表
-- 使用: 部署 01_setup.sql 后执行本脚本
-- ============================================================================

USE partition_mgr;

-- ============================================================================
-- 自动发现所有分区表
-- ============================================================================

INSERT INTO partition_config (
    table_schema, table_name, partition_column,
    partition_type, partition_interval, partition_prefix,
    maxvalue_part_name, retain_days, precreate_count, enabled
)
SELECT
    p.TABLE_SCHEMA,
    p.TABLE_NAME,
    -- 提取分区键字段名 (去掉反引号和 to_days/TO_DAYS 包装)
    TRIM(BOTH '`' FROM
        REPLACE(
            REPLACE(
                REPLACE(p.PARTITION_EXPRESSION, 'to_days(', ''),
                'TO_DAYS(', ''
            ),
            ')', ''
        )
    ) AS partition_column,

    -- 判断分区语法类型
    CASE
        WHEN p.PARTITION_METHOD = 'RANGE COLUMNS' THEN 'RANGE_COLUMNS'
        WHEN UPPER(p.PARTITION_EXPRESSION) LIKE '%TO_DAYS%' THEN 'RANGE_TO_DAYS'
        ELSE 'RANGE_COLUMNS'  -- 兜底
    END AS partition_type,

    -- 判断分区间隔 (通过分区名长度)
    CASE
        WHEN CHAR_LENGTH(
            (SELECT MAX(q.PARTITION_NAME)
             FROM information_schema.partitions q
             WHERE q.TABLE_SCHEMA = p.TABLE_SCHEMA
               AND q.TABLE_NAME = p.TABLE_NAME
               AND q.PARTITION_DESCRIPTION != 'MAXVALUE'
               AND q.PARTITION_NAME IS NOT NULL)
        ) <= 8 THEN 'MONTH'
        ELSE 'HALF_MONTH'
    END AS partition_interval,

    -- 提取前缀 (取第一个非 MAXVALUE 分区名的首字母)
    COALESCE(
        (SELECT LEFT(MIN(q.PARTITION_NAME), 1)
         FROM information_schema.partitions q
         WHERE q.TABLE_SCHEMA = p.TABLE_SCHEMA
           AND q.TABLE_NAME = p.TABLE_NAME
           AND q.PARTITION_DESCRIPTION != 'MAXVALUE'
           AND q.PARTITION_NAME IS NOT NULL
           AND q.PARTITION_NAME REGEXP '^[a-zA-Z]'),
        'p'
    ) AS partition_prefix,

    -- MAXVALUE 分区名
    COALESCE(
        (SELECT MAX(q.PARTITION_NAME)
         FROM information_schema.partitions q
         WHERE q.TABLE_SCHEMA = p.TABLE_SCHEMA
           AND q.TABLE_NAME = p.TABLE_NAME
           AND q.PARTITION_DESCRIPTION = 'MAXVALUE'),
        'p_future'
    ) AS maxvalue_part_name,

    -- 默认保留天数 (后续通过 config 脚本覆盖)
    15 AS retain_days,

    -- 默认预创建数量
    CASE
        WHEN CHAR_LENGTH(
            (SELECT MAX(q.PARTITION_NAME)
             FROM information_schema.partitions q
             WHERE q.TABLE_SCHEMA = p.TABLE_SCHEMA
               AND q.TABLE_NAME = p.TABLE_NAME
               AND q.PARTITION_DESCRIPTION != 'MAXVALUE'
               AND q.PARTITION_NAME IS NOT NULL)
        ) <= 8 THEN 3    -- MONTH: 预创建 3 个月
        ELSE 6             -- HALF_MONTH: 预创建 6 个半月分区
    END AS precreate_count,

    1 AS enabled

FROM information_schema.partitions p
WHERE p.TABLE_SCHEMA IN ('light_vision_radar', 'wechat_idc', 'life_radar_platform')
  AND p.PARTITION_NAME IS NOT NULL
  AND p.PARTITION_METHOD IN ('RANGE', 'RANGE COLUMNS')
GROUP BY p.TABLE_SCHEMA, p.TABLE_NAME, p.PARTITION_METHOD, p.PARTITION_EXPRESSION
-- 跳过已存在的配置
ON DUPLICATE KEY UPDATE
    maxvalue_part_name = VALUES(maxvalue_part_name),
    updated_at = CURRENT_TIMESTAMP;

-- ============================================================================
-- 显示发现结果
-- ============================================================================
SELECT
    '=== 自动发现完成 ===' AS summary,
    COUNT(*) AS total_tables
FROM partition_config;

SELECT
    id,
    table_schema AS `库`,
    table_name AS `表`,
    partition_column AS `分区键`,
    partition_type AS `分区语法`,
    partition_interval AS `分区间隔`,
    partition_prefix AS `前缀`,
    maxvalue_part_name AS `MAXVALUE分区`,
    retain_days AS `保留天`,
    precreate_count AS `预创建数`,
    enabled AS `启用`
FROM partition_config
ORDER BY table_schema, table_name;

-- ============================================================================
-- 下一步提示
-- ============================================================================
SELECT '接下来请根据环境执行 config/dev.sql 或 config/test.sql 设置保留天数' AS next_step;
