-- Run after T has passed, with the same T as l2_audit_events_v1.sql.
-- Backfill the rows before T from L0, without redeliveries.
-- INSERT ... SELECT maps columns by position, so the outer SELECT lists the table columns in order.
INSERT INTO gcl.audit_events_v1
SELECT Timestamp, PublishTime, MessageId, ProjectId, Principal, ServiceName, MethodName, ResourceName, CallerIp, StatusCode, LogName
FROM
(
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
    FROM (SELECT * FROM gcl.gcl_landing_v1 WHERE _publish_time < toDateTime64('{{T}}', 3, 'UTC') LIMIT 1 BY _message_id)
    WHERE position(_raw_message, 'google.cloud.audit.AuditLog') > 0
      AND endsWith(tupleElement(p, '@type'), 'google.cloud.audit.AuditLog')
      AND tupleElement(p, 'methodName') != 'io.k8s.coordination.v1.leases.update'
);

-- Same answer as L1, cheaper: compare before pointing a dashboard at the L2.
SELECT Principal, MethodName, count() AS n FROM gcl.audit_events_v1 GROUP BY ALL ORDER BY n DESC LIMIT 10;
SELECT LogAttributes['audit.principalEmail'] AS Principal, LogAttributes['audit.methodName'] AS MethodName, count() AS n
FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName') GROUP BY ALL ORDER BY n DESC LIMIT 10;
