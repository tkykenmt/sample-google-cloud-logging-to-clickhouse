-- Runbook 09: add an L3 (aggregate table) on top of L1 or an L2, e.g. long-range trend charts, or keeping
-- only aggregates for longer than the rows. MVs fire on INSERT only, so the past is filled by an
-- INSERT ... SELECT with the same GROUP BY. Partition operations on the source (REPLACE/MOVE PARTITION in
-- the appendix runbooks) do not fire the L3 MV: rebuild the matching L3 partitions after them.

-- Step 1: aggregate table and its MV from L1 (or an L2), limited to PublishTime >= T.
CREATE TABLE IF NOT EXISTS gcl.{{L3}}
(
    Minute       DateTime,
    LogId        LowCardinality(String),
    SeverityText LowCardinality(String),
    Cnt          SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(Minute)
ORDER BY (LogId, SeverityText, Minute)
TTL Minute + INTERVAL {{L3_TTL_DAYS}} DAY;

CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.{{L3}}_mv TO gcl.{{L3}}
DEFINER = default SQL SECURITY DEFINER
AS
SELECT toStartOfMinute(Timestamp) AS Minute, LogId, SeverityText, count() AS Cnt
FROM gcl.gcl_logs_v1
WHERE PublishTime >= toDateTime64('{{T}}', 3, 'UTC')
GROUP BY Minute, LogId, SeverityText;

-- Step 2 and 3 (fill the past, compare): 09_add_l3_backfill.sql, after T has passed.
