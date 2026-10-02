# Operations

English | [日本語](../ja/operations.md)

Most operational work is adding noise rules, creating and reworking L2 tables, and adding L3 tables.
L1 fixes only the envelope as columns and takes the payload as attributes, so new kinds of logs rarely require rebuilding L0 or L1.
Rebuilding and switching L0 and L1 is for recovery or redesign only, so those procedures are in the appendix.

SQL templates for each procedure are in `sql/runbooks/`.
This page covers the preconditions of each procedure and the caveats observed on real services.
Numbers and conditions are in the [findings](findings.md).

## Daily checks

The pipe state does not reveal a stuck batch until the pipe is Failed.
Check the following regularly with `verify/checks.sql`.

| Check | `verify/checks.sql` | Abnormal when | Action |
|---|---|---|---|
| Loss anywhere on the path | Check 9 and Cloud Monitoring `logging.googleapis.com/exports/log_entry_count` | Differs from the sink's export count by more than 1% (normally under 0.1%) | Check the pipe state, the Pub/Sub backlog, and sink export errors |
| Stuck batches | Check 2 | Greater than 0 | "Detecting and recovering MV failures" |
| Failed inserts | Check 6 | One or more | "Detecting and recovering MV failures" |
| Ingest latency | Check 1 | p99 above 10 s and growing | Add pipe replicas. Also check the age of unacked Pub/Sub messages |
| Duplicates | Check 3 | Increased after a failure or pause | Deduplicate in queries, or rebuild the day with appendix A2 |
| Pipe state | `clickhousectl cloud clickpipe get` | Failed | "Detecting and recovering MV failures" |

```bash
export CH_SERVICE_ID=<service id>
python3 tools/chq.py verify/checks.sql
```

## Choosing a procedure

| Goal | Procedure | SQL | Pipe stop |
|---|---|---|---|
| Drop high-volume, low-value logs | Noise rules and normalization for every log | `sql/runbooks/07_add_noise_rule.sql` | No |
| Give typed columns to logs with requirements L1 cannot meet; rework an existing L2 | Creating and reworking an L2 | `sql/runbooks/08_add_or_rework_l2.sql`, examples in `sql/examples/` | No |
| Fast long-range trends; keep only aggregates for longer | Adding an L3 | `sql/runbooks/09_add_l3.sql`, `09_add_l3_backfill.sql` | No |
| An MV throws; the pipe is Failed | Detecting and recovering MV failures | `sql/runbooks/05_mv_failure.sql` | ― |
| Extract another column | Appendix A1 | `sql/runbooks/01_add_column.sql` | No |
| Fix the parser, including past days | Appendix A2 | `sql/runbooks/02_rebuild_partition.sql` | No |
| Change types, ORDER BY, partitioning, or engine | Appendix A3 | `sql/runbooks/03_blue_green.sql` | No |
| Change pipe settings that cannot be edited after creation | Appendix A4 | `sql/runbooks/04_pipe_swap.sql` | No (run in parallel) |
| Move from an existing pipeline without `_publish_time` | Appendix A5 | `sql/runbooks/06_migrate_legacy_pipeline.sql` | No (run in parallel) |

Many procedures use a boundary time T.
T is a `_publish_time` (Pub/Sub publish time) a few minutes after the work starts.
Old and new MVs split the rows before and from T, so nothing is missed or ingested twice.

## What "no downtime" means

Reads, ingestion, and completeness are treated separately.

| Goal | Meaning | What the procedures here were shown to achieve |
|---|---|---|
| Read continuity | ClickStack and SQL searches keep working | Readers switch by replacing a view or changing the source setting, with no outage |
| Ingest continuity | The ClickPipe is never stopped | Adding a column, fixing the parser, Blue/Green, and swapping the pipe all completed without stopping the pipe |
| Completeness | No received message is lost or counted twice | All published message IDs reconciled with L1: zero missing, zero `MessageId` duplicates |

Completeness can only be checked for data still within the retention of L0 and the Pub/Sub topic.
Data past retention can be neither rebuilt nor reconciled.

## Noise rules and normalization for every log

### Drop noise in the MV and keep only counts

High-volume logs with little value per entry are, by default, kept out of L1 by the `WHERE` of MV1.
A separate MV (`sql/50_noise_rollup_v1.sql`) keeps the same rows as per-minute counts.
What counts as noise depends on the environment; in the test environment it was Kubernetes Lease update audit logs.
The template for adding a rule is `sql/runbooks/07_add_noise_rule.sql`.

