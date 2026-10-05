-- Runbook 05: detect and recover a batch blocked by an MV exception.
-- Observed behaviour (Pub/Sub ClickPipe, 26.6):
--   * the failing batch is committed to L0 but not to L1 (the INSERT fails after L0 is written);
--   * the pipe retries the same batch with backoff (10 s, 30 s, 70 s, then every 2 min);
--   * other batches keep flowing, the pipe state stays Running, the error table stays empty;
--   * after MODIFY QUERY fixes the MV, the next retry delivers the batch to L1 with no loss and
--     no duplicates (L0 deduplicates the block, MVs still run: deduplicate_blocks_in_dependent_materialized_views=1).
--   * about 60 minutes after the first failure the pipe goes Failed and stops ingesting. After fixing the MV,
--     `clickpipe start` redelivered the unacked messages with no loss, but part of the stuck batch was
--     written to L1 twice (check duplicates by MessageId afterwards).
-- The pipe state is NOT a reliable signal until it is Failed. Alert on the L0 -> L1 gap and on failed pipe inserts.

-- Gap: rows in L0 older than 2 minutes that never reached L1 (should be 0).
SELECT count() AS stuck_rows, min(_publish_time) AS oldest
FROM gcl.gcl_landing_v1
WHERE _publish_time BETWEEN now() - INTERVAL 1 DAY AND now() - INTERVAL 2 MINUTE
  -- Rows dropped on purpose by a noise rule (sql/30 WHERE, sql/50, runbook 07) are not stuck: keep in sync.
  AND JSONExtractString(_raw_message, 'protoPayload', 'methodName') != 'io.k8s.coordination.v1.leases.update'
  AND _message_id NOT IN (
      SELECT MessageId FROM gcl.gcl_logs_v1
      WHERE PublishTime BETWEEN now() - INTERVAL 1 DAY AND now());

-- Failed pipe inserts and their exceptions (query_log is per replica: read every replica).
SELECT event_time, hostName() AS replica, exception_code, substring(exception, 1, 300) AS exception, written_rows
FROM clusterAllReplicas('default', system.query_log)
WHERE user LIKE 'clickpipe:%' AND query_kind = 'Insert' AND type = 'ExceptionWhileProcessing'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC;

-- Recovery: fix the MV with ALTER TABLE ... MODIFY QUERY, wait for the next retry (<= 2 min),
-- then re-run the gap query. Do not DROP/recreate the MV: rows inserted in between would be lost.
