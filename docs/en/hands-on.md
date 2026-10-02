# Hands-on

English | [日本語](../ja/hands-on.md)

Two parts:

- **Part 1 (local, about 10 minutes)**: run the SQL from L0 through L1, L2, and L3 on `clickhouse local` alone, and check Japanese search and the noise rule. No cloud resources are created.
- **Part 2 (real services, about 60 minutes)**: deploy to a sandbox Google Cloud project and ClickHouse Cloud service with Terraform, publish synthetic logs, and search them in ClickStack. Clean up at the end.

Background is in [Design](design.md); production deployment is in [Setup](setup.md).

## Part 1: run the SQL locally

### 1-1. Prerequisites

- The single-binary ClickHouse (`clickhouse`, installed with `curl https://clickhouse.com/ | sh`)
- `python3` (standard library only)

### 1-2. Run everything and check

```bash
WORKDIR=/tmp/gcl-handson verify/local_e2e.sh 20000
```

The script:

1. Generates two batches of 20,000 LogEntry messages shaped like a Cloud Logging sink's output with `loadgen/gen_logentry.py`. The first batch mixes in 20% Kubernetes Lease updates (the noise example).
2. Creates L0, L1, MV1, L3 (per-minute counts), and the noise counts from `sql/10` to `sql/50`.
3. Loads the first batch into L0 the way the ClickPipe writes it (raw message plus Pub/Sub virtual columns).
4. Picks a boundary time T, creates the MV of the L2 example (`sql/examples/l2_audit_events_v1.sql`), and loads the second batch. The first batch, published before T, is backfilled from L0 with `sql/examples/l2_audit_events_v1_backfill.sql`.
5. Reconciles the counts.

The output looks like this (counts vary with the random data):

```text
   ┌─check───────────────────────────┬─expected─┬─actual─┬─result─┐
1. │ L0 rows = generated             │ 40000    │  40000 │ PASS   │
2. │ L1 rows = L0 rows - noise       │ 35985    │  35985 │ PASS   │
3. │ Noise counts = noise rows in L0 │ 4015     │   4015 │ PASS   │
4. │ L3 rollup total = L1 rows       │ 35985    │  35985 │ PASS   │
5. │ L2 audit rows = L1 audit rows   │ 3559     │   3559 │ PASS   │
6. │ L2 has no duplicates            │ 3559     │   3559 │ PASS   │
7. │ ServiceName/Body never empty    │ 0        │      0 │ PASS   │
8. │ No 1970 timestamps              │ 0        │      0 │ PASS   │
9. │ Japanese search (index) = LIKE  │ 3079     │   3079 │ PASS   │
   └─────────────────────────────────┴──────────┴────────┴────────┘
```

- 2 and 3: Lease updates stay out of L1 and only their counts remain in the noise table.
- 4: the L3 total equals the L1 row count.
- 5 and 6: rows from the MV plus the backfill equal the audit logs in L1, with no duplicates.
- 9: the 2-character n-gram index finds 「タイムアウト」 ("timeout") in as many rows as LIKE does.

### 1-3. Look inside

With `WORKDIR` set, the database is kept.

```bash
q() { TZ=UTC clickhouse local --path /tmp/gcl-handson/db -q "$1"; }
```

**ServiceName in L1**: filled by a fixed rule per log kind.

```bash
q "SELECT ResourceType, ServiceName, count() FROM gcl.gcl_logs_v1 GROUP BY ALL ORDER BY 3 DESC LIMIT 10"
```

**Japanese search**: the same condition ClickStack builds from the search box.

```bash
q "SELECT Body FROM gcl.gcl_logs_v1 WHERE hasAllTokens(lower(Body), lower('タイムアウト')) LIMIT 3"
q "EXPLAIN indexes = 1 SELECT count() FROM gcl.gcl_logs_v1 WHERE hasAllTokens(lower(Body), 'タイムアウト')"
```

Under Skip, EXPLAIN shows `idx_lower_body` and the word split into 2-character tokens (`タイ`, `イム`, ...).

**Extracting values from L1**: tables come from attributes and columns without a typed table.

```bash
q "SELECT ServiceName, round(quantile(0.95)(HttpLatencySeconds), 3) AS p95_s, countIf(HttpStatus >= 500) AS errors
   FROM gcl.gcl_logs_v1 WHERE HttpMethod != '' GROUP BY ALL ORDER BY p95_s DESC"
q "SELECT LogAttributes['audit.principalEmail'] AS who, LogAttributes['audit.methodName'] AS what, count()
   FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName') GROUP BY ALL ORDER BY 3 DESC"
```

