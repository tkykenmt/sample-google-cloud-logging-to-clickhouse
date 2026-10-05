-- Periodic checks for the GCL -> Pub/Sub ClickPipes -> ClickHouse pipeline.
-- Run with tools/chq.py. Table names follow sql/ (v1); adjust after a Blue/Green switch.

-- 1. Ingest latency: Pub/Sub publish -> row inserted, and LogEntry timestamp -> inserted.
SELECT
    toStartOfMinute(PublishTime) AS minute,
    count() AS rows,
    round(quantile(0.5)(dateDiff('millisecond', PublishTime, InsertedAt)) / 1000, 1) AS p50_publish_to_ch_s,
    round(quantile(0.99)(dateDiff('millisecond', PublishTime, InsertedAt)) / 1000, 1) AS p99_publish_to_ch_s,
    round(quantile(0.99)(dateDiff('millisecond', Timestamp, InsertedAt)) / 1000, 1) AS p99_event_to_ch_s
FROM gcl.gcl_logs_v1
WHERE PublishTime > now() - INTERVAL 15 MINUTE
GROUP BY minute
ORDER BY minute;

-- 2. Stuck batches: rows in L0 that never reached L1 (should be 0; see sql/runbooks/05_mv_failure.sql).
SELECT count() AS stuck_rows, min(_publish_time) AS oldest
FROM gcl.gcl_landing_v1
WHERE _publish_time BETWEEN now() - INTERVAL 1 DAY AND now() - INTERVAL 2 MINUTE
  -- Rows dropped on purpose by a noise rule (sql/30 WHERE, sql/50, runbook 07) are not stuck: keep in sync.
  AND JSONExtractString(_raw_message, 'protoPayload', 'methodName') != 'io.k8s.coordination.v1.leases.update'
  AND _message_id NOT IN (
      SELECT MessageId FROM gcl.gcl_logs_v1
      WHERE PublishTime BETWEEN now() - INTERVAL 1 DAY AND now());

-- 3. Duplicates: Pub/Sub redelivery (same MessageId) vs. the same LogEntry exported twice (insertId + timestamp).
SELECT
    count() AS rows,
    rows - uniqExact(MessageId) AS dup_by_message_id,
    rows - uniqExact(ProjectId, InsertId, Timestamp) AS dup_by_insert_id
FROM gcl.gcl_logs_v1
WHERE PublishTime > now() - INTERVAL 1 DAY;

-- 4. Late arrivals (LogEntry.timestamp behind publish time): sizes rebuild windows and partition churn.
SELECT
    multiIf(d < 60, '1: <1m', d < 600, '2: 1-10m', d < 3600, '3: 10-60m', d < 86400, '4: 1-24h', '5: >24h') AS bucket,
    count() AS rows
FROM (SELECT dateDiff('second', Timestamp, PublishTime) AS d FROM gcl.gcl_logs_v1 WHERE PublishTime > now() - INTERVAL 1 DAY)
GROUP BY bucket
ORDER BY bucket;

-- 5. Parser health: rows whose body was not valid JSON, and the active parser versions.
SELECT ParserVersion, countIf(NOT ParseOk) AS invalid_json, count() AS rows
FROM gcl.gcl_logs_v1
WHERE PublishTime > now() - INTERVAL 1 DAY
GROUP BY ParserVersion;

-- 6. Failed pipe inserts (the pipe state can stay Running while a batch is being retried).
--    query_log is per replica: read every replica of the service.
SELECT toStartOfMinute(event_time) AS minute, countIf(type = 'ExceptionWhileProcessing') AS failed, countIf(type = 'QueryFinish') AS ok
FROM clusterAllReplicas('default', system.query_log)
WHERE user LIKE 'clickpipe:%' AND query_kind = 'Insert' AND event_time > now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;

-- 7. Text index use (expect idx_lower_body under Skip indexes).
-- ClickStack emits hasAllTokens (UI search) or hasToken (seen from the MCP search) on lower(Body).
-- With the ngrams(2) index, Cloud 26.6 used the index for both; clickhouse local 26.7 only for hasAllTokens.
-- Check both forms on the version you run.
EXPLAIN indexes = 1
SELECT count() FROM gcl.gcl_logs_v1
WHERE Timestamp >= now() - INTERVAL 1 HOUR AND hasAllTokens(lower(Body), 'timeout');

-- 8. Partitions, parts, compression per table (sizes L0 retention from measured bytes, not estimates).
SELECT
    table,
    uniqExact(partition) AS partitions,
    count() AS parts,
    sum(rows) AS rows,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'gcl' AND active
GROUP BY table
ORDER BY table;

-- 9. Rows per publish hour in L0, to compare with the sink's exported entry count in Cloud Monitoring
--    (logging.googleapis.com/exports/log_entry_count, filtered by resource.label.name = <sink>).
--    Verified: the hourly difference stayed under 0.1% (entries near the hour boundary).
SELECT toStartOfHour(_publish_time) AS hour, count() AS rows_l0, uniqExact(_message_id) AS messages
FROM gcl.gcl_landing_v1
WHERE _publish_time >= now() - INTERVAL 6 HOUR AND _publish_time < toStartOfHour(now())
GROUP BY hour
ORDER BY hour;
