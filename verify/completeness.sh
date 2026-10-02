#!/bin/bash
# Compare the message IDs the load generator published with what landed in L0 and L1.
# Usage: completeness.sh <sent_ids_file> [l0_table] [l1_table]
# Needs: clickhousectl (API key), clickhouse (local), CH_SERVICE_ID.
set -euo pipefail
SENT=$1; L0=${2:-gcl.gcl_landing_v1}; L1=${3:-gcl.gcl_logs_v1}
W=$(mktemp -d)
sort -u "$SENT" > "$W/sent.txt"   # snapshot first, then let in-flight messages settle
sleep "${SETTLE_SEC:-45}"
q() { (cd ~ && clickhousectl cloud service query --id "$CH_SERVICE_ID" -q "$1"); }
q "SELECT _message_id, count() FROM $L0 GROUP BY 1 FORMAT TSV" > "$W/l0.tsv"
q "SELECT MessageId, count() FROM $L1 GROUP BY 1 FORMAT TSV" > "$W/l1.tsv"
clickhouse local -q "
WITH
  (SELECT count() FROM file('$W/sent.txt', 'LineAsString')) AS sent,
  (SELECT groupUniqArray(c1) FROM file('$W/l0.tsv', 'TSV')) AS _unused
SELECT
  sent AS sent_ids,
  (SELECT count() FROM file('$W/sent.txt','LineAsString') s WHERE s.line NOT IN (SELECT c1 FROM file('$W/l0.tsv','TSV'))) AS missing_in_l0,
  (SELECT count() FROM file('$W/sent.txt','LineAsString') s WHERE s.line NOT IN (SELECT c1 FROM file('$W/l1.tsv','TSV'))) AS missing_in_l1,
  (SELECT countIf(c2 > 1) FROM file('$W/l0.tsv','TSV') WHERE c1 IN (SELECT line FROM file('$W/sent.txt','LineAsString'))) AS dup_ids_l0,
  (SELECT countIf(c2 > 1) FROM file('$W/l1.tsv','TSV') WHERE c1 IN (SELECT line FROM file('$W/sent.txt','LineAsString'))) AS dup_ids_l1,
  (SELECT count() FROM file('$W/l1.tsv','TSV') WHERE c1 NOT IN (SELECT line FROM file('$W/sent.txt','LineAsString'))) AS l1_ids_not_in_sent
FORMAT Vertical" 2>&1 | grep -v "^$"
if [ -n "${KEEP_MISSING:-}" ]; then
  clickhouse local -q "SELECT line FROM file('$W/sent.txt','LineAsString') WHERE line NOT IN (SELECT c1 FROM file('$W/l1.tsv','TSV'))" > "$KEEP_MISSING"
fi
rm -rf "$W"
