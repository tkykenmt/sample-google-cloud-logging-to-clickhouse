-- MV2 (optional): per-minute counts for dashboards.
-- NOTE: partition operations (REPLACE/MOVE PARTITION) on gcl_logs_v1 do not fire this MV.
-- Any backfill or rebuild of L1 must rebuild the matching rollup partitions too (see runbooks).
CREATE TABLE IF NOT EXISTS gcl.gcl_logs_1m_v1
(
    Minute       DateTime,
    ServiceName  LowCardinality(String),
    SeverityText LowCardinality(String),
    HttpStatus   UInt16,
    Cnt          SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(Minute)
ORDER BY (Minute, ServiceName, SeverityText, HttpStatus)
TTL Minute + INTERVAL {{LOGS_TTL_DAYS}} DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.gcl_logs_1m_v1_mv TO gcl.gcl_logs_1m_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
SELECT
    toStartOfMinute(Timestamp) AS Minute,
    ServiceName,
    SeverityText,
    HttpStatus,
    count() AS Cnt
FROM gcl.gcl_logs_v1
GROUP BY Minute, ServiceName, SeverityText, HttpStatus;