- L0 keeps the raw rows for its retention, so a rule can be reverted by rebuilding from L0.
- Counts remain, so a stop in the updates (a controller going down) is visible in a chart.
- Pub/Sub and ClickPipes volume does not go down. For high-volume logs that also stay in Cloud Logging (such as `_Required`) and that you never search in ClickHouse, an exclusion filter on the sink is an option; then no counts remain either. In the test environment, Lease updates were 59% of the bytes sent to Pub/Sub, but only about $4 per cluster per month ([findings](findings.md)).

Switching a rule uses a `_publish_time` boundary T like the other procedures.
The noise MV counts only rows with `_publish_time >= T`, and MV1 drops only rows with `_publish_time >= T`.
In testing, the counts after the boundary (1,940) matched the matching rows in L0 (1,940), with zero in L1.

### Normalization that applies to every log goes into MV1

- For logs whose JSON key is `msg` (istio, cilium, and others), Body uses `msg` when `message` is absent.
- `key="value"` bodies (klog, logfmt) are split with `extractKeyValuePairs` into `kv.*` attributes. `latency` is also converted to milliseconds as `kv.latency_ms`.

GKE container logs already had JSON `level` converted to severity during collection, so no severity normalization was needed.

## Creating and reworking an L2

An L2 is optional. Build one only when one of the signals below applies. Otherwise, search L1 and extract values into tables and charts.

| Signal for an L2 | Try first |
|---|---|
| A screen used daily exceeds its target response time (e.g. a few seconds) on L1 (L1 reads all rows in the time range) | Narrow the time range. Use an L3 aggregate |
| You often filter on a column (an audit log operator, a node pool) and the L1 sort key cannot skip data for it | Move the value into a column in the L1 sort key (such as `ServiceName`) |
| Time or number calculations are heavy or error-prone to write in every query, or are used in alert conditions | Write the expression once in a dashboard tile |
| You need separate retention, access, or deletion rules per log kind | None (an L2 separates them) |
| You need deduplicated results or only the latest state | Use `LIMIT 1 BY` at query time |

Do not build one for one-off investigations, low-volume logs, or logs whose payload shape is not stable.
First build the same table or chart from L1 alone, and confirm that the L2 returns the same result.

**Create**

1. Create the typed table and an MV that reads only the matching logs from L0 (the MV takes `_publish_time >= T`).
2. After T has passed, backfill the rows before T from L0 with `LIMIT 1 BY _message_id`.
3. Register it as a ClickStack log source and point the dashboard tiles at it.

An L2 reads L0, so its MV repeats MV1's noise rules.
L1 is untouched, so overall search is unaffected.

**Rework** (add columns, change the sort key)

1. Under a name with the next version number, create the new table and a boundary MV that reads L0 (`_publish_time >= T`).
2. Backfill the rows before T from L0. For older rows no longer in L0, copy from the old L2 only the range before the oldest publish time still in L0, converting columns as needed.
3. Switch the ClickStack source to the new table. After the rollback window, drop the old MV and table.

The template is `sql/runbooks/08_add_or_rework_l2.sql`; the examples are `sql/examples/l2_audit_events_v1.sql` (used in the hands-on) and `sql/examples/l2_gke_upgrades_v1.sql`. An L2 is built from L0, so it reaches back only as far as L0's retention. Older rows come from the old L2 when reworking, limited to the range before the oldest publish time in L0.

## Adding an L3

Add an aggregate table (L3) on top of L1 or an L2 when long-range trend charts must be fast, or when aggregates must be kept longer than rows.
The per-minute counts in `sql/40_rollup_1m_v1.sql` are one.

1. Create the aggregate table and an MV that reads L1 (or an L2) (the MV takes `PublishTime >= T`).
2. After T has passed, fill the rows before T with an `INSERT ... SELECT` using the same GROUP BY.
3. For a closed range, confirm that the L3 total matches the source row count.
4. Point the ClickStack tiles (SQL tiles) at the L3.

MVs fire only on INSERT, so the past must be filled with `INSERT ... SELECT`. After partition operations on the source (the appendix procedures), rebuild the same range of the L3 too. The templates are `sql/runbooks/09_add_l3.sql` (table and MV) and `sql/runbooks/09_add_l3_backfill.sql` (fill the past and compare, after T).

