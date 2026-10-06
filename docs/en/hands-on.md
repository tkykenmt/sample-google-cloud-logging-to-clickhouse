# Hands-on

English | [日本語](../ja/hands-on.md)

Each part ends by removing what it created.

- **Part 1 (local, about 10 minutes)**: run the SQL from L0 through L1, L2, and L3 on `clickhouse local` alone, and check Japanese search and the noise rule. No cloud resources are created.
- **Part 2 (real services, about 60 minutes)**: deploy to a sandbox Google Cloud project and ClickHouse Cloud service with Terraform, publish synthetic logs, and search them in ClickStack.
- **Part 3 (real services, about 30 minutes)**: build what Terraform created in part 2 one piece at a time with `gcloud` and `clickhousectl`, and see what each does. This is not a deployment procedure; deploy with Terraform as in [Setup](setup.md).

Background is in [Design](design.md); production deployment is in [Setup](setup.md).

## Part 1: run the SQL locally

### 1-1. Prerequisites

- The single-binary ClickHouse (`clickhouse`, installed with `curl https://clickhouse.com/ | sh`)
- `python3` (standard library only)
- Run from the top directory of the repository.

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
10. │ Stuck-row check ignores noise   │ 0        │      0 │ PASS   │
11. │ GCE ServiceName is the VM name  │ 0        │      0 │ PASS   │
   └─────────────────────────────────┴──────────┴────────┴────────┘
```

- 2 and 3: Lease updates stay out of L1 and only their counts remain in the noise table.
- 4: the L3 total equals the L1 row count.
- 5 and 6: rows from the MV plus the backfill equal the audit logs in L1, with no duplicates.
- 9: the 2-character n-gram index finds 「タイムアウト」 ("timeout") in as many rows as LIKE does, because the synthetic logs contain no body with the same 2-character pieces in another order ([Design](design.md), "Japanese search").
- 10: check 2 of `verify/checks.sql` (rows that never reached L1) does not count rows dropped as noise.
- 11: the ServiceName of Compute Engine logs is the VM name.

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
- `clickhouse` from part 1 (used by `verify/completeness.sh`)
- Publish permission on the topic (`roles/pubsub.publisher`; project owners and editors have it) for the account that publishes the synthetic logs. `loadgen/gen_logentry.py` uses the token from `gcloud auth application-default print-access-token` (the ADC from "1. Authenticate")

### 2-2. Deploy

```bash
cd terraform
cat > terraform.tfvars <<'EOF'
gcp_project_id        = "<sandbox project>"
clickhouse_service_id = "<service id>"
topic_storage_regions = ["<service region, e.g. asia-northeast1>"]
EOF
terraform init
terraform apply
terraform output clickpipe_state   # Running
```

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
`dup_ids_*` counts Pub/Sub redeliveries (the same `MessageId` delivered twice).
Redeliveries happen (0 to 3% in testing); a non-zero value is not data loss.

### 2-5. Search in ClickStack

Create the source and dashboard as in "4. Create the ClickStack source (optional)" of [Setup](setup.md), then open ClickStack.

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
while [[ "$(date -u +"%Y-%m-%d %H:%M:%S")" < "$T" ]]; do sleep 10; done   # wait until T has passed
python3 tools/chq.py --var T="$T" sql/examples/l2_audit_events_v1_backfill.sql
python3 tools/chq.py -q "SELECT
  (SELECT uniqExact(MessageId) FROM gcl.audit_events_v1) AS l2,
  (SELECT uniqExact(MessageId) FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName')) AS l1_audit"
```

Pub/Sub redeliveries can put rows with the same `MessageId` into L1, so compare distinct `MessageId`s, not row counts.

Details and how to rework an L2 are under "Creating and reworking an L2" in [Operations](operations.md).

### 2-7. Add an L3

Add per-minute counts per log id as an L3.
As with the L2, create the MV, wait until T has passed, then fill the past.

```bash
T=$(date -u -v+3M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d '+3 min' +"%Y-%m-%d %H:%M:%S")
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var L3_TTL_DAYS=400 --var MV_DEFINER=default --var T="$T" sql/runbooks/09_add_l3.sql
while [[ "$(date -u +"%Y-%m-%d %H:%M:%S")" < "$T" ]]; do sleep 10; done   # wait until T has passed
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var T="$T" --var CHECK_TO="$(date -u +'%Y-%m-%d %H:%M:00')" \
  sql/runbooks/09_add_l3_backfill.sql
```

