-- L0: landing table. The ClickPipe writes only the raw message and Pub/Sub virtual columns.
-- Parsing happens in materialized views, so parser changes never require recreating the pipe.
CREATE DATABASE IF NOT EXISTS gcl;

CREATE TABLE IF NOT EXISTS gcl.gcl_landing_v1
(
    _message_id   String,
    _publish_time DateTime64(3),
    _attributes   Map(String, String),
    _raw_message  String CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toDate(_publish_time)
ORDER BY _publish_time
-- Replay buffer. Size the retention from: max ingest delay + switch/backfill time + verification/rollback time.
TTL toDateTime(_publish_time) + INTERVAL {{LANDING_TTL_DAYS}} DAY
SETTINGS ttl_only_drop_parts = 1;
