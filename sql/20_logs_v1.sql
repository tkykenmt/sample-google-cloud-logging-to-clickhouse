-- L1: main log table, column names aligned with the ClickStack OTel logs schema.
CREATE TABLE IF NOT EXISTS gcl.gcl_logs_v1
(
    Timestamp          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    ReceiveTimestamp   DateTime64(9) CODEC(ZSTD(1)),
    PublishTime        DateTime64(3) CODEC(ZSTD(1)),
    InsertedAt         DateTime64(3) CODEC(ZSTD(1)),
    SeverityText       LowCardinality(String) CODEC(ZSTD(1)),
    SeverityNumber     UInt8 CODEC(ZSTD(1)),
    ServiceName        LowCardinality(String) CODEC(ZSTD(1)),
    ResourceType       LowCardinality(String) CODEC(ZSTD(1)),
    ProjectId          LowCardinality(String) CODEC(ZSTD(1)),
    LogName            LowCardinality(String) CODEC(ZSTD(1)),
    LogId              LowCardinality(String) CODEC(ZSTD(1)),
    Body               String CODEC(ZSTD(1)),
    PayloadType        LowCardinality(String) CODEC(ZSTD(1)),
    ProtoPayload       String CODEC(ZSTD(3)),
    TraceId            String CODEC(ZSTD(1)),
    SpanId             String CODEC(ZSTD(1)),
    TraceSampled       Bool CODEC(ZSTD(1)),
    HttpMethod         LowCardinality(String) CODEC(ZSTD(1)),
    HttpStatus         UInt16 CODEC(ZSTD(1)),
    HttpUrl            String CODEC(ZSTD(1)),
    HttpLatencySeconds Float64 CODEC(ZSTD(1)),
    HttpUserAgent      String CODEC(ZSTD(1)),
    HttpRemoteIp       String CODEC(ZSTD(1)),
    SourceFile         LowCardinality(String) CODEC(ZSTD(1)),
    SourceLine         UInt32 CODEC(ZSTD(1)),
    SourceFunction     LowCardinality(String) CODEC(ZSTD(1)),
    OperationId        String CODEC(ZSTD(1)),
    OperationProducer  LowCardinality(String) CODEC(ZSTD(1)),
    InsertId           String CODEC(ZSTD(1)),
    MessageId          String CODEC(ZSTD(1)),
    ParseOk            Bool,
    ParserVersion      UInt32,
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    LogAttributes      Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    -- key=value items, as in the ClickStack default schema: when these columns exist, ClickStack turns an
    -- attribute filter into has(LogAttributeItems, 'key=value'), which the items index below can serve.
    ResourceAttributeItems Array(String) ALIAS arrayMap((arr) -> concat(arr.1, '=', arr.2), ResourceAttributes::Array(Tuple(String, String))),
    LogAttributeItems      Array(String) ALIAS arrayMap((arr) -> concat(arr.1, '=', arr.2), LogAttributes::Array(Tuple(String, String))),
    INDEX idx_trace_id TraceId TYPE text(tokenizer = 'array'),
    -- ngrams(2) so Japanese words are searchable: ClickStack searches with hasAllTokens(lower(Body), ...),
    -- and splitByNonAlpha keeps a Japanese sentence as one token (searches silently return 0 rows).
    -- Cost: about 4.5x the index size of splitByNonAlpha; one-character terms cannot be searched.
    -- Only one text index is allowed per expression. Use splitByNonAlpha if there is no Japanese text.
    INDEX idx_lower_body lower(Body) TYPE text(tokenizer = ngrams(2)),
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE text(tokenizer = 'array'),
    INDEX idx_res_attr_items ResourceAttributeItems TYPE text(tokenizer = 'array'),
    INDEX idx_log_attr_key mapKeys(LogAttributes) TYPE text(tokenizer = 'array'),
    INDEX idx_log_attr_items LogAttributeItems TYPE text(tokenizer = 'array')
)
ENGINE = MergeTree
PARTITION BY toDate(Timestamp)
ORDER BY (toStartOfFiveMinutes(Timestamp), ServiceName, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL {{LOGS_TTL_DAYS}} DAY
-- Bucketed Map serialization for merged parts only (inserts keep 'basic'). With the default
-- map_buckets_min_avg_size = 32 nothing changes while maps stay small (about 10 keys per row on real
-- GCL logs); parts whose maps average 32+ keys are split into buckets automatically at merge time.
SETTINGS ttl_only_drop_parts = 1,
         map_serialization_version = 'with_buckets',
         map_serialization_version_for_zero_level_parts = 'basic';