The last two numbers (the L3 total and the L1 row count) match.
The procedure is under "Adding an L3" in [Operations](operations.md).

### 2-8. Clean up

```bash
cd terraform && terraform destroy && cd ..
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
rm -f sent_ids.txt
```

Delete the pipe before the database.
`terraform destroy` waits until ClickPipes has deleted the managed subscription before it removes the key and the role binding.
Deleting the sink stops exports to the topic.
Clean up here before part 3 as well (part 3 uses the same database `gcl`).


## Part 3: build it one piece at a time with gcloud and clickhousectl

Build what Terraform created in part 2 with commands, one resource at a time.
Each step says what it creates and why.
Deploy with Terraform as in [Setup](setup.md), not with these commands.
Terraform tracks what it created in its state, so removal deletes only that.

Resource names carry `handson` so they do not collide with part 2 or with existing resources.
Clean up part 2 with 2-8 before you start.

### 3-1. Prerequisites

Same as 2-1 in part 2.
In addition, sign in to gcloud with `gcloud auth login` (separate from the ADC that Terraform uses).

```bash
P=<sandbox project>
export CH_SERVICE_ID=<service id>
TOPIC=gcl-handson
SINK=gcl-handson
SA=clickpipes-handson
SA_EMAIL=$SA@$P.iam.gserviceaccount.com
ROLE=clickpipesHandson
KEY=handson-key.json
REGION=asia-northeast1   # region of the ClickHouse Cloud service
```

### 3-2. Topic

```bash
gcloud pubsub topics create $TOPIC --project $P --message-storage-policy-allowed-regions=$REGION
```

The sink's destination.
No message retention, and message storage restricted to the region of the ClickHouse Cloud service: the replay data stays in L0 in ClickHouse ([Design](design.md), "Pub/Sub and ClickPipes").

### 3-3. Sink and publish permission

```bash
gcloud logging sinks create $SINK pubsub.googleapis.com/projects/$P/topics/$TOPIC \
  --project $P --log-filter="logName:\"projects/$P/logs/\""
W=$(gcloud logging sinks describe $SINK --project $P --format='value(writerIdentity)')
echo $W
gcloud pubsub topics add-iam-policy-binding $TOPIC --project $P --member="$W" --role=roles/pubsub.publisher
```

From the moment it is created, the sink sends every log of the project to the topic.
A sink publishes as its writer identity (`writerIdentity`), so that identity gets publish permission on the topic.
The writer identity is a service account Cloud Logging creates once per project and shares among its sinks (`service-<project-number>@gcp-sa-logging.iam.gserviceaccount.com`).
Until it has it, the sink fails to publish and those logs never reach the topic.

### 3-4. Role, service account and key for ClickPipes

```bash
gcloud iam roles create $ROLE --project $P --title="ClickPipes Pub/Sub ingestion (hands-on)" \
  --permissions=pubsub.topics.list,pubsub.topics.get,pubsub.topics.attachSubscription,pubsub.subscriptions.create,pubsub.subscriptions.get,pubsub.subscriptions.delete,pubsub.subscriptions.consume
gcloud iam service-accounts create $SA --project $P
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA_EMAIL" \
  --role="projects/$P/roles/$ROLE" --condition=None
until gcloud iam service-accounts keys create $KEY --iam-account=$SA_EMAIL; do sleep 10; done   # right after creation the account can be NOT_FOUND: retry until it propagates
```

A new service account can be invisible to key creation for a few seconds (it returned `NOT_FOUND` in testing).
The last line retries every 10 seconds until it succeeds.

