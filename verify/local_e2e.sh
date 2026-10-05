#!/bin/bash
# End-to-end check of the SQL in this repository on a local ClickHouse (no cloud resources).
# Generates synthetic LogEntry messages, loads them into L0 the way the ClickPipe does
# (raw message + Pub/Sub virtual columns), and checks L1, the rollup (L3), the noise counts and
# the optional L2 example (sql/examples/l2_audit_events_v1.sql) including its backfill from L0,
# and that the stuck-row check of verify/checks.sql ignores rows dropped by the noise rule.
# Usage: verify/local_e2e.sh [entries]    Needs: clickhouse (local), python3.
# WORKDIR=<dir> keeps the database there for exploring: clickhouse local --path <dir>/db
set -euo pipefail
cd "$(dirname "$0")/.."
N=${1:-20000}
if [ -n "${WORKDIR:-}" ]; then
  W=$WORKDIR; rm -rf "$W/db"; mkdir -p "$W"
else
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fi
export TZ=UTC

ch() { clickhouse local --path "$W/db" --multiquery "$@"; }
render() { sed -e "s/{{LANDING_TTL_DAYS}}/7/g; s/{{LOGS_TTL_DAYS}}/400/g; s/{{MV_DEFINER}}/default/g; s/{{T}}/$2/g" "$1"; }
load() {  # load <file>: L0 rows as the pipe writes them, published "now"
  ch -q "INSERT INTO gcl.gcl_landing_v1 (_message_id, _publish_time, _attributes, _raw_message)
         SELECT toString(generateUUIDv4()), now64(3), map(), line FROM file('$1', 'LineAsString')"
}

python3 loadgen/gen_logentry.py --out "$W/a.jsonl" --count "$N" --seed 1 --lease-rate 0.2 --late-rate 0.02 --future-rate 0.01 --missing-ts-rate 0.01 >/dev/null
python3 loadgen/gen_logentry.py --out "$W/b.jsonl" --count "$N" --seed 2 >/dev/null

for f in sql/10_landing_v1.sql sql/20_logs_v1.sql sql/30_logs_v1_mv.sql sql/40_rollup_1m_v1.sql sql/50_noise_rollup_v1.sql; do
  render "$f" "" | ch
done
load "$W/a.jsonl"

# Optional L2 added later, with a boundary T: batch b arrives after T, batch a is backfilled from L0.
sleep 1
T=$(date -u +"%Y-%m-%d %H:%M:%S")
sleep 1
render sql/examples/l2_audit_events_v1.sql "$T" | ch
load "$W/b.jsonl"
render sql/examples/l2_audit_events_v1_backfill.sql "$T" | awk '/^-- Same answer as L1/{exit} {print}' | ch

ch -q "
WITH
  (SELECT count() FROM gcl.gcl_landing_v1) AS l0,
  (SELECT count() FROM gcl.gcl_logs_v1) AS l1,
  (SELECT count() FROM gcl.gcl_landing_v1 WHERE position(_raw_message, 'io.k8s.coordination.v1.leases.update') > 0) AS lease_l0,
  (SELECT sum(Cnt) FROM gcl.gcl_noise_1m_v1 WHERE Rule = 'k8s-lease-update') AS lease_counted,
  (SELECT sum(Cnt) FROM gcl.gcl_logs_1m_v1) AS l3,
  (SELECT count() FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName')) AS audit_l1,
  (SELECT count() FROM gcl.audit_events_v1) AS audit_l2,
  (SELECT uniqExact(MessageId) FROM gcl.audit_events_v1) AS audit_l2_ids,
  (SELECT countIf(ServiceName = '' OR Body = '') FROM gcl.gcl_logs_v1) AS empty_svc_body,
  (SELECT countIf(toYear(Timestamp) < 2000) FROM gcl.gcl_logs_v1) AS ts_1970,
  (SELECT count() FROM gcl.gcl_logs_v1 WHERE hasAllTokens(lower(Body), lower('タイムアウト'))) AS ja_index,
  (SELECT count() FROM gcl.gcl_logs_v1 WHERE Body LIKE '%タイムアウト%') AS ja_like,
  -- verify/checks.sql 2 (stuck rows) must not count rows dropped by the noise rule
  (SELECT count() FROM gcl.gcl_landing_v1
   WHERE _message_id NOT IN (SELECT MessageId FROM gcl.gcl_logs_v1)
     AND JSONExtractString(_raw_message, 'protoPayload', 'methodName') != 'io.k8s.coordination.v1.leases.update') AS stuck,
  (SELECT countIf(match(ServiceName, '^[0-9]+$')) FROM gcl.gcl_logs_v1 WHERE ResourceType = 'gce_instance') AS gce_numeric
SELECT check, expected, actual, if(expected = actual, 'PASS', 'FAIL') AS result FROM (
  SELECT 1 AS n, 'L0 rows = generated'    AS check, toUInt64($N * 2) AS expected, l0 AS actual UNION ALL
  SELECT 2, 'L1 rows = L0 rows - noise',          l0 - lease_l0,       l1 UNION ALL
  SELECT 3, 'Noise counts = noise rows in L0',    lease_l0,            lease_counted UNION ALL
  SELECT 4, 'L3 rollup total = L1 rows',          l1,                  l3 UNION ALL
  SELECT 5, 'L2 audit rows = L1 audit rows',      audit_l1,            audit_l2 UNION ALL
  SELECT 6, 'L2 has no duplicates',               audit_l2,            audit_l2_ids UNION ALL
  SELECT 7, 'ServiceName/Body never empty',       toUInt64(0),                   empty_svc_body UNION ALL
  SELECT 8, 'No 1970 timestamps',                 toUInt64(0),                   ts_1970 UNION ALL
  SELECT 9, 'Japanese search (index) = LIKE',     ja_like,             ja_index UNION ALL
  SELECT 10, 'Stuck-row check ignores noise',     toUInt64(0),                   stuck UNION ALL
  SELECT 11, 'GCE ServiceName is the VM name',    toUInt64(0),                   gce_numeric
)
ORDER BY n
FORMAT PrettyCompactMonoBlock"
