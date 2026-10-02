-- MV1: L0 -> L1. The LogEntry is parsed once into a named Tuple instead of calling JSONExtract
-- per field (2.7x less CPU on real audit-heavy logs, 3.7x on synthetic mixed logs).
-- Only non-throwing functions are used: an exception here blocks the batch (see runbooks/05).
-- SQL SECURITY DEFINER lets the ClickPipe run with "Only destination table" (INSERT on L0 only).
-- Parser v7: the LogEntry envelope is fixed (columns), the payload is open (attributes). Nothing assumes a
-- specific log type: audit fields are added only for AuditLog payloads, envelope fields without a column go to
-- entry.* / http.* / operation.* attributes, and ServiceName / Body always fall back to something non-empty.
CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.gcl_logs_v1_mv TO gcl.gcl_logs_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
WITH
    JSONExtract(_raw_message, 'Tuple(
        timestamp String, receiveTimestamp String, severity String, logName String, insertId String,
        resource Tuple(type String, labels Map(String, String)),
        labels Map(String, String),
        textPayload String, jsonPayload String, protoPayload String,
        trace String, spanId String, traceSampled Bool,
        httpRequest Tuple(requestMethod String, requestUrl String, status UInt16, userAgent String, remoteIp String, latency String),
        sourceLocation Tuple(file String, line String, function String),
        operation Tuple(id String, producer String))') AS e,
    tupleElement(e, 'resource') AS res,
    tupleElement(res, 'type') AS res_type,
    tupleElement(res, 'labels') AS res_labels,
    tupleElement(e, 'labels') AS entry_labels,
    tupleElement(e, 'severity') AS sev,
    tupleElement(e, 'logName') AS log_name,
    tupleElement(e, 'textPayload') AS text_payload,
    tupleElement(e, 'jsonPayload') AS json_payload,
    tupleElement(e, 'protoPayload') AS proto_payload,
    JSONExtract(json_payload, 'Map(String, String)') AS json_map,
    JSONExtractString(proto_payload, '@type') AS proto_type,
    endsWith(proto_type, 'google.cloud.audit.AuditLog') AS is_audit,
    -- Envelope fields without a column (split, errorGroups, apphub*, otel, metadata, and any future field).
    -- Values are stringified; objects and arrays stay as JSON text. Parsed only when such a field exists.
    arrayFilter(k -> NOT has(['logName', 'resource', 'timestamp', 'receiveTimestamp', 'severity', 'insertId', 'labels',
                              'textPayload', 'jsonPayload', 'protoPayload', 'trace', 'spanId', 'traceSampled',
                              'httpRequest', 'sourceLocation', 'operation'], k),
                JSONExtractKeys(_raw_message)) AS extra_keys,
    if(empty(extra_keys), map(),
       mapApply((k, v) -> (concat('entry.', k), v),
                mapFilter((k, v) -> has(extra_keys, k) AND v != '', JSONExtract(_raw_message, 'Map(String, String)')))) AS entry_map,
    JSONExtract(proto_payload, 'Tuple(
        serviceName String, methodName String, resourceName String,
        authenticationInfo Tuple(principalEmail String),
        requestMetadata Tuple(callerIp String, callerSuppliedUserAgent String),
        status Tuple(code Int64, message String))') AS audit,
    -- Audit log fields used for filtering in ClickStack (empty values are dropped).
    mapFilter((k, v) -> v != '', map(
        'audit.methodName',     tupleElement(audit, 'methodName'),
        'audit.resourceName',   tupleElement(audit, 'resourceName'),
        'audit.principalEmail', tupleElement(tupleElement(audit, 'authenticationInfo'), 'principalEmail'),
        'audit.callerIp',       tupleElement(tupleElement(audit, 'requestMetadata'), 'callerIp'),
        'audit.userAgent',      tupleElement(tupleElement(audit, 'requestMetadata'), 'callerSuppliedUserAgent'),
        'audit.statusCode',     if(tupleElement(tupleElement(audit, 'status'), 'code') != 0,
                                   toString(tupleElement(tupleElement(audit, 'status'), 'code')), ''))) AS audit_all,
    if(is_audit, audit_all, map()) AS audit_map,
    tupleElement(e, 'httpRequest') AS http,
    -- httpRequest and operation fields without a column (responseSize, referer, protocol, cacheHit, first, last, ...).
    if(tupleElement(http, 'requestMethod') = '' AND tupleElement(http, 'status') = 0, map(),
       mapApply((k, v) -> (concat('http.', k), v),
                mapFilter((k, v) -> NOT has(['requestMethod', 'requestUrl', 'status', 'userAgent', 'remoteIp', 'latency'], k) AND v != '',
                          JSONExtract(JSONExtractRaw(_raw_message, 'httpRequest'), 'Map(String, String)')))) AS http_map,
    if(tupleElement(tupleElement(e, 'operation'), 'id') = '', map(),
       mapApply((k, v) -> (concat('operation.', k), v),
                mapFilter((k, v) -> NOT has(['id', 'producer'], k) AND v != '',
                          JSONExtract(JSONExtractRaw(_raw_message, 'operation'), 'Map(String, String)')))) AS op_map,
    tupleElement(e, 'sourceLocation') AS src,
    parseDateTime64BestEffortOrZero(tupleElement(e, 'timestamp'), 9, 'UTC') AS ts_parsed,
    decodeURLComponent(extract(log_name, '/logs/(.+)$')) AS log_id,
    -- Body: the first readable summary; never empty.
    multiIf(
        text_payload != '',                       text_payload,
        mapContains(json_map, 'message'),         json_map['message'],
        mapContains(json_map, 'msg'),             json_map['msg'],
        is_audit,                                 concat(tupleElement(audit, 'serviceName'), ' ', tupleElement(audit, 'methodName')),
        tupleElement(http, 'requestMethod') != '',
            concat(tupleElement(http, 'requestMethod'), ' ', toString(tupleElement(http, 'status')), ' ', tupleElement(http, 'requestUrl')),
        json_payload != '',                       json_payload,
        proto_payload != '',                      concat('[', replaceRegexpOne(proto_type, '^.*/', ''), '] ', substring(proto_payload, 1, 2000)),
        concat('[', log_id, ']')) AS body,
    -- klog / logfmt style bodies (key="value" pairs) become kv.* attributes; latency also as milliseconds.
    if(position(body, '="') > 0, extractKeyValuePairs(body, '=', ' ', '"'), map()) AS kv,
    mapConcat(mapApply((k, v) -> (concat('kv.', k), v), kv),
              if(mapContains(kv, 'latency'),
                 map('kv.latency_ms', toString(round(multiIf(endsWith(kv['latency'], 'ms'), toFloat64OrZero(replaceOne(kv['latency'], 'ms', '')),
                                                             endsWith(kv['latency'], 'µs'), toFloat64OrZero(replaceOne(kv['latency'], 'µs', '')) / 1000,
                                                             endsWith(kv['latency'], 's'), toFloat64OrZero(replaceOne(kv['latency'], 's', '')) * 1000, 0), 3))),
                 map())) AS kv_map
