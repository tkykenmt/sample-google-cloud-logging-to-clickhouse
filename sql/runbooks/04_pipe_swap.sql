-- Runbook 04: replace the ClickPipe itself (new subscription) without a gap.
-- Create the new pipe BEFORE T2 with seek-type latest: a new subscription receives every message
-- published after it exists, so no topic retention is needed (topic retention bills storage for all
-- messages; L0 is already the replay buffer).
-- Fallback only if the pipe could not be created before T2: enable a short topic retention (e.g. 1 day)
-- before the work, create the pipe with seek-type timestamp (< T2), and disable retention afterwards.
-- Verified: seek-type timestamp started exactly at the seek time; replay duplicates were all before T2
-- and were dropped by the boundary MV.
--
-- Every MV that reads the old landing table moves: MV1 (to L1), the noise MV, and any L2 MV (runbook 08).
-- {{L1}} / {{L1_MV}} = the current L1 and its MV (gcl_logs_v1 / gcl_logs_v1_mv on a fresh deployment,
-- gcl_logs_v2 / gcl_logs_v2_mv after runbook 03).

-- Step 0: list the MVs that read the old landing table. Each one gets Step 1 and Step 3.
SELECT name FROM system.tables
WHERE database = 'gcl' AND engine = 'MaterializedView' AND create_table_query LIKE '%gcl.gcl_landing_v1%';

-- Step 1: new landing table and, for each MV above, a boundary copy reading it (T2 = now + 5..10 min).
CREATE TABLE gcl.gcl_landing_v2 AS gcl.gcl_landing_v1;
CREATE MATERIALIZED VIEW gcl.{{L1}}_from_landing_v2_mv TO gcl.{{L1}}
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
-- parser body ... FROM gcl.gcl_landing_v2
WHERE (/* the current WHERE of {{L1_MV}} */) AND _publish_time >= toDateTime64('{{T2}}', 3, 'UTC');
CREATE MATERIALIZED VIEW gcl.gcl_noise_1m_v1_from_landing_v2_mv TO gcl.gcl_noise_1m_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
-- body of gcl_noise_1m_v1_mv ... FROM gcl.gcl_landing_v2
WHERE (/* the current WHERE of gcl_noise_1m_v1_mv */) AND _publish_time >= toDateTime64('{{T2}}', 3, 'UTC');
-- The same for each L2 MV: gcl.<l2>_from_landing_v2_mv TO gcl.<l2>.

-- Step 2: before T2, create the new ClickPipe on gcl.gcl_landing_v2 starting at latest.
--   Terraform: add a second clickhouse_clickpipe resource (copy of clickhouse_clickpipe.gcl with another
--   name and destination.table = "gcl_landing_v2") and apply.
--   clickhousectl: docs/en/hands-on.md, part 3 (create the ClickPipe), with --table gcl_landing_v2.

-- Step 3: cap every old MV at T2 (before T2), with its full current body.
ALTER TABLE gcl.{{L1_MV}} MODIFY QUERY
-- parser body ... FROM gcl.gcl_landing_v1
WHERE (/* the current WHERE */) AND _publish_time < toDateTime64('{{T2}}', 3, 'UTC');
ALTER TABLE gcl.gcl_noise_1m_v1_mv MODIFY QUERY
-- body ... FROM gcl.gcl_landing_v1
WHERE (/* the current WHERE */) AND _publish_time < toDateTime64('{{T2}}', 3, 'UTC');
-- The same for each L2 MV.

-- Step 4: after T2, confirm the old landing passed T2 with no stuck batch, then STOP the old pipe.
SELECT max(_publish_time) FROM gcl.gcl_landing_v1;
SELECT count() FROM gcl.gcl_landing_v1
WHERE _publish_time < toDateTime64('{{T2}}', 3, 'UTC')
  AND _publish_time >= toDateTime64('{{T2}}', 3, 'UTC') - INTERVAL 1 DAY
  AND _message_id NOT IN (SELECT MessageId FROM gcl.{{L1}} WHERE PublishTime >= toDateTime64('{{T2}}', 3, 'UTC') - INTERVAL 1 DAY)
  -- Rows dropped on purpose by a noise rule are not stuck: same condition as verify/checks.sql 2.
  AND JSONExtractString(_raw_message, 'protoPayload', 'methodName') != 'io.k8s.coordination.v1.leases.update';   -- must be 0
-- Point verify/checks.sql and the runbooks at gcl_landing_v2 from now on.
-- Delete the old pipe only after the rollback window (see docs/en/findings.md, "Creating the pipe and its destination").
