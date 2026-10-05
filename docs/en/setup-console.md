# Setup in the browser

English | [日本語](../ja/setup-console.md)

For environments without Terraform: the same configuration as [Setup](setup.md), built only in the Google Cloud console and the ClickHouse Cloud console.
It replaces Terraform; do not run both.
Read "Before you start" in [Setup](setup.md) first.
The screenshots were taken on 2026-10-05.

It creates the same resources as Setup, except the ClickStack dashboard (Terraform only).
Unlike Terraform, nothing records what was created, so note the names for removal.

## Values to decide

The examples use `gcl-console-1005` names throughout.
Replace them with your own.

| Item | Example | Used in |
|---|---|---|
| Google Cloud project ID | `<project>` | Sink, ClickPipe |
| ClickHouse Cloud service name | `gcl-console-1005` | 1 |
| Topic ID and sink name | `gcl-console-1005` | 2, 3, 7 |
| Custom role ID | `clickpipesConsole1005` | 4, 5 |
| Service account ID | `clickpipes-console-1005` | 5 |
| ClickPipe name | `gcl-console-1005` | 7 |
| Region | `asia-northeast1` (Tokyo) | 1, 2 |

## 1. Create the ClickHouse Cloud service

In the ClickHouse Cloud console, open "New service" under Services and choose:

- Service name: the service name
- Cloud provider: GCP
- Region: the region where the topic stores messages (for example Tokyo (asia-northeast1))
- Memory and scaling: "Mini" is enough for a trial. As the page says, a single replica is not recommended for production; choose "Standard" or larger there.

![Create service](../images/console/01_create_service.png)

Press "Create service"; it starts in a few minutes.
To use an existing service (26.6 or later), skip this step.

## 2. Create the Pub/Sub topic

In Pub/Sub in the Google Cloud console, open "Create topic" under Topics and enter the Topic ID.

- **Uncheck "Add a default subscription".** It is checked by default. ClickPipes creates its own subscription, so the default one is never read, keeps accumulating messages, and is billed.
- Leave "Enable message retention" off (the replay data stays in L0 in ClickHouse).

![Create topic](../images/console/02_topic_create.png)

After creating it, open "Edit" on the topic and, under "Storage policy" in the info panel on the right, restrict message storage to the region of the ClickHouse Cloud service:

1. Uncheck "Allow in any region".
2. "Add region" and enter `asia-northeast1`.
3. Leave "Enforce in transit" off.
4. Press "Update" in the panel.

![Topic storage policy](../images/console/02b_topic_storage_policy.png)

## 3. Create the sink

Open "Create sink" under Log router in Logging.

1. Sink details: name and description.
2. Sink destination: choose "Cloud Pub/Sub topic" and the topic from step 2.
3. Choose logs to include in sink: filter `logName:"projects/<project>/logs/"` (every log of the project).
4. Choose logs to filter out of sink: exclusions for high-volume noise you never search in ClickHouse (optional).
5. Press "Create sink".

![Sink destination](../images/console/03_sink_destination.png)

![Sink filter](../images/console/03b_sink_filter.png)

From the moment it is created, the sink sends every log of the project to the topic.
With a topic in the same project, the console granted publish permission on the topic (Pub/Sub Publisher) to the sink's writer identity automatically.
Check that the topic's "Permissions" list `service-<project-number>@gcp-sa-logging.iam.gserviceaccount.com` as Pub/Sub Publisher.
For a topic in another project, grant it yourself.

## 4. Create the custom role for ClickPipes

