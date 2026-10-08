# Findings

English | [日本語](../ja/findings.md)

Results observed on ClickHouse Cloud and Google Cloud test environments from 2026-10-01 to 05.
Pub/Sub ClickPipes is in Private Preview and ClickHouse Cloud upgrades automatically, so the behavior described here may change.

## Environment

| Item | Value |
|---|---|
| ClickHouse Cloud | GCP asia-northeast1, 1 replica, memory autoscaling 8 to 32 GiB, release channel fast, 26.6.1.2191 |
| ClickPipes | Pub/Sub, JSONEachRow, 1 replica (0.125 vCPU, 0.5 GB), created with `clickhousectl` |
| Pub/Sub | Dedicated test topic, 7-day message retention |
| Input | Synthetic LogEntry from `loadgen/gen_logentry.py` (711 bytes on average; 2% late, 0.2% future, 0.2% missing timestamp, 0.5% resent entries) |
| Real logs | Cloud Logging of an internal GCP project (mostly audit logs, about 1.5 KB on average). Used only for parser correctness and CPU comparison |
| Local | clickhouse local 26.7.7.19 |

Completeness was checked with `verify/completeness.sh`, reconciling every message ID the load generator recorded from Pub/Sub responses with `MessageId` in L0 and L1.

## Creating the pipe and its destination

| Question | Result |
|---|---|
| Can an existing table be the destination? | Yes, with columns given by `--column` |
| Virtual column types | `_message_id String`, `_publish_time DateTime64(3)`, and `_attributes Map(String, String)` were accepted and populated |
| Can a Null engine table be the destination? | Yes. The pipe was Running and rows were written through the MV |
| Can the start position be chosen? | `latest`, `earliest`, or `timestamp` at creation. With `timestamp`, reading started at the given time (with topic retention enabled) |
| Pipe inserts | Synchronous INSERT (`async_insert = 0`), Native format, about every 5 seconds |
| Managed subscription | Named `clickpipes-<pipe id>`. 7-day message retention, 60 s ack deadline, ordering enabled, 31-day expiry when inactive |

A pipe created with `clickhousectl` and `--column` was recorded as `managedTable: true` in the API even though an existing table was specified.
Deleting that pipe left the destination table and the error table in place.
The Pub/Sub managed subscription disappeared within 2 minutes of deleting the pipe.
A pipe that was only stopped kept its subscription (unacked messages presumably accumulate up to the 7-day retention).

## Permissions

The MV `SQL SECURITY` mode and the permissions the pipe user needs were tested with a user that has INSERT only.

| MV definition | INSERT by an INSERT-only user |
|---|---|
| No SQL SECURITY clause (the Cloud default) | Failed. SELECT on the MV's source was required; a second-level MV also required SELECT on the intermediate table |
| `DEFINER = default SQL SECURITY DEFINER` | Succeeded, through both MV levels |
| `SQL SECURITY INVOKER` | Not allowed on MVs (error at creation) |

When the MV without a SQL SECURITY clause lacked permissions, rows were written to the source table but not past the MV.

The user of a pipe created with `clickhousectl` has `default_role`, so it never lacked permissions.
When choosing "Only destination" in the UI, create the MVs with a DEFINER.

## When an MV throws

The MV was changed with `MODIFY QUERY` so that `throwIf` raised on specific insertIds, and three such messages were published.

| Observation | Result |
|---|---|
| The failing batch (303 rows) | Written to L0, never reached L1 or the rollup |
| Retries | The same batch was retried after 10 s, 30 s, 70 s, then every 2 minutes. From the second attempt on, L0 deduplicated it (`DuplicatedInsertedBlocks = 1`) |
| Other batches | Kept flowing in parallel |
| Pipe state | Degraded once in 30-second polling, otherwise Running |
| Error table | Stayed at 0 rows |
| Recovery | The first retry after fixing the MV delivered it to L1. Zero missing and zero duplicates across all message IDs |

