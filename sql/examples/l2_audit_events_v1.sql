-- Optional L2 example used in the hands-on. Build an L2 only when L1 cannot meet a requirement
-- (docs/en/design.md, "When to build an L2").
-- Requirement this one answers: "who did what" queries filter on the operator, but the L1 sort key
-- (5-minute bucket, ServiceName, Timestamp) cannot skip by operator. The typed table sorts by operator.
-- It reads L0 (not L1), so it can be rebuilt from L0 like L1.
CREATE TABLE IF NOT EXISTS gcl.audit_events_v1
(
    Timestamp     DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    PublishTime   DateTime64(3),
    MessageId     String,
    ProjectId     LowCardinality(String),
    Principal     LowCardinality(String),
    ServiceName   LowCardinality(String),
    MethodName    LowCardinality(String),
    ResourceName  String,
    CallerIp      String,
    StatusCode    Int32,
    LogName       LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (Principal, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL {{LOGS_TTL_DAYS}} DAY
SETTINGS ttl_only_drop_parts = 1;

-- Boundary: rows published from {{T}} on. After T has passed, run l2_audit_events_v1_backfill.sql with the same T.
CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.audit_events_v1_mv TO gcl.audit_events_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
WITH
    JSONExtract(_raw_message, 'Tuple(timestamp String, logName String,
        resource Tuple(labels Map(String, String)),
        protoPayload Tuple(`@type` String, serviceName String, methodName String, resourceName String,
                           authenticationInfo Tuple(principalEmail String),
                           requestMetadata Tuple(callerIp String),
                           status Tuple(code Int32)))') AS e,
    tupleElement(e, 'protoPayload') AS p,
    parseDateTime64BestEffortOrZero(tupleElement(e, 'timestamp'), 9, 'UTC') AS ts
SELECT
    if(ts > toDateTime64('2000-01-01 00:00:00', 9, 'UTC'), ts, toDateTime64(_publish_time, 9, 'UTC')) AS Timestamp,
    _publish_time AS PublishTime,
    _message_id AS MessageId,
    if(tupleElement(tupleElement(e, 'resource'), 'labels')['project_id'] != '',
       tupleElement(tupleElement(e, 'resource'), 'labels')['project_id'],
       extract(tupleElement(e, 'logName'), '^projects/([^/]+)/')) AS ProjectId,
    tupleElement(tupleElement(p, 'authenticationInfo'), 'principalEmail') AS Principal,
    tupleElement(p, 'serviceName') AS ServiceName,
    tupleElement(p, 'methodName') AS MethodName,
    tupleElement(p, 'resourceName') AS ResourceName,
    tupleElement(tupleElement(p, 'requestMetadata'), 'callerIp') AS CallerIp,
    tupleElement(tupleElement(p, 'status'), 'code') AS StatusCode,
    tupleElement(e, 'logName') AS LogName
FROM gcl.gcl_landing_v1
WHERE position(_raw_message, 'google.cloud.audit.AuditLog') > 0
  AND endsWith(tupleElement(p, '@type'), 'google.cloud.audit.AuditLog')
  -- Same noise rule as MV1 (sql/30): the L2 reads L0, so it must drop the noise itself.
  AND tupleElement(p, 'methodName') != 'io.k8s.coordination.v1.leases.update'
  AND _publish_time >= toDateTime64('{{T}}', 3, 'UTC');