Open "Create role" under Roles in IAM & Admin and enter the Title, Description and ID.
"Add permissions" and add these seven (the official least-privilege role, [Pub/Sub IAM permissions](https://clickhouse.com/docs/integrations/clickpipes/pubsub/auth)):

- `pubsub.topics.list`
- `pubsub.topics.get`
- `pubsub.topics.attachSubscription`
- `pubsub.subscriptions.create`
- `pubsub.subscriptions.get`
- `pubsub.subscriptions.delete`
- `pubsub.subscriptions.consume`

The filter in the permission picker accumulates conditions (they must all match).
After selecting one permission, remove the filter before typing the next name.
Leaving "Role launch stage" at the default Alpha does not change the permissions.

![Custom role](../images/console/04_role_create.png)

The role allows listing topics and creating, consuming and deleting subscriptions anywhere in the project.
If that is too broad, put the topic in a project dedicated to log export.

## 5. Create the service account and its key

Open "Create service account" under Service accounts in IAM & Admin, enter a name and ID, and press "Create and continue".

![Create service account](../images/console/04b_sa_create.png)

Under Permissions, choose the custom role from step 4 and press "Done".
If other roles share the name, tell them apart by description or ID (`projects/<project>/roles/<role id>`).

![Grant the role](../images/console/04c_sa_role.png)

On the new service account, "Keys" → "Add key" → "Create new key" → "JSON" → "Create" downloads the key file.

- The key file is the credential for reading the topic. Treat it like a password; keep it out of shared drives and Git.
- Once it is uploaded to the ClickPipe, you can delete the local file. To rotate, create a new key on the same page.
- If an organization policy (`iam.disableServiceAccountKeyCreation`) blocks key creation, use a key created through your approved process.

## 6. Create the tables and MVs

Open the service's "SQL console" in the ClickHouse Cloud console and paste `sql/10_landing_v1.sql`, `sql/20_logs_v1.sql`, `sql/30_logs_v1_mv.sql`, `sql/40_rollup_1m_v1.sql` and `sql/50_noise_rollup_v1.sql`, in that order, into a new query.
Replace these strings before pasting:

| String | Value (Terraform default) |
|---|---|
| `{{LANDING_TTL_DAYS}}` | `7` |
| `{{LOGS_TTL_DAYS}}` | `400` |
| `{{MV_DEFINER}}` | `default` |

"Run" executes all statements together.
The editor adds indentation as you paste; it is whitespace only and does not change the SQL.
It is done when the database `gcl` appears on the left with four tables and three MVs.

![SQL console](../images/console/05b_sql_console_result.png)

Create these before the pipe.
The pipe writes into the existing L0 (`gcl.gcl_landing_v1`), and the MVs build L1 and the rest.

## 7. Create the ClickPipe

Under the service's "Data sources", open "Create ClickPipe" and choose "GCP Pub/Sub".
The page labels it Beta (the documentation says Private Preview, [ClickPipes connectors](https://clickhouse.com/docs/integrations/clickpipes)).

**Setup your ClickPipe connection**: enter the ClickPipe name and the GCP Project ID, and upload the key file from step 5.

![Connection](../images/console/06b_clickpipe_connection.png)

**Incoming data**:

- Pub/Sub topic: the topic from step 2
- Data format: JSONEachRow (fixed)
- Starting offset: Latest

"Fetch sample data" reads messages from the topic.
The next step needs a sample, so if the topic has no messages yet, wait a few minutes for logs from the sink.

![Incoming data](../images/console/06d_clickpipe_sample.png)

**Parse information**: under "Upload data to", choose "Existing table", then Database `gcl` and Table `gcl_landing_v1`.
The page maps the Pub/Sub virtual columns (`_raw_message`, `_message_id`, `_publish_time`, `_attributes`) to the L0 columns of the same names automatically.
Leave the JSON fields (`insertId` and so on) unmapped.
The MVs do the parsing, so L0 gets only the virtual columns.

![Column mapping](../images/console/06f_clickpipe_mapping.png)

**Details and settings**: under Permissions, choose "Only destination" and press "Create ClickPipe".

![Permissions](../images/console/06g_clickpipe_details.png)

The page warns "No access to Materialized Views"; that does not apply here.
The MVs have `SQL SECURITY DEFINER` and write to L1 and the aggregate tables with the definer's (`default`) rights.
In testing, the pipe user had grants on L0 and its error table only, and L1 and the aggregate tables filled with no loss ([Findings](findings.md), "Setup in the browser").

The state becomes Running in a few minutes.
The pipe creates its managed subscription (`clickpipes-<pipe id>`; 7-day retention, 60 s ack deadline, ordering on).

## 8. Create the ClickStack source

Open ClickStack from the service menu and press "Add source" under Sources in Team Settings.
Enter a Name and choose Source Data Type Log, Database `gcl` and Table `gcl_logs_v1`.
Set Default Select and the fields under "Configure Optional Fields" as follows (the same values as `terraform/clickstack.tf`):

| Field | Value |
|---|---|
| Timestamp Column | `Timestamp` |
| Default Select | `Timestamp, ServiceName, SeverityText, ResourceType, Body` |
| Service Name Expression | `ServiceName` |
| Log Level Expression | `SeverityText` |
| Body Expression | `Body` |
| Log Attributes Expression | `LogAttributes` |
| Resource Attributes Expression | `ResourceAttributes` |
| Displayed Timestamp Column | `Timestamp` |
| Trace Id Expression | `TraceId` |
| Span Id Expression | `SpanId` |
| Implicit Column Expression | `Body` |
| Use Text Index | Auto (default) |

"Add Setting" adds per-source query settings, which this configuration does not use.
If it left empty rows, delete them with the trash button before saving.

![ClickStack source](../images/console/07b_clickstack_optional.png)

After "Save New Source", choose the source in Search and check that a Japanese word such as `タイムアウト` ("timeout") finds logs.

![Search in ClickStack](../images/console/07d_clickstack_search.png)

## 9. Check that it works

Run this in the SQL console to see rows in L0 and L1:

```sql
SELECT
    (SELECT count() FROM gcl.gcl_landing_v1) AS l0,
    (SELECT count() FROM gcl.gcl_logs_v1) AS l1,
    (SELECT sum(Cnt) FROM gcl.gcl_noise_1m_v1) AS noise;
```

The L0 row count roughly equals L1 plus the noise counts (minus a few seconds still on their way to L1).
For the periodic checks, paste the queries of `verify/checks.sql` into the SQL console ("Daily checks" in [Operations](operations.md)).

## Removal

Remove in reverse order:

1. Delete the ClickPipe under Data sources in the ClickHouse Cloud console.
2. Wait in Pub/Sub Subscriptions until the managed subscription (`clickpipes-<pipe id>`) is gone. ClickPipes deletes it after the pipe, with the service account from step 5. Deleting step 5 or 4 before that leaves the subscription behind, attached to the deleted topic (`_deleted-topic_`) (with Terraform, it was gone 23 seconds after the pipe was deleted).
3. Run `DROP DATABASE IF EXISTS gcl SYNC` in the SQL console.
4. Delete the sink in Log router.
5. Delete the topic in Pub/Sub.
6. Remove the service account's role binding in IAM and delete the service account in Service accounts (its keys stop working).
7. Delete the custom role in Roles. It can be restored within 7 days, and its ID cannot be reused until it is permanently deleted.
8. Delete the source from step 8 under Sources in ClickStack Team Settings.
9. If you do not keep the service from step 1, delete it.
