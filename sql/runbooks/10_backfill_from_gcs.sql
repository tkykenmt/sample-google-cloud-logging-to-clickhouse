-- Runbook 10 (optional): backfill logs stored in Cloud Logging before the Pub/Sub sink existed.
-- The sink and the pipe only carry logs received after the sink was created. Older logs are copied from
-- the log bucket to Cloud Storage (gcloud logging copy), then inserted into L0 here, so MV1, the noise MV
-- and the rollup run exactly as for live logs. See docs/en/operations.md, "Backfilling existing logs".
--
-- Variables:
--   {{GCS_URL}}    copied files, e.g. https://storage.googleapis.com/<bucket>/**.json
--   {{HMAC_KEY}} / {{HMAC_SECRET}}  HMAC key of a service account with roles/storage.objectViewer on the bucket
--                  (Cloud Storage > Settings > Interoperability). The secret is masked in system.query_log.
--   {{FROM}} / {{TO}}  one chunk of receiveTimestamp, UTC. Chunks must not overlap.
--   {{T0}}         first _publish_time the live pipe delivered (Step 1)
-- Copied rows get _message_id = '' and _publish_time = receiveTimestamp (as runbook 06).
-- Rows older than the L0 TTL are written to L0 and the MVs run on the INSERT, but the background TTL
-- drop removes those parts right after (Cloud 26.6: TTLDropMerge 0.1 s after the insert; clickhouse local
-- 26.7: within 3 s). The MV target got every row.
-- So L0 cannot be the source for rebuilding the backfilled range (appendix A2): keep the copied files
-- in Cloud Storage until the backfill is verified, and re-insert from them instead.
-- Copied files (gcloud logging copy, 2026-10-05): one LogEntry JSON per line, the same shape the sink
-- publishes, under <log id>/YYYY/MM/DD/<HH:MM:SS>_<HH:MM:SS>_copy_log_entries_<op>_<region>_S0.json.
-- Copying 3 hours of _Default (151,192 entries, 116 MB in 48 files) took 76 minutes, 10 of them queued.
-- Copy from _Default leaves out logs stored only in _Required (Admin Activity and System Event audit logs).
-- Cloud (26.6): each one-hour chunk inserted in 2.5 s; every backfilled LogEntry was also in the live L1
-- of the same window, and the live rows missing from the backfill were the _Required audit logs only.
-- Verified (clickhouse local 26.7, 3,000 entries, live boundary in the middle): L1 + noise counts =
-- entries, no duplicate LogEntry identity. Without the L0 check on the boundary chunk, 319 rows were
-- duplicated in L1 and the noise counts grew by 81.

-- Step 1: where the live pipeline starts.
SELECT min(_publish_time) AS t0 FROM gcl.gcl_landing_v1 WHERE _message_id != '';

-- Step 2: check the copied files before inserting (format, count, receive range).
SELECT count(), min(rt), max(rt), countIf(NOT isValidJSON(line)) AS not_json
FROM
(
    SELECT line, parseDateTime64BestEffortOrZero(JSONExtractString(line, 'receiveTimestamp'), 3, 'UTC') AS rt
    FROM gcs('{{GCS_URL}}', '{{HMAC_KEY}}', '{{HMAC_SECRET}}', 'LineAsString', 'line String')
);

-- Step 3: chunks entirely before the boundary, X = T0 - 10 min. One chunk per INSERT, a day or less,
--   so that each finishes within the client timeout (use clickhouse client for large chunks).
INSERT INTO gcl.gcl_landing_v1 (_raw_message, _message_id, _publish_time, _attributes)
SELECT line, '', rt, map()
FROM
(
    SELECT line,
           parseDateTime64BestEffortOrZero(JSONExtractString(line, 'receiveTimestamp'), 3, 'UTC') AS rt,
           (JSONExtractString(line, 'logName'), JSONExtractString(line, 'insertId'), JSONExtractString(line, 'timestamp')) AS id
    FROM gcs('{{GCS_URL}}', '{{HMAC_KEY}}', '{{HMAC_SECRET}}', 'LineAsString', 'line String')
    WHERE rt >= toDateTime64('{{FROM}}', 3, 'UTC') AND rt < toDateTime64('{{TO}}', 3, 'UTC')
    LIMIT 1 BY id
);

-- Step 4: the boundary chunk [T0 - 10 min, T0 + 10 min). The live pipe already wrote part of it, so skip
--   LogEntries that L0 already holds. L0 (not L1) because noise rows never reach L1. The boundary is
--   recent, so these L0 rows are still within the L0 TTL.
INSERT INTO gcl.gcl_landing_v1 (_raw_message, _message_id, _publish_time, _attributes)
SELECT line, '', rt, map()
FROM
(
    SELECT line,
           parseDateTime64BestEffortOrZero(JSONExtractString(line, 'receiveTimestamp'), 3, 'UTC') AS rt,
           (JSONExtractString(line, 'logName'), JSONExtractString(line, 'insertId'), JSONExtractString(line, 'timestamp')) AS id
    FROM gcs('{{GCS_URL}}', '{{HMAC_KEY}}', '{{HMAC_SECRET}}', 'LineAsString', 'line String')
    WHERE rt >= toDateTime64('{{T0}}', 3, 'UTC') - INTERVAL 10 MINUTE
      AND rt <  toDateTime64('{{T0}}', 3, 'UTC') + INTERVAL 10 MINUTE
    LIMIT 1 BY id
)
WHERE id NOT IN
(
    SELECT (JSONExtractString(_raw_message, 'logName'), JSONExtractString(_raw_message, 'insertId'), JSONExtractString(_raw_message, 'timestamp'))
    FROM gcl.gcl_landing_v1
    WHERE _publish_time >= toDateTime64('{{T0}}', 3, 'UTC') - INTERVAL 30 MINUTE
);

-- Step 5: reconcile. Copied entries = backfilled L1 rows + backfilled noise counts, per receive hour.
--   (Compare with logEntriesCopiedCount of the copy operation, too.)
SELECT count() AS backfilled_l1 FROM gcl.gcl_logs_v1 WHERE MessageId = '';
SELECT count() - uniqExact(LogName, InsertId, Timestamp) AS duplicate_entries FROM gcl.gcl_logs_v1;   -- 0