**Compared with the L2**: the L2 answers the same question with rows sorted by operator, so it reads less.

```bash
q "SELECT Principal, MethodName, count() FROM gcl.audit_events_v1 GROUP BY ALL ORDER BY 3 DESC"
```

**Noise counts**: logs kept out of L1 remain as per-minute counts per rule.

```bash
q "SELECT Rule, Principal, sum(Cnt) FROM gcl.gcl_noise_1m_v1 GROUP BY ALL ORDER BY 3 DESC"
```

Remove it afterwards with `rm -rf /tmp/gcl-handson`.

## Part 2: run on real services

Use a sandbox project and service.
In a production project, every log of the project would be sent to the topic and incur Pub/Sub charges.

### 2-1. Prerequisites

- A sandbox Google Cloud project and a ClickHouse Cloud service (26.6 or later)
- "Prerequisites" and "1. Authenticate" in [Setup](setup.md)

### 2-2. Deploy

```bash
cd terraform
cat > terraform.tfvars <<'EOF'
gcp_project_id        = "<sandbox project>"
clickhouse_service_id = "<service id>"
EOF
terraform init
terraform apply
terraform output clickpipe_state   # Running
```

Without Terraform, put the same two values in `cli/.env` and run `cli/deploy.sh`. Clean up with `DROP_DATABASE=1 cli/destroy.sh`.

### 2-3. Publish synthetic logs

In addition to the real logs the sink exports, publish synthetic logs straight to the topic.
`--ids-out` records the IDs of the published messages.

```bash
cd ..
python3 loadgen/gen_logentry.py --publish projects/<sandbox project>/topics/gcl-to-clickhouse \
  --rate 50 --duration 300 --lease-rate 0.2 --dup-rate 0.01 --ids-out sent_ids.txt
```

### 2-4. Check for loss and duplicates

```bash
export CH_SERVICE_ID=<service id>
verify/completeness.sh sent_ids.txt
```

`missing_in_l0` of 0 means every published message reached L0.
`missing_in_l1` equals the number of Lease updates, which L1 does not keep.
To check L1 completeness on its own, publish without `--lease-rate` and confirm `missing_in_l1` is 0.
Entries resent with `--dup-rate` get a new `MessageId` from Pub/Sub, so they do not count in `dup_ids_*`.

### 2-5. Search in ClickStack

Create the source and dashboard as in "4. ClickStack source" of [Setup](setup.md), then open ClickStack.

1. Select the "Cloud Logging" source and type `タイムアウト` in the search box. Logs whose body contains the word appear.
2. Filter ServiceName to `web-frontend` on the left.
3. Switch to Event Patterns to see counts per body shape. Lease updates are not in L1, so they do not appear at the top.
4. Open the "Cloud Logging overview" dashboard.

### 2-6. Add an L2

Add a table for filtering audit logs by operator, as an L2.
Set the boundary time T a few minutes ahead.

```bash
T=$(date -u -v+3M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d '+3 min' +"%Y-%m-%d %H:%M:%S")
python3 tools/chq.py --var LOGS_TTL_DAYS=400 --var MV_DEFINER=default --var T="$T" sql/examples/l2_audit_events_v1.sql
```

The MV puts audit logs published from T on into the L2.
After T has passed, backfill the rows before T from L0.
The end of the backfill file prints the same aggregate from the L2 and from L1.

```bash
python3 tools/chq.py --var T="$T" sql/examples/l2_audit_events_v1_backfill.sql
python3 tools/chq.py -q "SELECT
  (SELECT count() FROM gcl.audit_events_v1) AS l2,
  (SELECT count() FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName')) AS l1_audit"
```

Details and how to rework an L2 are under "Creating and reworking an L2" in [Operations](operations.md).

### 2-7. Add an L3

Add per-minute counts per log id as an L3.
As with the L2, create the MV, wait until T has passed, then fill the past.

```bash
T=$(date -u -v+3M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d '+3 min' +"%Y-%m-%d %H:%M:%S")
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var L3_TTL_DAYS=400 --var T="$T" sql/runbooks/09_add_l3.sql
# after T has passed
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var T="$T" --var CHECK_TO="$(date -u +'%Y-%m-%d %H:%M:00')" \
  sql/runbooks/09_add_l3_backfill.sql
```

The last two numbers (the L3 total and the L1 row count) match.
The procedure is under "Adding an L3" in [Operations](operations.md).

### 2-8. Clean up

```bash
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
cd terraform && terraform destroy
rm -f ../sent_ids.txt
```

Deleting the ClickPipe also deletes its managed subscription.
Deleting the sink stops exports to the topic.