SELECT
    if(ts_parsed > toDateTime64('2000-01-01 00:00:00', 9, 'UTC'), ts_parsed, toDateTime64(_publish_time, 9, 'UTC')) AS Timestamp,
    parseDateTime64BestEffortOrZero(tupleElement(e, 'receiveTimestamp'), 9, 'UTC') AS ReceiveTimestamp,
    _publish_time AS PublishTime,
    now64(3) AS InsertedAt,
    if(sev = '', 'DEFAULT', sev) AS SeverityText,
    toUInt8(multiIf(sev = 'DEBUG', 5, sev = 'INFO', 9, sev = 'NOTICE', 10, sev = 'WARNING', 13,
                    sev = 'ERROR', 17, sev = 'CRITICAL', 18, sev = 'ALERT', 19, sev = 'EMERGENCY', 21, 0)) AS SeverityNumber,
    multiIf(
        -- Audit logs first: the API service is what audit queries filter on, whatever the resource.
        is_audit AND tupleElement(audit, 'serviceName') != '', tupleElement(audit, 'serviceName'),
        res_type = 'k8s_container' AND res_labels['container_name'] != '',
                                         concat(res_labels['namespace_name'], '/', res_labels['container_name']),
        res_type = 'cloud_run_revision', res_labels['service_name'],
        res_type = 'cloud_function',     res_labels['function_name'],
        res_type = 'gae_app',            res_labels['module_id'],
        res_type = 'gce_instance',       if(entry_labels['compute.googleapis.com/resource_name'] != '',
                                            entry_labels['compute.googleapis.com/resource_name'], res_labels['instance_id']),
        res_type = 'k8s_control_plane_component', concat('control-plane/', res_labels['component_name']),
        -- Anything else: "<resource type>/<log id>" (e.g. k8s_node/kubelet, k8s_pod/events) so mixed logs stay separable.
        log_id != '',                    concat(res_type, '/', log_id),
        res_type != '',                  res_type,
        'unknown') AS ServiceName,
    res_type AS ResourceType,
    if(res_labels['project_id'] != '', res_labels['project_id'], extract(log_name, '^projects/([^/]+)/')) AS ProjectId,
    log_name AS LogName,
    log_id AS LogId,
    body AS Body,
    multiIf(text_payload != '', 'text', json_payload != '', 'json', proto_payload != '', 'proto',
            tupleElement(http, 'requestMethod') != '', 'http', 'none') AS PayloadType,
    proto_payload AS ProtoPayload,
    replaceRegexpOne(tupleElement(e, 'trace'), '^projects/[^/]+/traces/', '') AS TraceId,
    tupleElement(e, 'spanId') AS SpanId,
    tupleElement(e, 'traceSampled') AS TraceSampled,
    tupleElement(http, 'requestMethod') AS HttpMethod,
    tupleElement(http, 'status') AS HttpStatus,
    tupleElement(http, 'requestUrl') AS HttpUrl,
    toFloat64OrZero(replaceOne(tupleElement(http, 'latency'), 's', '')) AS HttpLatencySeconds,
    tupleElement(http, 'userAgent') AS HttpUserAgent,
    tupleElement(http, 'remoteIp') AS HttpRemoteIp,
    tupleElement(src, 'file') AS SourceFile,
    toUInt32OrZero(tupleElement(src, 'line')) AS SourceLine,
    tupleElement(src, 'function') AS SourceFunction,
    tupleElement(tupleElement(e, 'operation'), 'id') AS OperationId,
    tupleElement(tupleElement(e, 'operation'), 'producer') AS OperationProducer,
    tupleElement(e, 'insertId') AS InsertId,
    _message_id AS MessageId,
    isValidJSON(_raw_message) AS ParseOk,
    7 AS ParserVersion,
    mapConcat(res_labels, map('resource.type', res_type)) AS ResourceAttributes,
    mapConcat(mapApply((k, v) -> (concat('labels.', k), v), entry_labels), json_map, audit_map, kv_map,
              entry_map, http_map, op_map, if(proto_type != '', map('proto.type', proto_type), map())) AS LogAttributes
FROM gcl.gcl_landing_v1
-- Noise rule (kept as per-minute counts by sql/50_noise_rollup_v1.sql instead of rows).
WHERE tupleElement(audit, 'methodName') != 'io.k8s.coordination.v1.leases.update';
