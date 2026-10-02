-- Noise handling in the MV instead of the sink: high-volume, low-value entries are kept only as
-- per-minute counts. L0 still holds the raw rows for its TTL, so the decision can be reverted
-- (rebuild from L0) and the rate stays visible (a stopped heartbeat is itself a signal).
-- The rule lives here and in the WHERE of MV1 (sql/30): keep both in sync.
CREATE TABLE IF NOT EXISTS gcl.gcl_noise_1m_v1
(
    Minute      DateTime,
    Rule        LowCardinality(String),
    ServiceName LowCardinality(String),
    Principal   LowCardinality(String),
    Cnt         SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(Minute)
ORDER BY (Rule, ServiceName, Principal, Minute)
TTL Minute + INTERVAL {{LOGS_TTL_DAYS}} DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.gcl_noise_1m_v1_mv TO gcl.gcl_noise_1m_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
WITH
    JSONExtract(_raw_message, 'Tuple(timestamp String,
        protoPayload Tuple(serviceName String, methodName String, authenticationInfo Tuple(principalEmail String)))') AS e,
    tupleElement(e, 'protoPayload') AS p,
    tupleElement(p, 'methodName') AS method,
    parseDateTime64BestEffortOrZero(tupleElement(e, 'timestamp'), 3, 'UTC') AS ts
SELECT
    toStartOfMinute(if(ts > toDateTime64('2000-01-01 00:00:00', 3, 'UTC'), ts, _publish_time)) AS Minute,
    'k8s-lease-update' AS Rule,
    tupleElement(p, 'serviceName') AS ServiceName,
    tupleElement(tupleElement(p, 'authenticationInfo'), 'principalEmail') AS Principal,
    count() AS Cnt
FROM gcl.gcl_landing_v1
WHERE method = 'io.k8s.coordination.v1.leases.update'
GROUP BY Minute, Rule, ServiceName, Principal;