## Detecting and recovering MV failures

When an MV threw an exception, the behavior was:

1. The failing batch was written to L0 but never reached L1.
2. The pipe retried the same batch after 10 s, 30 s, 70 s, then every 2 minutes.
3. Other batches kept flowing; the pipe state was Degraded briefly and then back to Running. The error table stayed empty.
4. After fixing the MV with `MODIFY QUERY`, the next retry delivered the batch to L1 with no loss and no duplicates.

Point 4 holds because the block is deduplicated in L0 and still passed again to the dependent MVs.
This comes from the ClickHouse Cloud default `deduplicate_blocks_in_dependent_materialized_views = 1`.

In testing, however, the pipe went Failed and stopped ingesting about 60 minutes after the first failure.
Fixing the MV and restarting with `clickpipe start` lost nothing, but part of the stuck batch was written to L1 twice.
After a restart, check `MessageId` duplicates with check 3 in `verify/checks.sql`, and deduplicate in queries or rebuild the range with appendix A2.

The pipe state does not show a stuck batch until Failed, so monitor the L0 to L1 gap and failed inserts in `system.query_log`.
The SQL is in `sql/runbooks/05_mv_failure.sql`.

Fix MVs with `MODIFY QUERY`; never drop and recreate them.
Blocks inserted between DROP and CREATE skip the MV and stay only in L0.

## Operations to avoid

| Operation | Observed on 26.6.1 |
|---|---|
| `EXCHANGE TABLES` on an MV's target | The MV kept writing to the original physical table (now under the other name) |
| `EXCHANGE TABLES` on an MV's source | The MV followed the name and fired on inserts into the table that now had that name |
| `RENAME TABLE` on an MV's source | Inserts into either the old or new name no longer fired the MV, with no error |

