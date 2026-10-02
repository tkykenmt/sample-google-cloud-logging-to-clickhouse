-- Runbook 02: rebuild one settled day of L1 from L0 after a parser fix, then rebuild its rollup.
-- REPLACE PARTITION does NOT fire MVs on gcl_logs_v1: the rollup must be rebuilt explicitly.
-- Use only for days where late arrivals have settled (check verify/checks.sql: late-arrival distribution).
-- Variables: {{DAY}} = 2026-10-07, {{PART}} = 20261007, {{FROM}}/{{TO}} = publish-time window around the day.

CREATE TABLE gcl.gcl_logs_v1_rebuild AS gcl.gcl_logs_v1;

-- INSERT ... SELECT maps columns by POSITION, while an MV maps them by NAME.
-- Wrap the MV body in a subquery and select the target columns in table order
-- (SELECT arrayStringConcat(groupArray(name), ', ') FROM system.columns
--  WHERE database = 'gcl' AND table = 'gcl_logs_v1' ORDER BY position).
INSERT INTO gcl.gcl_logs_v1_rebuild
SELECT /* target columns in table order */ *
FROM
(
    -- body of the fixed MV (WITH ... SELECT ...), reading L0 through a deduplicating subquery:
    -- FROM (SELECT * FROM gcl.gcl_landing_v1
    --       WHERE _publish_time >= toDateTime64('{{FROM}}', 3, 'UTC') AND _publish_time < toDateTime64('{{TO}}', 3, 'UTC')
    --       LIMIT 1 BY _message_id)
    -- L0 keeps Pub/Sub redeliveries as separate rows; without LIMIT 1 BY they come back into L1
    -- (observed: 493 duplicates in an 8-minute window right after a pipe seek).
)
WHERE toDate(Timestamp) = '{{DAY}}';

-- Compare before replacing (uniqExact, because the old partition may hold duplicates too).
SELECT count(), uniqExact(MessageId) FROM gcl.gcl_logs_v1 WHERE toDate(Timestamp) = '{{DAY}}';
SELECT count(), uniqExact(MessageId) FROM gcl.gcl_logs_v1_rebuild;

ALTER TABLE gcl.gcl_logs_v1 REPLACE PARTITION ID '{{PART}}' FROM gcl.gcl_logs_v1_rebuild;

-- Rebuild the matching rollup partition from the rebuilt rows.
CREATE TABLE gcl.gcl_logs_1m_v1_rebuild AS gcl.gcl_logs_1m_v1;
INSERT INTO gcl.gcl_logs_1m_v1_rebuild
SELECT toStartOfMinute(Timestamp) AS Minute, ServiceName, SeverityText, HttpStatus, count() AS Cnt
FROM gcl.gcl_logs_v1_rebuild
GROUP BY Minute, ServiceName, SeverityText, HttpStatus;
ALTER TABLE gcl.gcl_logs_1m_v1 REPLACE PARTITION ID '{{PART}}' FROM gcl.gcl_logs_1m_v1_rebuild;

DROP TABLE gcl.gcl_logs_1m_v1_rebuild;
DROP TABLE gcl.gcl_logs_v1_rebuild;