Nothing was lost because a block deduplicated in L0 is still passed to dependent MVs (the Cloud default `deduplicate_blocks_in_dependent_materialized_views = 1`).
With that setting at 0, the MV would presumably not run once L0 deduplicates the retry, and the rows would be missing from L1 (not tested).

### Left unfixed for more than 60 minutes

On another pipe, the same failure was left unfixed.

| Elapsed | Observation |
|---|---|
| About 60 minutes after the first failure | Messages of the failing batch were redelivered, and L0 held up to three copies (606 duplicates in L0). Part of the redelivered messages was also written to L1 as a separate batch |
| About 62 minutes | Inserts from this pipe stopped. About 15 minutes later its state was Failed. A Failed pipe ingests nothing |
| Fix the MV and `clickpipe start` | Back to Running within 2 minutes; unacked messages were redelivered and the L0 to L1 gap went to 0. Nothing was lost |
| After recovery | 100 entries of the stuck batch were written to L1 twice (once in the redelivery at 60 minutes, once after the restart) |

In this test, ingestion continued with the failure unfixed only for about 60 minutes after the first failure.
After that the pipe stopped, and `MessageId` duplicates remained after recovery.
The restart must happen within the managed subscription's message retention (7 days by default) (derived).

## Schema changes and switches

All were done under a 50 msg/s load.

| Procedure | Result |
|---|---|
| `ADD COLUMN` then `MODIFY QUERY` | 0 failed inserts. Old and new versions never mixed within one INSERT |
| Blue/Green (ORDER BY changed, boundary T on `_publish_time`, backfill from L0) | v2 received only rows from T on; after backfill, zero missing and zero duplicates. The rollup matched v1 too |
| Pipe swap (new pipe seeked to 10 minutes before T2) | Zero missing and zero duplicates in L1. The new landing table received 500 redeliveries, all before T2 and dropped by the boundary condition |
| Rebuilding a day with `REPLACE PARTITION` | L1 was replaced but the rollup kept old values. Rebuilding the rollup made them match |
| Rebuilding from L0 without deduplication | 493 duplicates from redeliveries came back into L1. `LIMIT 1 BY _message_id` brought it to 0 |
| `INSERT ... SELECT` with the MV's SELECT | Columns mapped by position and the insert failed with a type conversion error. Columns must be listed by name in table order |

## EXCHANGE and RENAME (26.6.1, manual inserts)

| Operation | Result |
|---|---|
| `EXCHANGE TABLES` on an MV's target | The MV kept writing to the original physical table (now under the other name) |
| `EXCHANGE TABLES` on an MV's source | The MV followed the name (it fired on inserts into the table that now had the name, not on the original table) |
| `RENAME TABLE` on an MV's source, then recreate under the original name | Inserts into neither the old nor the new name fired the MV, with no error |

## Parsing cost

Reading each LogEntry field with `JSONExtract*` (A) was compared with parsing once with `JSONExtract(_raw_message, 'Tuple(...)')` (B, `sql/30_logs_v1_mv.sql`).
B also changes some outputs, such as `Body` as `serviceName methodName` for audit logs and `METHOD STATUS URL` for HTTP-only logs.
All other columns matched A on 300,000 synthetic rows.

| Data | CPU of A | CPU of B | Ratio |
|---|---|---|---|
| 300,000 synthetic rows (local, 4 threads) | 2.0 s | 0.55 s | about 3.7x |
| 2 million real rows (Cloud, average of 2 runs) | 57.1 s | 20.9 s | about 2.7x |
| Reference: CAST to the JSON type (synthetic, main columns only) | 1.8 s | | |

Across the whole ingest path (pipe INSERT, L0, MV1, L1, MV2), CPU time was about 18 microseconds per message at 2,000 msg/s (synthetic logs, `UserTimeMicroseconds` in `system.query_log`).

## Load and latency

With the smallest pipe (1 replica, 0.125 vCPU), the publish rate was raised every 5 minutes.
Latency is from `_publish_time` to when the MV produced the row (`InsertedAt`).

