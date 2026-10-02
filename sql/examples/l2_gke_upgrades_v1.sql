-- Optional L2 example. Build an L2 only when L1 cannot meet a requirement (docs/en/design.md, "When to build an L2").
-- Promote one log type into a typed table for clean dashboards: GKE upgrade notifications
-- (log id container.googleapis.com/notifications). The generic L1 keeps them too; this table
-- only adds typed columns. Register it as its own ClickStack log source.
CREATE TABLE IF NOT EXISTS gcl.gke_upgrade_events_v1
(
    Timestamp      DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    PublishTime    DateTime64(3),
    MessageId      String,
    ServiceName    LowCardinality(String),
    SeverityText   LowCardinality(String),
    Body           String,
    EventKind      LowCardinality(String),
    EventType      LowCardinality(String),
    State          LowCardinality(String),
    ResourceKind   LowCardinality(String),
    Cluster        LowCardinality(String),
    NodePool       LowCardinality(String),
    CurrentVersion LowCardinality(String),
    TargetVersion  LowCardinality(String),
    StartTime      DateTime64(3),
    EndTime        DateTime64(3),
    DurationSec    Float64,
    Operation      String,
    LogAttributes  Map(LowCardinality(String), String)
)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (Cluster, NodePool, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL {{LOGS_TTL_DAYS}} DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS gcl.gke_upgrade_events_v1_mv TO gcl.gke_upgrade_events_v1
DEFINER = {{MV_DEFINER}} SQL SECURITY DEFINER
AS
WITH
    JSONExtract(_raw_message, 'Tuple(timestamp String, severity String, logName String,
        resource Tuple(type String, labels Map(String, String)),
        jsonPayload Tuple(`@type` String, eventType String, state String, resourceType String, resource String,
                          currentVersion String, targetVersion String, operation String,
                          startTime String, endTime String, operationStartTime String))') AS e,
    tupleElement(e, 'jsonPayload') AS p,
    tupleElement(tupleElement(e, 'resource'), 'labels') AS rl,
    parseDateTime64BestEffortOrZero(tupleElement(e, 'timestamp'), 9, 'UTC') AS ts,
    parseDateTime64BestEffortOrZero(if(tupleElement(p, 'startTime') != '', tupleElement(p, 'startTime'),
                                       tupleElement(p, 'operationStartTime')), 3, 'UTC') AS st,
    parseDateTime64BestEffortOrZero(tupleElement(p, 'endTime'), 3, 'UTC') AS et,
    extract(tupleElement(p, 'resource'), '/clusters/([^/]+)') AS cluster,
    extract(tupleElement(p, 'resource'), '/nodePools/([^/]+)') AS nodepool,
    replaceRegexpOne(tupleElement(p, '@type'), '^.*\\.', '') AS kind,
    tupleElement(p, 'state') AS state
SELECT
    if(ts > toDateTime64('2000-01-01 00:00:00', 9, 'UTC'), ts, toDateTime64(_publish_time, 9, 'UTC')) AS Timestamp,
    _publish_time AS PublishTime,
    _message_id AS MessageId,
    'gke-upgrades' AS ServiceName,
    multiIf(state = 'FAILED', 'ERROR', tupleElement(e, 'severity') = '', 'DEFAULT', tupleElement(e, 'severity')) AS SeverityText,
    concat(kind, ' ', if(nodepool != '', nodepool, cluster), if(state != '', concat(' ', state), ''),
           if(tupleElement(p, 'targetVersion') != '', concat(' ', tupleElement(p, 'currentVersion'), ' -> ', tupleElement(p, 'targetVersion')), '')) AS Body,
    kind AS EventKind,
    tupleElement(p, 'eventType') AS EventType,
    state AS State,
    tupleElement(p, 'resourceType') AS ResourceKind,
    if(cluster != '', cluster, rl['cluster_name']) AS Cluster,
    if(nodepool != '', nodepool, rl['nodepool_name']) AS NodePool,
    tupleElement(p, 'currentVersion') AS CurrentVersion,
    tupleElement(p, 'targetVersion') AS TargetVersion,
    st AS StartTime,
    et AS EndTime,
    if(et > st AND toYear(st) > 2000, dateDiff('millisecond', st, et) / 1000, 0) AS DurationSec,
    tupleElement(p, 'operation') AS Operation,
    map('location', rl['location'], 'project_id', rl['project_id']) AS LogAttributes
FROM gcl.gcl_landing_v1
WHERE position(_raw_message, 'container.googleapis.com%2Fnotifications') > 0;