Some ClickHouse versions also had a bug where MVs stopped firing after `EXCHANGE` ([ClickHouse#105021](https://github.com/ClickHouse/ClickHouse/issues/105021)).
Use `EXCHANGE` only for read-only tables not connected to any MV or pipe.

Also avoid dropping and recreating an MV (inserts in between skip it), reusing an MV's SELECT as is in `INSERT ... SELECT` (columns map by position and values shift), and rebuilding from L0 without deduplication (redeliveries return to L1).

## Cleanup

- A stopped pipe keeps its managed subscription, which keeps accumulating messages. Delete pipes you no longer use.
- Deleting a pipe leaves the destination table and the error table. Drop them separately if not needed.

## Appendix: rebuilding and switching L0 and L1 (recovery)

L1 fixes only the envelope as columns and takes the payload loosely, so it rarely needs rebuilding. These procedures are for recovery: fixing the parser, changing L1 types or sort key, replacing the pipe, or migrating from an existing pipeline.

### A1 Adding a derived column

`ADD COLUMN` on the target first, then replace the MV with `ALTER TABLE ... MODIFY QUERY`.
In the reverse order, the MV would produce a column that does not exist.

`MODIFY QUERY` replaces the whole SELECT, so keep the full MV SELECT in version control.
Bump `ParserVersion` so the switch point can be traced later.
In testing, old and new versions never mixed within one INSERT.

Existing rows keep the default value in the new column.
If past values are needed, rebuild with A2, within L0's retention.
Avoid `MATERIALIZE COLUMN` over 400 days; it runs as a heavy mutation.

### A2 Fixing the parser and rebuilding past days

The fix itself is a `MODIFY QUERY`, as in A1, and rows are correct from the time of the fix.
Days before the fix are rebuilt from L0 into a work table and replaced day by day with `REPLACE PARTITION`.

- **`REPLACE PARTITION` does not fire downstream MVs.**
  Replacing L1 leaves the per-minute rollup with old values.
  Rebuild the same day's rollup partition from the rebuilt rows and replace it too.
- **`INSERT ... SELECT` maps columns by position.**
  MVs map columns by name, so pasting an MV's SELECT shifts columns.
  Different types stop with a conversion error, but columns of the same type swap values and succeed.
  Wrap the MV SELECT in a subquery and list the target columns in table order outside it.
- **L0 keeps Pub/Sub redeliveries as they arrived.**
  Add `LIMIT 1 BY _message_id` when reading L0.
  A test without it returned 493 duplicates to L1 for an 8-minute range.
- **`REPLACE PARTITION` replaces all existing data for the day.**
  Use it only for days whose late arrivals have settled, never for today.
  The late-arrival distribution can be measured with check 4 in `verify/checks.sql`.

### A3 Changing types, ORDER BY, PARTITION BY, or engine (Blue/Green)

Create a new table `gcl_logs_v2` and an MV that feeds it only from boundary time T on.
The boundary uses `_publish_time`.

`_publish_time` is when Pub/Sub accepted the message, so it always precedes the INSERT.
If the new MV exists before T, every message with `_publish_time` from T on is inserted after the new MV was created.
Messages before T, even if late, are written to the old table by the old MV.
Set T 5 to 10 minutes after creation.

A LogEntry `timestamp` can be anywhere in the retention window in the past and up to 24 hours in the future, so it cannot be the boundary.

Backfill into a work table and move it with `MOVE PARTITION`.
`MOVE PARTITION` does not delete existing data at the destination, so it works for days that already have rows from T on.
`MOVE PARTITION` does not fire downstream MVs either, so insert rows aggregated from the work table into the v2 rollup first.
Late logs land in past-date partitions, so move every partition the work table has.
In testing, a backfill of about 20 minutes before T spanned two daily partitions.

When types or columns change, backfill from L0 (within its retention).
Converting from the old table cannot produce values the old table does not have.

Readers switch through the table name in the ClickStack source, and through a stable view (`CREATE OR REPLACE VIEW gcl.logs`) for SQL users.
Primary key and text index filtering still worked through the view.

Until the old MV is stopped, the old table keeps receiving writes, so rolling back is only a matter of switching readers back.
During that time writes are doubled, which costs insert CPU and storage.

### A4 Changing the ClickPipe itself

To change settings that cannot be edited after creation (such as a subscription filter), create a new pipe and run it in parallel.
The new pipe creates a new subscription, which receives a copy of every message.

Create the new pipe with start position latest before boundary time T2.
A new subscription receives every message published after it is created, so nothing from T2 on is missed.

Do not enable message retention on the Pub/Sub topic by default.
With retention, every published message incurs storage for the retention period ($0.27/GiB per month; 1.5 TiB a day kept for 7 days is about $2,900 a month).
L0 already holds the replay data, so the roles overlap too.

Only if the new pipe could not be created before T2, recreate it with `--seek-type timestamp` from a time before T2.
In testing, reading started exactly at the given time.
In that case, enable a short retention (for example one day) before the work and remove it afterwards.
You cannot seek to messages published before retention was enabled.

As with Blue/Green, boundary time T2 splits the work.
Create an MV that feeds rows from T2 on from the new landing table, and narrow the old MV to rows before T2 with `MODIFY QUERY`.
After a seek, the replayed range contains duplicates (500 in testing), but they are all before T2 and are dropped by the boundary condition.

Stop the old pipe only after the old landing table has passed T2 with no stuck batch.
Delete it after the rollback window.

### A5 Migrating from an existing pipeline without `_publish_time`

If the old landing table has no `_message_id` and `_publish_time`, the boundary-based A3 and A4 cannot be used.
Instead, switch using the LogEntry identity `(logName, insertId, timestamp)` and `receiveTimestamp` as a stand-in for `_publish_time`.
On real logs, `receiveTimestamp` preceded the Pub/Sub publish time by 0.2 to 2.4 seconds.

1. Create a new pipe on the same topic with `--seek-type latest` into the new layout. Record the first `_publish_time` delivered as T_new.
2. Backfill rows of the old landing table whose `receiveTimestamp` is more than 10 minutes before T_new, with the new parser. The old landing table also contains redeliveries, so deduplicate on the LogEntry identity.
3. For the remaining 20 minutes or so around the boundary, compare identities with what the new pipe wrote and insert only the missing ones.
4. While both run, compare the identity sets per receive hour and confirm the difference is zero.
5. Switch readers and stop the old pipe. Drop the old table after the rollback window.

The backfill here is a normal INSERT, so the rollup MV fires and the rollup stays consistent.

When generating backfill SQL, check at generation time that the MV body's `FROM` was replaced with the old landing table.
In testing, one replacement was missed and rows from another landing table got in.
Checking the `tables` column of `system.query_log` after the INSERT shows whether the source was the intended table.
