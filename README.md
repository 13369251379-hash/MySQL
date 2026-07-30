# MySQL 分区自动管理 (mysql-data-trigger)

MySQL 8.0+ 分区表自动管理方案，基于 Event Scheduler + 存储过程，支持按月(MONTH)和半月(HALF_MONTH)两种分区间隔，兼容 `RANGE COLUMNS` 和 `RANGE (TO_DAYS)` 两种分区语法。

## 适用环境

| 环境 | 保留天数 | 数据库实例 |
|------|:---:|------|
| dev | 7 天 | 31306 |
| test | 15 天 | 32306 |

## 项目结构

```
mysql-data-trigger/
├── sql/
│   ├── 01_setup.sql           # 部署脚本: 建库、建表、存储过程、Event
│   ├── 02_discovery.sql       # 自动发现: 扫描分区表, 填充配置
│   ├── 03_preview.sql         # 预览模式: 只查不改, 上线前审核
│   └── 04_manual_cleanup.sql  # 运维工具箱: 手动执行、日志清理、诊断
├── test/
│   └── local_setup.sql        # 本地测试: Docker MySQL 测试环境
├── config/
│   ├── dev.sql                # dev 环境配置
│   └── test.sql               # test 环境配置
└── README.md
```

## 快速开始

### 1. 本地测试 (Docker)

```bash
# 启动 MySQL 容器
docker run -d --name mysql-test \
  -e MYSQL_ROOT_PASSWORD=test123 \
  -p 33060:3306 \
  mysql:8.4

# 创建测试表
docker exec -i mysql-test mysql -uroot -ptest123 < test/local_setup.sql

# 部署
docker exec -i mysql-test mysql -uroot -ptest123 < sql/01_setup.sql

# 自动发现
docker exec -i mysql-test mysql -uroot -ptest123 < sql/02_discovery.sql

# 设置本地测试参数 (保留3天, 快速验证)
docker exec -i mysql-test mysql -uroot -ptest123 -e "
  UPDATE partition_mgr.partition_config SET retain_days = 3, precreate_count = 12;
  ALTER EVENT partition_mgr.evt_auto_partition ENABLE;
"

# 预览
docker exec -i mysql-test mysql -uroot -ptest123 < sql/03_preview.sql

# 手动执行一次
docker exec -i mysql-test mysql -uroot -ptest123 -e "
  CALL partition_mgr.proc_manage_partitions();
"

# 查看日志
docker exec -i mysql-test mysql -uroot -ptest123 -e "
  SELECT * FROM partition_mgr.partition_log ORDER BY executed_at DESC LIMIT 20;
"
```

### 2. dev 环境部署

```bash
# Step 1: 部署基础结构
mysql -h <dev-host> -P 31306 -u root -p < sql/01_setup.sql

# Step 2: 自动发现分区表
mysql -h <dev-host> -P 31306 -u root -p < sql/02_discovery.sql

# Step 3: 设置 dev 环境参数 (保留7天)
mysql -h <dev-host> -P 31306 -u root -p < config/dev.sql

# Step 4: 预览, 人工确认
mysql -h <dev-host> -P 31306 -u root -p < sql/03_preview.sql

# Step 5: 确认无误, 手动执行一次
mysql -h <dev-host> -P 31306 -u root -p -e "
  CALL partition_mgr.proc_manage_partitions();
  SELECT * FROM partition_mgr.partition_log ORDER BY executed_at DESC LIMIT 10;
"

# Step 6: 启用定时任务 (每天凌晨 2:00)
mysql -h <dev-host> -P 31306 -u root -p -e "
  ALTER EVENT partition_mgr.evt_auto_partition ENABLE;
"
```

### 3. test 环境部署

与 dev 相同，Step 3 替换为:

```bash
mysql -h <test-host> -P 32306 -u root -p < config/test.sql
```

## 分区间隔说明

| 类型 | partition_interval | 分区名格式 | 边界规则 | 适用表 |
|------|:---|:--|:--|:--|
| 月分区 | `MONTH` | `pYYYYMM` | 每月 1 号 | 25 张 (如 sleep_record, device_event_log) |
| 半月分区 | `HALF_MONTH` | `pYYYYMM01` / `pYYYYMM02` | 16 号和下月 1 号 | 1 张 (device_point_cloud) |

## 分区语法说明

| 类型 | partition_type | VALUES LESS THAN 格式 |
|------|:---|:--|
| RANGE COLUMNS | `RANGE_COLUMNS` | `VALUES LESS THAN ('2026-08-01')` |
| RANGE TO_DAYS | `RANGE_TO_DAYS` | `VALUES LESS THAN (TO_DAYS('2026-08-01'))` |

## 保留策略

**选项 A (宁可多保留)**: 只删除整月/整半月数据完全过期的分区。
- 如果分区包含任何可能未过期的数据（即分区边界 > 截止日期），则保留
- 至少始终保留 1 个非 MAXVALUE 分区

## 故障排查

### Event 没有自动执行

```sql
-- 检查 Event Scheduler 是否开启
SHOW VARIABLES LIKE 'event_scheduler';

-- 如果 OFF, 开启
SET GLOBAL event_scheduler = ON;

-- 检查 Event 状态
SELECT EVENT_NAME, STATUS, LAST_EXECUTED
FROM information_schema.events
WHERE EVENT_SCHEMA = 'partition_mgr';
```

### 查看执行失败记录

```sql
SELECT table_schema, table_name, action, partition_name, error_msg, executed_at
FROM partition_mgr.partition_log
WHERE status = 'FAILED'
ORDER BY executed_at DESC
LIMIT 20;
```

### 手动执行一次

```sql
CALL partition_mgr.proc_manage_partitions();
```

### 禁用某张表的自动管理

```sql
UPDATE partition_mgr.partition_config SET enabled = 0
WHERE table_schema = '库名' AND table_name = '表名';
```

### 新加了分区表, 如何加入管理

```sql
-- 重新运行自动发现 (已有配置不会被覆盖, 仅新增)
SOURCE sql/02_discovery.sql
```

## 日志查询示例

```sql
-- 今天所有操作
SELECT * FROM partition_mgr.partition_log
WHERE DATE(executed_at) = CURDATE()
ORDER BY executed_at DESC;

-- 某张表的操作历史
SELECT action, partition_name, status, executed_at
FROM partition_mgr.partition_log
WHERE table_schema = 'light_vision_radar'
  AND table_name = 'sleep_record'
ORDER BY executed_at DESC
LIMIT 20;

-- 本月各表操作统计
SELECT table_schema, table_name, action, COUNT(*) AS cnt
FROM partition_mgr.partition_log
WHERE executed_at > DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND table_schema != 'SYSTEM'
GROUP BY table_schema, table_name, action
ORDER BY table_schema, table_name;
```

## 安全说明

- Event 部署后默认 **DISABLE**，需人工确认后手动启用
- 预览脚本 (`03_preview.sql`) 只读不写，上线前必须执行审核
- 每次操作 (ADD/DROP/SKIP) 都写入 `partition_log`，无论成功失败
- 删除操作有兜底：始终保留至少 1 个非 MAXVALUE 分区
- 可随时通过 `enabled=0` 禁用某张表的自动管理