These are the permissions of the official least-privilege role ([Pub/Sub IAM permissions](https://clickhouse.com/docs/integrations/clickpipes/pubsub/auth)).
ClickPipes creates and deletes its managed subscription (`clickpipes-<pipe id>`) itself, so it needs subscription create and delete.
The key file is the credential for reading the topic.
Treat it like a password and keep it out of Git (`.gitignore` excludes `*.json`).

### 3-5. Tables and MVs

```bash
python3 tools/chq.py --var LANDING_TTL_DAYS=7 --var LOGS_TTL_DAYS=400 --var MV_DEFINER=default \
  sql/10_landing_v1.sql sql/20_logs_v1.sql sql/30_logs_v1_mv.sql sql/40_rollup_1m_v1.sql sql/50_noise_rollup_v1.sql
```

Create them before the pipe.
The pipe writes into the existing L0, and the MVs build L1 and the rest.
`tools/chq.py` uses the Query API, so statements longer than 30 seconds lose their response (the server keeps running them).
Run large backfills over a native `clickhouse client` connection.

### 3-6. ClickPipe

```bash
clickhousectl cloud clickpipe create pubsub "$CH_SERVICE_ID" \
  --name gcl-handson --topic $TOPIC --project-id $P --format JSONEachRow \
  --service-account-file $KEY --seek-type latest \
  --database gcl --table gcl_landing_v1 \
  --column "_raw_message:String" --column "_message_id:String" \
  --column "_publish_time:DateTime64(3)" --column "_attributes:Map(String, String)"
clickhousectl cloud clickpipe list "$CH_SERVICE_ID"
PIPE_ID=<ID of gcl-handson from the list>
clickhousectl cloud clickpipe get "$CH_SERVICE_ID" $PIPE_ID   # wait until the state is Running
```

The pipe writes only the Pub/Sub virtual columns (raw message, message ID, publish time, attributes) into L0.
Creating the pipe creates its managed subscription, with 7-day retention, a 60 s ack deadline and ordering enabled.
If creation fails for missing permissions, wait a minute or two for IAM to propagate and create it again.

### 3-7. ClickStack source

Under Team Settings > Sources in ClickStack, create a log source.
The fields and values on the page are in "8. Create the ClickStack source" of [Setup in the browser](setup-console.md).
The JSON below is the same configuration in API field names (the same values as `terraform/clickstack.tf`).
The dashboard is created by Terraform only (`terraform/clickstack/dashboard.json.tftpl`).

```json
{
  "kind": "log",
  "name": "Cloud Logging (hands-on)",
  "databaseName": "gcl",
  "tableName": "gcl_logs_v1",
  "timestampValueExpression": "Timestamp",
  "displayedTimestampValueExpression": "Timestamp",
  "defaultTableSelectExpression": "Timestamp, ServiceName, SeverityText, ResourceType, Body",
  "serviceNameExpression": "ServiceName",
  "severityTextExpression": "SeverityText",
  "bodyExpression": "Body",
  "eventAttributesExpression": "LogAttributes",
  "resourceAttributesExpression": "ResourceAttributes",
  "traceIdExpression": "TraceId",
  "spanIdExpression": "SpanId",
  "implicitColumnExpression": "Body",
  "useTextIndexForImplicitColumn": "auto",
  "highlightedRowAttributeExpressions": [
    { "sqlExpression": "ResourceType", "alias": "type" },
    { "sqlExpression": "LogId", "alias": "log" },
    { "sqlExpression": "ProjectId", "alias": "project" }
  ]
}
```

With `useTextIndexForImplicitColumn` set to `auto`, words in the search box become conditions that use the text index on `lower(Body)`.
Japanese search needs that index.

### 3-8. Check

Run 2-3 and 2-4 of part 2 with the topic name `$TOPIC`.

```bash
python3 loadgen/gen_logentry.py --publish projects/$P/topics/$TOPIC --rate 50 --duration 120 --ids-out sent_ids.txt
verify/completeness.sh sent_ids.txt
```

`missing_in_l0` and `missing_in_l1` are 0.

### 3-9. Remove what you created

Remove only the resources with part 3's names, in reverse order of creation.

```bash
clickhousectl cloud clickpipe delete "$CH_SERVICE_ID" $PIPE_ID
python3 tools/wait_subscriptions_gone.py --project $P --topic $TOPIC   # wait for the managed subscription to go
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
gcloud logging sinks delete $SINK --project $P
gcloud pubsub topics delete $TOPIC --project $P
gcloud projects remove-iam-policy-binding $P --member="serviceAccount:$SA_EMAIL" \
  --role="projects/$P/roles/$ROLE" --condition=None
gcloud iam service-accounts delete $SA_EMAIL --project $P
gcloud iam roles delete $ROLE --project $P
rm -f $KEY sent_ids.txt
```

Deleting the pipe returns at once; ClickPipes then deletes the managed subscription with the service account.
Removing the role or the service account before that leaves the subscription behind, attached to the deleted topic, so the second line waits.
Delete the ClickStack source in the UI.
Deleting the service account also invalidates its key.
A deleted custom role can be restored within 7 days, and its ID cannot be reused until it is permanently deleted.
To try again, change `ROLE`.
