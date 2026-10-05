-- Runbook 06: move an existing pipeline whose landing table has no _message_id / _publish_time
-- (e.g. only _raw_message) onto this layout, without stopping it.
-- {{LEGACY_TABLE}} = the old landing table (e.g. default.logs_landing), {{LEGACY_TS}} = its column holding the
-- LogEntry timestamp (used for chunking; any column that bounds the rows works).
-- Without _publish_time there is no exact boundary, so the cutover uses the LogEntry identity
-- (logName, insertId, timestamp) and receiveTimestamp as a stand-in for the publish time.
-- Verified on a real Cloud Logging pipeline (about 18 msg/s, 7 days in the old landing table):
--   receiveTimestamp -> Pub/Sub publish time was 0.2-2.4 s; after the cutover every hour of the
--   old and new tables held the same set of (logName, insertId, timestamp).

-- Step 1: create the new database from sql/ (L0, L1, MV1, MV2) and a new ClickPipe on the SAME topic
--   with --seek-type latest. Note the first _publish_time it delivers (T_new).
SELECT min(_publish_time) AS t_new FROM gcl.gcl_landing_v1;

-- Step 2: backfill the old landing table in chunks that each finish within your client timeout
--   (6-hour chunks took about 13 s for 650k rows). Only rows received before X = T_new - 10 min.
--   Deduplicate the old table on the LogEntry identity: it holds Pub/Sub redeliveries too.
--   Generate the SQL and ASSERT that the MV body now reads the old table, not gcl_landing_v1:
--   a missed replacement silently backfills from the wrong landing table.
INSERT INTO gcl.gcl_logs_v1
SELECT /* L1 columns in table order */ *
FROM
(
    -- MV body (WITH ... SELECT ...) with FROM replaced by:
    -- (SELECT _raw_message, '' AS _message_id, map() AS _attributes,
    --         parseDateTime64BestEffortOrZero(JSONExtractString(_raw_message, 'receiveTimestamp'), 3, 'UTC') AS _publish_time
    --  FROM {{LEGACY_TABLE}}
    --  WHERE {{LEGACY_TS}} >= '{{CHUNK_FROM}}' AND {{LEGACY_TS}} < '{{CHUNK_TO}}' AND _publish_time < toDateTime64('{{X}}', 3, 'UTC')
    --  LIMIT 1 BY logName, JSONExtractString(_raw_message, 'insertId'), {{LEGACY_TS}})
);
-- Backfilled rows have MessageId = '' and PublishTime = receiveTimestamp.
-- These INSERTs go through MV2, so the rollup stays consistent (unlike partition moves).
-- They do NOT go through the noise MV (it reads L0), while the MV body above still drops noise rows.
-- Count them from the old table the same way, or the noise counts start at T_new:
INSERT INTO gcl.gcl_noise_1m_v1
SELECT /* gcl_noise_1m_v1 columns in table order */ *
FROM
(
    -- body of gcl_noise_1m_v1_mv (WITH ... SELECT ... GROUP BY) with FROM replaced by the same
    -- deduplicated old-table subquery as above, chunk by chunk
);

-- Step 3: fill [X, T_new + 10 min) from the old table, skipping entries the new pipe already wrote.
INSERT INTO gcl.gcl_logs_v1
SELECT /* L1 columns in table order */ *
FROM
(
    -- MV body with the old-table subquery restricted to X <= _publish_time < T_new + 10 min
)
WHERE (LogName, InsertId, Timestamp) NOT IN
(
    SELECT LogName, InsertId, Timestamp FROM gcl.gcl_logs_v1
    WHERE PublishTime >= toDateTime64('{{X}}', 3, 'UTC') - INTERVAL 30 MINUTE
);
-- Confirm in system.query_log that the INSERT's `tables` lists the old landing table.

-- Step 4: reconcile per hour of receiveTimestamp while both pipelines run (diff must be 0).
SELECT h, o, n, n - o AS diff
FROM
(
    SELECT toStartOfHour(parseDateTime64BestEffortOrZero(JSONExtractString(_raw_message, 'receiveTimestamp'), 3, 'UTC')) AS h,
           uniqExact(logName, JSONExtractString(_raw_message, 'insertId'), {{LEGACY_TS}}) AS o
    FROM {{LEGACY_TABLE}}
    WHERE {{LEGACY_TS}} >= '{{DAY}}' AND parseDateTime64BestEffortOrZero(JSONExtractString(_raw_message, 'receiveTimestamp'), 3, 'UTC') < now() - INTERVAL 5 MINUTE
      -- L1 holds no noise rows: leave them out here too (same condition as verify/checks.sql 2).
      AND JSONExtractString(_raw_message, 'protoPayload', 'methodName') != 'io.k8s.coordination.v1.leases.update'
    GROUP BY h
) AS a
FULL OUTER JOIN
(
    SELECT toStartOfHour(ReceiveTimestamp) AS h, uniqExact(LogName, InsertId, Timestamp) AS n
    FROM gcl.gcl_logs_v1
    WHERE Timestamp >= '{{DAY}}' AND ReceiveTimestamp < now() - INTERVAL 5 MINUTE
    GROUP BY h
) AS b USING (h)
ORDER BY h;
-- Run it one day at a time: a 7-day uniqExact over JSON keys exceeds the 30 s Query API timeout.

-- Step 5: switch readers (ClickStack source, stable view), then STOP the old pipe.
-- Keep the old tables until the rollback window ends; drop them only after that.
CREATE OR REPLACE VIEW gcl.logs AS SELECT * FROM gcl.gcl_logs_v1;
