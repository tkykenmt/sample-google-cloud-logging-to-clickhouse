-- Runbook 04: replace the ClickPipe itself (new subscription) without a gap.
-- Create the new pipe BEFORE T2 with seek-type latest: a new subscription receives every message
-- published after it exists, so no topic retention is needed (topic retention bills storage for all
-- messages; L0 is already the replay buffer).
-- Fallback only if the pipe could not be created before T2: enable a short topic retention (e.g. 1 day)
-- before the work, create the pipe with seek-type timestamp (< T2), and disable retention afterwards.
-- Verified: seek-type timestamp started exactly at the seek time; replay duplicates were all before T2
-- and were dropped by the boundary MV.

-- Step 1: new landing table and a boundary MV from it (T2 = now + 5..10 min).
CREATE TABLE gcl.gcl_landing_v2 AS gcl.gcl_landing_v1;
CREATE MATERIALIZED VIEW gcl.gcl_logs_v2_from_landing_v2_mv TO gcl.gcl_logs_v2
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
-- parser body ... FROM gcl.gcl_landing_v2
WHERE _publish_time >= toDateTime64('{{T2}}', 3, 'UTC');

-- Step 2: before T2, create the new ClickPipe on gcl.gcl_landing_v2 starting at latest, e.g.
--   clickhousectl cloud clickpipe create pubsub <service> --name ... --topic ... \
--     --seek-type latest --database gcl --table gcl_landing_v2 \
--     --column "_raw_message:String" --column "_message_id:String" \
--     --column "_publish_time:DateTime64(3)" --column "_attributes:Map(String, String)"

-- Step 3: cap the old MV at T2 (before T2).
ALTER TABLE gcl.gcl_logs_v2_mv MODIFY QUERY
-- parser body ... FROM gcl.gcl_landing_v1
WHERE _publish_time < toDateTime64('{{T2}}', 3, 'UTC');

-- Step 4: after T2, confirm the old landing passed T2 with no stuck batch, then STOP the old pipe.
SELECT max(_publish_time) FROM gcl.gcl_landing_v1;
SELECT count() FROM gcl.gcl_landing_v1
WHERE _publish_time < toDateTime64('{{T2}}', 3, 'UTC')
  AND _message_id NOT IN (SELECT MessageId FROM gcl.gcl_logs_v2);   -- must be 0
-- Delete the old pipe only after the rollback window (see docs/en/findings.md, "Creating the pipe and its destination").
