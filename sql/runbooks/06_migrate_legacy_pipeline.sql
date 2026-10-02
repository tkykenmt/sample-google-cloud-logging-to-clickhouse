-- Runbook 06: move an existing pipeline whose landing table has no _message_id / _publish_time
-- (e.g. only _raw_message) onto this layout, without stopping it.
-- Without _publish_time there is no exact boundary, so the cutover uses the LogEntry identity
-- (logName, insertId, timestamp) and receiveTimestamp as a stand-in for the publish time.
-- Verified on a real Cloud Logging pipeline (about 18 msg/s, 7 days in the old landing table):
--   receiveTimestamp -> Pub/Sub publish time was 0.2-2.4 s; after the cutover every hour of the
--   old and new tables held the same set of (logName, insertId, timestamp).

-- Step 1: create the new database from sql/ (L0, L1, MV1, MV2) and a new ClickPipe on the SAME topic
--   with --seek-type latest. Note the first _publish_time it delivers (T_new).
SELECT min(_publish_time) AS t_new FROM cloudlogging.gcl_landing_v1;

-- Step 2: backfill the old landing table in chunks that each finish within your client timeout
--   (6-hour chunks took about 13 s for 650k rows). Only rows received before X = T_new - 10 min.
--   Deduplicate the old table on the LogEntry identity: it holds Pub/Sub redeliveries too.
--   Generate the SQL and ASSERT that the MV body now reads the old table, not gcl_landing_v1:
--   a missed replacement silently backfills from the wrong landing table.
INSERT INTO cloudlogging.gcl_logs_v1
SELECT /* L1 columns in table order */ *
FROM
(
    -- MV body (WITH ... SELECT ...) with FROM replaced by:
    -- (SELECT _raw_message, '' AS _message_id, map() AS _attributes,
    --         parseDateTime64BestEffortOrZero(JSONExtractString(_raw_message, 'receiveTimestamp'), 3, 'UTC') AS _publish_time
    --  FROM default.logs_landing
    --  WHERE ts >= '{{CHUNK_FROM}}' AND ts < '{{CHUNK_TO}}' AND _publish_time < toDateTime64('{{X}}', 3, 'UTC')
    --  LIMIT 1 BY logName, JSONExtractString(_raw_message, 'insertId'), ts)
);
-- Backfilled rows have MessageId = '' and PublishTime = receiveTimestamp.
-- These INSERTs go through MV2, so the rollup stays consistent (unlike partition moves).

-- Step 3: fill [X, T_new + 10 min) from the old table, skipping entries the new pipe already wrote.
INSERT INTO cloudlogging.gcl_logs_v1
SELECT /* L1 columns in table order */ *
FROM
(
    -- MV body with the old-table subquery restricted to X <= _publish_time < T_new + 10 min
)
WHERE (LogName, InsertId, Timestamp) NOT IN
(
    SELECT LogName, InsertId, Timestamp FROM cloudlogging.gcl_logs_v1
    WHERE PublishTime >= toDateTime64('{{X}}', 3, 'UTC') - INTERVAL 30 MINUTE
);
-- Confirm in system.query_log that the INSERT's `tables` lists the old landing table.

-- Step 4: reconcile per hour of receiveTimestamp while both pipelines run (diff must be 0).
SELECT h, o, n, n - o AS diff
FROM
(
    SELECT toStartOfHour(parseDateTime64BestEffortOrZero(JSONExtractString(_raw_message, 'receiveTimestamp'), 3, 'UTC')) AS h,
           uniqExact(logName, JSONExtractString(_raw_message, 'insertId'), ts) AS o
    FROM default.logs_landing
    WHERE ts >= '{{DAY}}' AND parseDateTime64BestEffortOrZero(JSONExtractString(_raw_message, 'receiveTimestamp'), 3, 'UTC') < now() - INTERVAL 5 MINUTE
    GROUP BY h
) AS a
FULL OUTER JOIN
(
    SELECT toStartOfHour(ReceiveTimestamp) AS h, uniqExact(LogName, InsertId, Timestamp) AS n
    FROM cloudlogging.gcl_logs_v1
    WHERE Timestamp >= '{{DAY}}' AND ReceiveTimestamp < now() - INTERVAL 5 MINUTE
    GROUP BY h
) AS b USING (h)
ORDER BY h;
-- Run it one day at a time: a 7-day uniqExact over JSON keys exceeds the 30 s Query API timeout.

-- Step 5: switch readers (ClickStack source, stable view), then STOP the old pipe.
-- Keep the old tables until the rollback window ends; drop them only after that.
CREATE OR REPLACE VIEW cloudlogging.logs AS SELECT * FROM cloudlogging.gcl_logs_v1;
