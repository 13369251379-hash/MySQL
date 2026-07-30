-- ============================================================================
-- MySQL 分区自动管理 - 本地测试环境
-- 版本: 1.0
-- 说明: Docker MySQL 本地测试用, 创建 3 张测试表分别覆盖 3 种分区组合
-- 使用: docker exec -i mysql-test mysql -uroot -ptest123 < test/local_setup.sql
-- ============================================================================

-- 创建测试数据库
CREATE DATABASE IF NOT EXISTS test_partition
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE test_partition;

-- ============================================================================
-- 测试表 1: RANGE COLUMNS + MONTH (对应 sleep_record 等 11 张表)
-- ============================================================================
DROP TABLE IF EXISTS test_month_columns;
CREATE TABLE test_month_columns (
    id          BIGINT NOT NULL AUTO_INCREMENT,
    device_id   VARCHAR(50),
    event_time  DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00',
    data        VARCHAR(255),
    PRIMARY KEY (id, event_time),
    KEY idx_time (event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  PARTITION BY RANGE COLUMNS(event_time) (
    PARTITION p202605 VALUES LESS THAN ('2026-06-01'),
    PARTITION p202606 VALUES LESS THAN ('2026-07-01'),
    PARTITION p202607 VALUES LESS THAN ('2026-08-01'),
    PARTITION p202608 VALUES LESS THAN ('2026-09-01'),
    PARTITION p_future  VALUES LESS THAN (MAXVALUE)
);

-- 插入模拟数据 (过去 3 个月 + 当前月)
INSERT INTO test_month_columns (device_id, event_time, data) VALUES
('D001', '2026-05-15 10:00:00', 'old data - month 05'),
('D002', '2026-06-10 10:00:00', 'old data - month 06'),
('D003', '2026-07-01 10:00:00', 'recent data - month 07'),
('D004', '2026-07-25 10:00:00', 'current data - month 07'),
('D005', '2026-08-03 10:00:00', 'future data - month 08');

-- ============================================================================
-- 测试表 2: RANGE TO_DAYS + MONTH (对应 device_event_log 等 13 张表)
-- ============================================================================
DROP TABLE IF EXISTS test_month_todays;
CREATE TABLE test_month_todays (
    id          BIGINT NOT NULL AUTO_INCREMENT,
    device_id   VARCHAR(50),
    event_time  DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00',
    data        VARCHAR(255),
    PRIMARY KEY (id, event_time),
    KEY idx_time (event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  PARTITION BY RANGE (TO_DAYS(event_time)) (
    PARTITION p202605 VALUES LESS THAN (TO_DAYS('2026-06-01')),
    PARTITION p202606 VALUES LESS THAN (TO_DAYS('2026-07-01')),
    PARTITION p202607 VALUES LESS THAN (TO_DAYS('2026-08-01')),
    PARTITION p202608 VALUES LESS THAN (TO_DAYS('2026-09-01')),
    PARTITION pMaxValue VALUES LESS THAN (MAXVALUE)
);

INSERT INTO test_month_todays (device_id, event_time, data) VALUES
('D001', '2026-05-20 10:00:00', 'old - month 05'),
('D002', '2026-06-15 10:00:00', 'old - month 06'),
('D003', '2026-07-10 10:00:00', 'recent - month 07'),
('D004', '2026-07-28 10:00:00', 'current - month 07'),
('D005', '2026-08-05 10:00:00', 'future - month 08');

-- ============================================================================
-- 测试表 3: RANGE TO_DAYS + HALF_MONTH (对应 device_point_cloud)
-- ============================================================================
DROP TABLE IF EXISTS test_halfmonth_todays;
CREATE TABLE test_halfmonth_todays (
    id          BIGINT NOT NULL AUTO_INCREMENT,
    device_id   VARCHAR(50),
    event_time  DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00',
    data        VARCHAR(255),
    PRIMARY KEY (id, event_time),
    KEY idx_time (event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  PARTITION BY RANGE (TO_DAYS(event_time)) (
    PARTITION p20260701 VALUES LESS THAN (TO_DAYS('2026-07-16')),
    PARTITION p20260702 VALUES LESS THAN (TO_DAYS('2026-08-01')),
    PARTITION p20260801 VALUES LESS THAN (TO_DAYS('2026-08-16')),
    PARTITION p20260802 VALUES LESS THAN (TO_DAYS('2026-09-01')),
    PARTITION pMaxValue  VALUES LESS THAN (MAXVALUE)
);

INSERT INTO test_halfmonth_todays (device_id, event_time, data) VALUES
('D001', '2026-07-01 10:00:00', 'old - first half Jul'),
('D002', '2026-07-10 10:00:00', 'old - first half Jul'),
('D003', '2026-07-18 10:00:00', 'recent - second half Jul'),
('D004', '2026-08-01 10:00:00', 'current - first half Aug'),
('D005', '2026-08-10 10:00:00', 'future - first half Aug');

-- ============================================================================
-- 验证测试数据
-- ============================================================================
SELECT '=== 测试环境就绪 ===' AS status;

SELECT 'test_month_columns' AS tbl,
        TABLE_SCHEMA, TABLE_NAME,
        PARTITION_NAME, PARTITION_DESCRIPTION,
        TABLE_ROWS
FROM information_schema.partitions
WHERE TABLE_SCHEMA = 'test_partition'
  AND TABLE_NAME = 'test_month_columns'
ORDER BY PARTITION_ORDINAL_POSITION;

SELECT 'test_month_todays' AS tbl,
        TABLE_SCHEMA, TABLE_NAME,
        PARTITION_NAME, PARTITION_DESCRIPTION,
        TABLE_ROWS
FROM information_schema.partitions
WHERE TABLE_SCHEMA = 'test_partition'
  AND TABLE_NAME = 'test_month_todays'
ORDER BY PARTITION_ORDINAL_POSITION;

SELECT 'test_halfmonth_todays' AS tbl,
        TABLE_SCHEMA, TABLE_NAME,
        PARTITION_NAME, PARTITION_DESCRIPTION,
        TABLE_ROWS
FROM information_schema.partitions
WHERE TABLE_SCHEMA = 'test_partition'
  AND TABLE_NAME = 'test_halfmonth_todays'
ORDER BY PARTITION_ORDINAL_POSITION;
