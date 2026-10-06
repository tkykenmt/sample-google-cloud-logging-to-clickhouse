-- Runbook 07: add a noise rule without stopping ingestion.
-- Rows matching the rule stop going to L1 and are kept only as per-minute counts in gcl_noise_1m_v1.
-- Boundary T is on _publish_time: rows before T still go to L1, rows from T are counted instead.
-- {{RULE}} = rule name, {{COND}} = condition on the raw L0 message, e.g.
--   position(_raw_message, 'HTTP status=200') > 0 AND position(_raw_message, 'fluentbit') > 0
-- Verified (clickhouse local 26.7, TZ=UTC): a matching row after T is counted, one before T is not.

-- Step 1: choose T = now + 5..10 min (UTC) and write the condition so that it matches only the noise
--   (test it on L0 first: SELECT count() FROM gcl.gcl_landing_v1 WHERE ({{COND}}) AND _publish_time > now() - INTERVAL 1 HOUR).
--   After T, add the same condition everywhere noise is excluded from a "must be 0" check:
--   verify/checks.sql 2, runbooks 03 (Step 3), 04 (Step 4), 05, 06 (Step 4) and verify/local_e2e.sh check 10.
--   Rows matching both COND and the Lease rule are counted as k8s-lease-update (multiIf order), so leave
--   Lease updates out of COND, or the Step 4 comparison below will not match.

-- Step 2: start counting the new rule from T (the existing rule keeps counting).
ALTER TABLE gcl.gcl_noise_1m_v1_mv MODIFY QUERY
WITH
    JSONExtract(_raw_message, 'Tuple(timestamp String,
        protoPayload Tuple(serviceName String, methodName String, authenticationInfo Tuple(principalEmail String)))') AS e,
    tupleElement(e, 'protoPayload') AS p,
    tupleElement(p, 'methodName') AS method,
    parseDateTime64BestEffortOrZero(tupleElement(e, 'timestamp'), 3, 'UTC') AS ts,
    multiIf(method = 'io.k8s.coordination.v1.leases.update', 'k8s-lease-update',
            ({{COND}}) AND _publish_time >= toDateTime64('{{T}}', 3, 'UTC'), '{{RULE}}',
            '') AS rule
SELECT
    toStartOfMinute(if(ts > toDateTime64('2000-01-01 00:00:00', 3, 'UTC'), ts, _publish_time)) AS Minute,
    rule AS Rule,
    tupleElement(p, 'serviceName') AS ServiceName,
    tupleElement(tupleElement(p, 'authenticationInfo'), 'principalEmail') AS Principal,
    count() AS Cnt
FROM gcl.gcl_landing_v1
WHERE rule != ''
GROUP BY Minute, Rule, ServiceName, Principal;

-- Step 3: with the same T, exclude the rule from MV1 (paste the full body of the current MV1).
ALTER TABLE gcl.gcl_logs_v1_mv MODIFY QUERY
WITH
    -- ... body of the current MV1 ...
SELECT
    -- ... columns of the current MV1 ...
FROM gcl.gcl_landing_v1
WHERE tupleElement(audit, 'methodName') != 'io.k8s.coordination.v1.leases.update'
  AND NOT (({{COND}}) AND _publish_time >= toDateTime64('{{T}}', 3, 'UTC'));

-- Step 4: after T, the counted rows match L0 for a closed window.
-- Minute is based on the LogEntry timestamp and L0 on the publish time: compare a window with margins.
SELECT sum(Cnt) FROM gcl.gcl_noise_1m_v1
WHERE Rule = '{{RULE}}' AND Minute >= '{{W_FROM}}' AND Minute < '{{W_TO}}';
SELECT count() FROM gcl.gcl_landing_v1
WHERE ({{COND}}) AND _publish_time >= toDateTime64('{{T}}', 3, 'UTC')
  AND _publish_time >= '{{W_FROM}}' AND _publish_time < '{{W_TO}}';
-- Rollback: remove the condition from MV1 with MODIFY QUERY. Rows excluded meanwhile can be rebuilt
-- from L0 within its retention (runbook 02).