| Publish rate | Median | p99 |
|---|---|---|
| About 200 msg/s | 2.7 s | 5.2 s |
| About 480 msg/s | 2.6 to 2.9 s | 5.2 s |
| About 980 msg/s | 2.7 to 2.8 s | 5.3 s |
| About 1,950 msg/s (about 1.4 MB/s) | 2.7 to 2.9 s | 5.3 s |

The backlog did not grow at any step.
The p99 of about 5 seconds presumably reflects the pipe inserting about every 5 seconds.
Higher rates (tens of MB/s) were not tested.

## Migrating an existing pipeline (real logs)

An existing pipeline that ingested an internal GCP project's Cloud Logging (landing table with `_raw_message` only, MVs splitting audit and GKE logs) was moved to this layout with the procedure in `sql/runbooks/06_migrate_legacy_pipeline.sql` (appendix A5 in [Operations](operations.md)).
The rate was about 18 msg/s (about 1.55 million entries a day, 96% of them k8s.io Lease update audit logs).

| Item | Result |
|---|---|
| Backfill | 7 days of the old landing table (about 17.8 million rows) in 40 runs of 6 hours each, about 13 seconds per run |
| Duplicates in the old landing table | Dozens per day (e.g. 2,603,218 identities for 2,603,287 rows) |
| Reconciliation | Old and new identity sets matched for every receive hour from 9/24 to 10/01 |
| Pausing and resuming the new pipe | Messages published during the pause arrived after the resume; 4 `MessageId` duplicates remained |
| Parser CPU with the `audit.*` attributes added | 18.8 s on 2 million real rows (20.9 s before; within measurement noise) |

Storage (compressed, per row):

| Layer | Existing pipeline | This layout |
|---|---|---|
| Landing table | 178 bytes (`_raw_message` plus the whole entry in a JSON-typed column) | 99 bytes |
| Main table | 54 bytes (audit logs only, ORDER BY (serviceName, principalEmail, timestamp)) | 86 bytes (including about 13% for text indexes) |

The main table grew mostly because of `OperationId`, which is a unique UUID per event in k8s.io audit logs (22% of the columns), the raw `ProtoPayload` (25%), and the attribute text indexes.
Dropping unneeded logs such as Lease updates with a sink exclusion filter cuts long-term storage substantially.

## Japanese full-text search

ClickStack turned search box words into `hasAllTokens(lower(Body), lower('word'))` and used the text index on `lower(Body)` (confirmed in query_log).
Counts from ClickStack over 35 minutes of synthetic logs (about 1.1 million rows):

| lower(Body) tokenizer | 「タイムアウト」 | "timeout" | Index size |
|---|---|---|---|
| Words (splitByNonAlpha) | 0 | 70,311 | 3.3 MiB |
| 2-character n-grams (ngrams(2)) | 92,517 | 70,311 | 15.1 MiB |
| Reference: counted with LIKE | 92,517 | 70,311 | ― |

- With the word tokenizer, a whole Japanese sentence became one token, and Japanese searches returned 0 rows without an error.
- An expression could have only one text index.
- With ngrams(2), one-character search terms returned 0 rows in both Japanese and English.
- Some search paths in ClickStack emitted `hasToken(lower(Body), lower('word'))` (searches from the MCP server). The ngrams(2) index was used for `hasToken` on Cloud 26.6 (11 of 333 granules) but only for `hasAllTokens` on clickhouse local 26.7. Check both forms with EXPLAIN on your version.
- `hasAllTokens` used the index's tokenizer only in WHERE. In the SELECT list, `countIf(hasAllTokens(...))` returned 0 for Japanese (clickhouse local 26.7.7; in WHERE it returned 1,736, the same as LIKE). Count in WHERE when comparing.

## Reconciling with the sink's export count

The hourly difference between Cloud Monitoring `logging.googleapis.com/exports/log_entry_count` (per sink) and L0 rows per publish hour was under 0.1% in each of three hours (alternating sign, 0.03% over the three hours).

## Bytes that drive Pub/Sub cost

