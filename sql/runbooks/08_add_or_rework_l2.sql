-- Runbook 08: add an L2 (typed table for one log type), or rework an existing one, without stopping ingestion.
-- Add an L2 only when L1 cannot meet a requirement (speed, sort key, typed values for alerts, separate
-- retention or access). Build the table or chart on L1 first; the L2 must return the same result.
-- L2 reads L0, so the backfill reaches back only as far as the L0 retention (7 days by default).
-- Verified with sql/examples/l2_gke_upgrades_v1.sql: L1-only and L2 results were identical.

-- New L2 ------------------------------------------------------------------------------------------
-- Step 1: create the typed table (see sql/examples/l2_gke_upgrades_v1.sql), then its MV from L0
--   limited to _publish_time >= T (T = now + 5..10 min).
CREATE MATERIALIZED VIEW gcl.{{L2}}_mv TO gcl.{{L2}}
DEFINER = default SQL SECURITY DEFINER
AS
-- WITH ... SELECT ... (typed columns) ...
FROM gcl.gcl_landing_v1
WHERE ({{COND}}) AND _publish_time >= toDateTime64('{{T}}', 3, 'UTC');

-- Step 2: after T, backfill the rows before T from L0, without redeliveries.
INSERT INTO gcl.{{L2}}
SELECT /* L2 columns in table order */ *
FROM
(
    -- same WITH ... SELECT as the MV, reading
    -- FROM (SELECT * FROM gcl.gcl_landing_v1 WHERE _publish_time < toDateTime64('{{T}}', 3, 'UTC') LIMIT 1 BY _message_id)
    -- WHERE ({{COND}})
);
SELECT count(), uniqExact(MessageId) FROM gcl.{{L2}};   -- equal: no duplicates

-- Step 3: register the table as a ClickStack log source and point the tiles at it.

-- Rework an L2 (new columns, new sort key) ------------------------------------------------------------
-- Same as above with a new versioned name ({{L2}} -> {{L2_NEW}}): new table, boundary MV from L0 (>= T),
-- backfill from L0. For rows older than the L0 retention, copy them from the old L2, only before the
-- oldest publish time still in L0 so the two backfills do not overlap:
-- INSERT INTO new SELECT ... FROM old
-- WHERE PublishTime < (SELECT min(_publish_time) FROM gcl.gcl_landing_v1)   -- converting columns as needed
-- Then switch the ClickStack source, and after the rollback window:
-- DROP VIEW gcl.{{L2}}_mv; DROP TABLE gcl.{{L2}};
