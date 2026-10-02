-- Runbook 03: change types / ORDER BY / PARTITION BY / engine with a new table (Blue/Green).
-- Boundary T is on _publish_time (set by Pub/Sub, before the insert), never on LogEntry.timestamp.
-- Create the new MV before T (T = now + 5..10 min): every message with _publish_time >= T is then
-- inserted after the new MV exists, and messages before T are written by the old MV.
-- Verified under load: 0 missing and 0 duplicate message IDs in v2, rollup equal to v1.

-- Step 1: new table with a permanent versioned name (never RENAME it later).
--   Copy sql/20_logs_v1.sql, rename to gcl_logs_v2, apply the change (e.g. a new ORDER BY).
-- Step 2: downstream objects of v2 first (rollup + its MV), then the boundary MV.
CREATE MATERIALIZED VIEW gcl.gcl_logs_v2_mv TO gcl.gcl_logs_v2
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
-- body of the v2 parser (WITH ... SELECT ... FROM gcl.gcl_landing_v1)
WHERE _publish_time >= toDateTime64('{{T}}', 3, 'UTC');

-- Step 3: after T, confirm v2 starts at T and nothing is stuck in v1.
SELECT min(PublishTime), max(PublishTime), count() FROM gcl.gcl_logs_v2;
SELECT max(PublishTime) FROM gcl.gcl_logs_v1;
SELECT count() FROM gcl.gcl_landing_v1
WHERE _publish_time < toDateTime64('{{T}}', 3, 'UTC')
  AND _message_id NOT IN (SELECT MessageId FROM gcl.gcl_logs_v1);   -- must be 0 (runbook 05)

-- Step 4: backfill rows before T into a work table, add them to the v2 rollup, then MOVE PARTITION.
--   Source: L0 when the change needs re-parsing and L0 still holds the range; otherwise gcl_logs_v1.
--   Late-arriving logs land in older Timestamp partitions: move every partition the work table has.
CREATE TABLE gcl.gcl_logs_v2_bf AS gcl.gcl_logs_v2;
INSERT INTO gcl.gcl_logs_v2_bf
SELECT /* v2 columns in table order */ *
FROM
(
    -- v2 parser body ... reading L0 through a deduplicating subquery:
    -- FROM (SELECT * FROM gcl.gcl_landing_v1
    --       WHERE _publish_time < toDateTime64('{{T}}', 3, 'UTC') LIMIT 1 BY _message_id)
    -- When the source is gcl_logs_v1 instead, use LIMIT 1 BY MessageId the same way.
);
-- MOVE PARTITION does not fire the v2 rollup MV: aggregate the work table first.
INSERT INTO gcl.gcl_logs_1m_v2
SELECT toStartOfMinute(Timestamp) AS Minute, ServiceName, SeverityText, HttpStatus, count() AS Cnt
FROM gcl.gcl_logs_v2_bf GROUP BY Minute, ServiceName, SeverityText, HttpStatus;
SELECT partition_id, sum(rows) FROM system.parts
WHERE database = 'gcl' AND table = 'gcl_logs_v2_bf' AND active GROUP BY partition_id ORDER BY partition_id;
ALTER TABLE gcl.gcl_logs_v2_bf MOVE PARTITION ID '{{PART}}' TO TABLE gcl.gcl_logs_v2;   -- repeat per partition
DROP TABLE gcl.gcl_logs_v2_bf;

-- Step 5: reconcile (verify/completeness.sh with a known ID set, or per-minute uniqExact(MessageId) v1 vs v2).
-- Step 6: switch readers. ClickStack: change the source table. SQL users: stable view name.
CREATE OR REPLACE VIEW gcl.logs AS SELECT * FROM gcl.gcl_logs_v2;
-- Step 7: after the rollback window, stop the old MV, then drop the old tables.
-- DROP VIEW gcl.gcl_logs_v1_mv;  DROP TABLE gcl.gcl_logs_1m_v1_mv; ...