The [price list](https://cloud.google.com/pubsub/pricing) charges $40/TiB each for publish and delivery (the first 10 GiB per month, shared by publish and delivery, is free; minimum 1 KB per request).
Volumes over three hours were measured in Cloud Monitoring with one all-logs sink and one running pipe.

| Item | Bytes | Metric |
|---|---|---|
| Billable Cloud Logging ingestion | 74.3 MB | `logging.googleapis.com/billing/bytes_ingested` |
| Bytes exported by the sink | 369.1 MB | `logging.googleapis.com/exports/byte_count` |
| Pub/Sub publish | 368.2 MB | `pubsub.googleapis.com/topic/byte_cost` |
| Pub/Sub delivery | 376.9 MB | `pubsub.googleapis.com/subscription/byte_cost` (streaming_pull) |

- Bytes sent to Pub/Sub were about 5 times the billable Cloud Logging volume. 74% were Admin Activity audit logs routed to `_Required`, which Cloud Logging does not bill, and 59% were Kubernetes Lease updates.
- In price, Pub/Sub (publish and delivery) came to about 78% of the Cloud Logging ingestion charge.
- For the logs Cloud Logging bills, the JSON sent to Pub/Sub was about 1.2 times the billable volume, so Pub/Sub would cost about 20% of the ingestion charge.
- On the delivery side, acks (55.3 MB) and ack deadline extensions (179.8 MB) were also counted in byte_cost. Whether they are billed was not confirmed.
- Counting Lease updates alone over one day (2026-10-04, two GKE clusters) gave 2.1 million messages, 2.71 GiB of message data. At the publish and delivery prices that is about $6.4 a month, or about $3 per cluster (a rough figure that ignores the free tier and the 1 KB minimum). The counted rows (`gcl_noise_1m_v1`) and the matching rows in L0 were both 2,103,762, with zero in L1.
- A stopped pipe's managed subscription had accumulated 1.7 million messages, 2.3 GB, 19 hours after the stop. Messages older than one day incur storage charges.

## Attribute Maps and indexes (against the ClickStack default schema)

Attributes use the Map type, as ClickStack officially recommends (the JSON type is beta in ClickStack and suited to small, stable key sets).

**SQL and index use for attribute filters** (Cloud 26.6, 400,000 rows)

- With `LogAttributeItems` (an ALIAS column of `key=value` strings) on the table, ClickStack turned attribute filters into `has(LogAttributeItems, 'key=value')`. The text index on that column applied, and 8,192 rows were read.
- Without the column, ClickStack generated `LogAttributes['key'] = 'value' AND indexHint(mapContains(...))`. In that form the `key=value` index did not apply; an index on `mapValues` did (clickhouse local 26.7).
- L1 therefore has `ResourceAttributeItems` and `LogAttributeItems` with their indexes, as in the default schema.

**Map serialization (`with_buckets`)** (Cloud 26.6, one day of real logs, 1.2 million rows, 2 to 12 attribute keys per row on average and 22 at most, median of 3 runs)

| Query | Basic | with_buckets (default) | with_buckets (forced split) |
|---|---|---|---|
| Filter on one key | 196 ms | 167 ms | 150 ms |
| Search with `has(LogAttributeItems, ...)` | 20 ms | 19 ms | 20 ms |
| Aggregate on one key | 177 ms | 211 ms | 126 ms |
| Read the whole Map | 181 ms | 180 ms | 440 ms |
| Storage (compressed) | 23.6 MiB | 23.5 MiB | 26.0 MiB |
| One INSERT | 4.4 s | 4.1 s | 5.6 s |

- With the default `map_buckets_min_avg_size = 32`, the average key count was under 32, so nothing was split and the layout was the same as basic.
- Forcing the split (threshold 0) made single-key queries 20 to 30% faster, but whole-Map queries 2.4 times slower, storage about 10% larger, and inserts almost 30% slower.
- L1 sets `with_buckets` and keeps freshly inserted parts basic. Only parts whose average exceeds 32 keys are split, automatically, during merges.

## Moving the main L1 (Blue/Green, 2026-10-02)

The L1 with the old schema (index on attribute values, word tokenizer for the body) was moved to `gcl_logs_v2` with the new schema (`key=value` indexes, ngrams(2) for the body, `with_buckets` Maps) following `sql/runbooks/03_blue_green.sql` (appendix A3 in [Operations](operations.md)).

- The MV feeding rows published from T on was created 5 minutes before T. The first v2 row was published 0.348 seconds after T, and the number of MessageIds from T on matched v1 (1,813).
- Rows before T were copied from v1 in 6-hour ranges, checking counts per range (18,921,930 rows in total). One count check failed and stopped the run, but it was before the copy, so the run resumed by skipping completed ranges.
- Daily counts, MessageId duplicates (641), and rollup totals matched between v1 and v2.
- The ClickStack source and the stable view were switched to v2. Attribute filters were generated as `has(LogAttributeItems, ...)`, narrowing rare values down to 1 of 333 granules.

## Parser v7 (strict envelope, loose payload)

v6 parsed L1 with audit logs in mind and listed LogEntry envelope fields by hand. v7 drops assumptions per log kind and puts envelope fields without a column into attributes without listing their names.

**Checks with differently shaped logs** (clickhouse local 26.7)

| LogEntry shape | v7 ServiceName | v7 Body | Attributes added |
|---|---|---|---|
| Non-audit protoPayload (App Engine, with httpRequest) | Module name | `GET 200 /items` | `http.responseSize`, `http.protocol`, `proto.type` |
| Same, without httpRequest | Module name | `[google.appengine.logging.v1.RequestLog] {...}` | `proto.type` |
| jsonPayload with httpRequest and no message (load balancer style) | resource type/log id | `GET 503 https://...` | `http.responseSize`, `http.cacheHit`, `http.referer` |
| Split entry | resource type/log id | textPayload | `entry.split` |
| With `otel`, `apphub`, `errorGroups`, `operation.first` | Service name | message | `entry.otel`, `entry.apphub`, `entry.errorGroups`, `operation.first` |
| No payload | resource type/log id | `[log id]` | None |
| Audit log | API service name | `service method` | `audit.*`, `proto.type` |

In v6, non-audit protoPayloads had an empty ServiceName and a single-space Body.

- On 300,000 synthetic rows, ServiceName, Body, and existing attributes matched v6, and the attribute count grew by 16%. INSERT CPU time went from 1.53 s to 1.78 s (16% more).
- After applying it to the main pipeline with `MODIFY QUERY`, failed inserts and stuck batches were 0. In real logs, `operation.first` and `operation.last` of GKE operation logs are now kept (v6 dropped them).

## Extracting from L1 versus a typed table (L2)

A table of GKE upgrade notifications (node pool, versions, count, failures, average duration) was built by extracting from L1 attributes at query time and compared with a typed table (9 days; L1 had 18.94 million rows).

| Built from | Result | Time | Rows read |
|---|---|---|---|
| L2 (typed table) | 6 rows | 13 ms | 55,000 |
| L1 (filtered by log id) | The same 6 rows | 623 ms | 18.94 million |
| L1 (filtered by ServiceName, 1 day) | ― | 159 ms | 1.1 million |

- The L1 sort key starts with a 5-minute bucket, so filtering by ServiceName barely reduces reads; the time range decides.
- Reads grow with the number of rows in the time range: 159 ms for one day (1.1 million rows) and 623 ms for nine days (18.94 million rows). At this scale, dashboards run well on L1 alone.

## Text index

`hasToken(lower(Body), 'timeout')` used `idx_lower_body`.
The plan was the same through the stable view (`gcl.logs`).

## Deployment procedures (Terraform and gcloud/clickhousectl, 2026-10-02)

Both procedures were run from creation to removal on a test project and service.
`cli/deploy.sh` and `cli/destroy.sh` were later removed from the repository; the same commands are in part 3 of the [Hands-on](hands-on.md).

| Procedure | Result |
|---|---|
| `terraform apply` (including the ClickStack source and dashboard) | Created 11 resources in about 50 seconds; the pipe was Running. A pipe into the existing L0 (`managed_table = false`) was accepted |
| `cli/deploy.sh` | Created everything in about 70 seconds; the pipe was Running. A second run skipped the topic, sink, role, service account, key file, and pipe |
| Publishing 600 synthetic messages and reconciling (both) | Zero missing and zero duplicates in L0. Only the mixed-in Lease updates stayed out of L1; L1 plus noise counts equaled L0, and the L3 total equaled L1. Real logs from the sink started arriving within minutes |
| ClickStack source (created by Terraform) | Searching 「タイムアウト」 returned logs with Japanese bodies |
| `terraform destroy`, `cli/destroy.sh` | The topic, sink, managed subscription, service account, and pipe were gone. The custom role remained soft-deleted (restorable) |

## Deploying to a new service in Tokyo (Terraform, 2026-10-05)

A new service (26.6, 8 GB memory) was created in GCP Tokyo (`asia-northeast1`) with `clickhousectl cloud service create`, and the [Setup](setup.md) steps were run against it from an empty state.
Message storage was pinned to Tokyo with `topic_storage_regions = ["asia-northeast1"]`, the sink filter matched no real logs, and only synthetic logs were published.

| Step | Result |
|---|---|
| `terraform plan` | 9 resources to add (before `terraform_data.subscription_cleanup` was added) |
| `terraform apply` | Done in about 57 seconds; the pipe was Running. Message storage was `asia-northeast1` only, with the label `managed-by=terraform` |
| Managed subscription | 60 s ack deadline, 7-day retention, ordering on, 31-day expiration |
| 600 synthetic messages (20% Lease updates) | No loss and no duplicates in L0. L1 (476) plus the noise counts (124) equalled L0, and the L3 total equalled L1. The GCE ServiceName was the VM name |
| `verify/checks.sql` | 0 stuck batches, 0 failed inserts, 0 `MessageId` duplicates, publish-to-insert p99 about 5.7 s |
| `terraform destroy` (without the wait) | Removed 9 resources, but the managed subscription was left behind, attached to the deleted topic (`_deleted-topic_`). Deleting the pipe returned in 0 seconds and the key and binding were removed right after |
| `terraform destroy` (with the wait) | Waited 23 seconds after deleting the pipe until the managed subscription was gone, then removed the key and binding. Nothing was left |

- The first `tools/chq.py` run against the new service made `clickhousectl` create a Query API endpoint and key.
- The same project held two older managed subscriptions attached to `_deleted-topic_`, dated before this test. The 2026-10-02 removal check may have missed this.

## Setup in the browser (2026-10-05)

The [Setup in the browser](setup-console.md) steps were run in the Google Cloud and ClickHouse Cloud consoles only, against a test project and a new service in Tokyo (Mini, 26.6).
The sink filter was replaced with one that matches no real logs after the screenshot was taken, and only synthetic logs were published.

| Step | Result |
|---|---|
| Topic | "Add a default subscription" was checked by default on the create page. Message storage could be restricted to `asia-northeast1` under Storage policy in the info panel of the edit page |
| Sink | Created in the console by an account with Owner access to the topic, the sink's writer identity (the project-wide `service-<project-number>@gcp-sa-logging.iam.gserviceaccount.com`) got publish permission on the topic (`roles/pubsub.publisher`) automatically |
| Custom role | The permission picker's filter accumulates conditions; the seven permissions were selected one at a time, removing the filter in between. The API showed all seven |
| SQL console | `sql/10` to `50` pasted into one query ran together with Run, creating four tables and three MVs |
| ClickPipe | "GCP Pub/Sub" was labelled Beta in the source list. With the existing L0 selected, the four virtual columns were mapped to the columns of the same names automatically and the JSON fields stayed unmapped. A sample fetch was required before the next step |
| Permission "Only destination" | The page warned "No access to Materialized Views". The pipe user had only SELECT, INSERT and similar grants on L0 and its error table (`system.grants`), yet with 600 synthetic messages (115 Lease updates) L0 had no loss or duplicates, L1 (485) plus the noise counts (115) equalled L0, and the L3 total equalled L1 |
| ClickStack source | Saved with the optional fields set as in Terraform; タイムアウト ("timeout") returned 42 rows. The GCE ServiceName was the VM name |
| Removal | After deleting the pipe and confirming its managed subscription was gone, the sink, topic, role binding, service account, role and service were deleted |

## Backfilling existing logs (2026-10-05)

The "Backfilling existing logs" procedure in [Operations](operations.md) and `sql/runbooks/10_backfill_from_gcs.sql` were tried on 3 hours of the test project's `_Default` bucket (2026-10-04 00:00 to 03:00 UTC).
The destination was a separate database with no pipe.
The same window had also reached the main L1 through the sink, so the two were compared row by row.

| Item | Result |
|---|---|
| Copy (`entries:copy`) | 151,192 entries, 48 files, 116 MB. 76 minutes from start to finish (10 queued). Progress seemed stuck at 71% for over 30 minutes, and no file appeared until just before completion |
| File layout | `<log id>/YYYY/MM/DD/<time range>_copy_log_entries_..._S0.json`, one file per hour. One LogEntry JSON per line, the same shape the sink publishes |
| Read check (runbook Step 2) | 151,192 lines, equal to the copy count. 0 lines that are not JSON, 0 duplicate LogEntry identities |
| Insert into L0 (`gcs()`, HMAC key) | Four one-hour chunks of receive time, 1.5 to 2.6 s each. L0 = L1 = L3 total = 151,192, 0 duplicates. Noise 0 (Lease updates go to `_Required`) |
| Comparison with the main L1 | 0 backfilled rows missing from the main L1. The 32,379 rows only in the main L1 were 32,376 Admin Activity and 3 System Event audit logs, both stored only in `_Required` |
| HMAC key | `system.query_log` kept the key ID; the secret was `[HIDDEN]` |
| Copy from `_Required` (same day, 00:00 to 00:10) | Succeeded: 16,300 entries, 2 files (Admin Activity, System Event), 23 MB, about 48 minutes. The 14,617 Lease updates equalled the main noise counts (14,617), and every other row was in the main L1 |

The boundary handling and rows older than the L0 TTL were checked on clickhouse local 26.7:

- 3,000 synthetic entries with the boundary in the middle of the receive times: the part after it was inserted as the pipe would, the rest with Steps 3 and 4 of the runbook. L1 (2,364) plus the noise counts (636) made 3,000, with 0 duplicate LogEntry identities. Without the L0 check of Step 4, 319 rows were duplicated in L1 and the noise counts grew by 81.
- 10 rows dated 20 days ago in a table set up like L0 (7-day TTL, `ttl_only_drop_parts = 1`): 10 right after the insert, 0 after 3 s; they stayed with background merges stopped. The MVs run on the INSERT, so L1 got them.
- On Cloud 26.6 with the same table and an MV, `system.part_log` showed a `TTLDropMerge` 0.1 s after the inserted part (10 rows), and the MV target had all 10 rows.

## Final check (2026-10-06)

After the final-review fixes, the Terraform steps of [Setup](setup.md) and part 2 of the hands-on were run against a Tokyo service with `topic_storage_regions = ["asia-northeast1"]`.

| Step | Result |
|---|---|
| `terraform apply` | About 69 seconds, 10 resources, pipe Running |
| 3,000 synthetic messages (20% Lease updates, 1% repeated content) | No loss in L0. L0 3,050 = L1 2,428 + noise counts 622, L3 total = L1. `MessageId` duplicates (Pub/Sub redeliveries): 50 in L0, 45 in L1 |
| Adding the L2 (with the wait for T) | The wait ended 3 seconds after T. Distinct `MessageId`s were 668 in both the L2 and the L1 audit logs; L1 had 6 more rows, all redeliveries |
| Adding the L3 | L3 total and L1 row count both 8,405 |
| `verify/checks.sql` | 0 stuck batches, 0 failed inserts |
| `terraform destroy` | Waited 24 seconds for the managed subscription to go, then removed the key and binding. Nothing was left |
| `tools/chq.py`, `verify/completeness.sh` | Run from the top of the repository; `clickhousectl` used the API key from the environment |
| Hands-on part 3 (gcloud and clickhousectl) | Run as written from creation to removal. Key creation right after the service account was created failed with `NOT_FOUND` and succeeded on a retry 10 seconds later. A pipe created with `clickhousectl` 0.4.2 without `--enable-ordering` still had ordering enabled on its managed subscription. 6,000 synthetic messages, no loss, 200 redelivery duplicates in each of L0 and L1. The managed subscription was gone 22 seconds after the pipe was deleted. The writer identity of the gcloud-created sink was also the project-wide `service-<project-number>@gcp-sa-logging.iam.gserviceaccount.com` |

## Workload identity (2026-10-07)

ClickPipes workload identity (Private Preview) was tested in the test environment (GCP Tokyo) with the feature enabled for the organization, through the OpenAPI and ClickHouse Terraform provider v3.35.0; the Terraform switch was retested with v3.37.0 on 2026-10-08.

| Step | Result |
|---|---|
| Service context (`clickpipes/context`) | `gcpWorkloadIdentity.supported` and `ready` both true; the identity to grant is `ch-<id>@clickpipes-production.iam.gserviceaccount.com` |
| New pipe through the OpenAPI | Created with `SERVICE_ACCOUNT_WORKLOAD_IDENTITY` after granting the custom role. 1,200 synthetic messages, no loss in L0. The managed subscription was gone 22 seconds after the pipe was deleted |
| Switching a key-based pipe with PATCH | Only the authentication was sent, while synthetic messages flowed. Same pipe and managed subscription, Running throughout, 4,800 messages with no loss. Ingestion continued after the key's service account was deleted (1,800 messages, no loss) |
| New deployment with Terraform (`clickpipes_auth = "workload_identity"`) | 8 resources, pipe Running, no loss with synthetic messages. `terraform destroy` removed the 8 resources and left nothing |
| Switching from a key with Terraform (v3.35.0) | Provider v3.35.0's pipe update also sends the unchanged `format` and failed with `format is immutable for Pub/Sub sources and cannot be changed via PATCH`. The old binding and key were removed before the pipe update, so the pipe went Degraded and 1,000 messages did not arrive. After a PATCH it was Running again in about 20 seconds, and with those 1,000 there was no loss. Switching the pipe with a PATCH and then running `terraform state rm` and `terraform import` let the next apply succeed. The provider bug is [#745](https://github.com/ClickHouse/terraform-provider-clickhouse/issues/745), fixed in v3.37.0 |
| Switching from a key with Terraform (v3.37.0, no `create_before_destroy`) | One apply with `clickpipes_auth` changed while 10 synthetic messages per second flowed (about 46 seconds). The old key and binding went first; the pipe was updated about 20 seconds later. The pipe stayed Running until the update, then went through Provisioning for about 13 seconds back to Running |
| Switching back to the key (v3.37.0) | One apply created the service account, key and binding, switched the pipe back to the key, then removed the workload identity binding |
| Switching from a key with Terraform (v3.37.0, with `create_before_destroy`) | Order: workload identity binding, pipe update, then removal of the old key, binding and service account (about 25 seconds). Across the three switches, all 4,800 messages sent arrived in L0. 400 redelivery duplicates in L0 and L1; distinct `MessageId`s in L1 matched at 4,800. `terraform destroy` removed 8 resources and left nothing |
| Main pipe of the test environment | Switched with PATCH and stayed Running for 5 minutes. The old key and binding were deleted about 22 minutes later; ingestion continued |
| In the browser (steps 5 and 7 of [Setup in the browser](setup-console.md)) | Choosing "Workload identity" under "Authentication method" showed the service account to grant. After granting the custom role with "Grant access" in IAM, the connection check and the topic list passed. Running about 30 seconds after creation; the 3,800 synthetic messages sent after creation arrived in L0 and L1 with no loss |
| `clickhousectl` | 0.4.2 (2026-09-03) requires a key file and cannot create workload identity pipes; support is in unreleased changes |

## Not tested

- Replicas needed at tens of MB/s
- Real logs from sources other than GKE (such as Cloud Run request logs); synthetic logs were used instead
