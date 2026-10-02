# Setup

English | [日本語](../ja/setup.md)

Terraform creates the Google Cloud resources, the ClickHouse tables and MVs, the ClickPipe, and the ClickStack source and dashboard.
Where Terraform is not available, `cli/deploy.sh` builds the same configuration with gcloud and clickhousectl ("With clickhousectl and gcloud").
The reasoning is in [Design](design.md); a guided trial is in the [Hands-on](hands-on.md).

## What gets created

| Where | Resource | Role | Defined in |
|---|---|---|---|
| Google Cloud | Pub/Sub topic | Sink destination. No message retention | `terraform/gcp.tf` |
| Google Cloud | Log Router sink | Sends every log of the project to the topic | `terraform/gcp.tf` |
| Google Cloud | Topic IAM | Grants publish to the sink's writer identity | `terraform/gcp.tf` |
| Google Cloud | Custom role, service account, key | Lets ClickPipes read the topic and create its managed subscription | `terraform/gcp.tf` |
| ClickHouse Cloud | Tables and MVs in database `gcl` | L0, L1, MV1, L3 (per-minute counts), noise counts | `sql/10` to `sql/50` |
| ClickHouse Cloud | ClickPipe | Ingests the topic into L0 | `terraform/clickhouse.tf` |
| ClickStack | Log source and dashboard | Search and visualize L1 (optional) | `terraform/clickstack.tf` |

Terraform creates the tables and MVs by running the files in `sql/` through `tools/chq.py`.
The ClickHouse Terraform provider has no resource for DDL.
Every statement is `CREATE ... IF NOT EXISTS`, so re-running leaves existing tables unchanged.

## Prerequisites

- A ClickHouse Cloud service (26.6 or later) in the same region where the topic stores messages.
- A ClickHouse Cloud API key with write access, and the organization ID.
- Permissions in the Google Cloud project to create topics, sinks, service accounts, custom roles, and IAM bindings.
- Terraform 1.5 or later, `gcloud`, `python3`, and `clickhousectl` on your machine.
- If an organization policy (`iam.disableServiceAccountKeyCreation`) blocks service account key creation, prepare a key file through your approved process (`service_account_key_file`).

## Steps

### 1. Authenticate

```bash
gcloud auth application-default login

# The ClickHouse Terraform provider and clickhousectl read the same variables
export CLICKHOUSE_ORG_ID=<organization id>
export CLICKHOUSE_CLOUD_API_KEY=<key id>
export CLICKHOUSE_CLOUD_API_SECRET=<key secret>
```

### 2. Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

The main variables are below.
All variables and defaults are in `terraform/variables.tf`.

| Variable | Default | How to decide |
|---|---|---|
| `gcp_project_id` | ― | The project whose logs you send |
| `clickhouse_service_id` | ― | The destination service |
| `sink_filter` | All logs of the project | Usually unchanged; narrow by log kind in ClickHouse |
| `sink_exclusions` | None | To drop high-volume noise you never search in ClickHouse at the sink |
| `topic_storage_regions` | Not restricted | To pin storage to the ClickHouse Cloud region |
| `landing_ttl_days` | 7 | Ingest delay + switch and backfill + reconciliation and rollback, plus margin |
| `logs_ttl_days` | 400 | Your log retention requirement |
| `pipe_replicas` and others | 1 replica, smallest size | Increase while measuring volume and latency |
| `clickstack_connection_id` | None | To create the ClickStack source and dashboard (step 4) |

### 3. Apply

```bash
terraform init
terraform plan
terraform apply
```

Apply runs in this order:

1. Create the topic, sink, IAM, and service account.
2. Run `sql/10` to `sql/50` to create the tables and MVs (skipped with `apply_schema = false`).
3. Create the ClickPipe with the existing L0 as the destination.

When Terraform creates the service account key, the key is stored in the Terraform state.
Protect the state as you would the key.

### 4. ClickStack source (optional)

Find the ID of the connection to this service under Team Settings > Connections in ClickStack.
Set `clickstack_connection_id` in `terraform.tfvars` and apply again to create the L1 log source and the example dashboard.

```bash
terraform apply -var clickstack_connection_id=<connection id>
```

### 5. Verify

```bash
terraform output clickpipe_state   # Running

# Latency, stuck batches, duplicates, late arrivals, parser health (tools/chq.py reads CH_SERVICE_ID)
export CH_SERVICE_ID=<service id>
python3 tools/chq.py verify/checks.sql
```

If logs from the sink appear in L0 and L1, ingestion works.
The items to watch regularly are under "Daily checks" in [Operations](operations.md).

## Moving production logs over

Add the Pub/Sub sink, run both paths in parallel, then stop storing logs in `_Default`.

1. Parallel run: add the Pub/Sub sink and keep storing in `_Default`.
2. Reconcile: compare the sink's export count with ingested rows in ClickHouse, and confirm that everyday searches work in ClickStack.
3. Inventory: list the features that depend on logs stored in `_Default`, and decide whether to move each to ClickStack or keep those logs in `_Default` ("What changes when you stop storing logs in the _Default bucket" in [Design](design.md)).
4. Switch: add an exclusion filter to the `_Default` sink, or disable it, so new logs no longer enter `_Default`. Removing the filter reverts the switch.

This repository's Terraform does not manage the `_Default` sink.
Make the switch through your own change process.

## With clickhousectl and gcloud (without Terraform)

Where Terraform is not available, `cli/deploy.sh` builds the same configuration with `gcloud` and `clickhousectl`.
Resource names and defaults are the same as in Terraform.
Every step skips what already exists, so after a failure you can fix the cause and run the same command again.

```bash
cp cli/env.example cli/.env      # set GCP_PROJECT_ID and CH_SERVICE_ID
gcloud auth login
export CLICKHOUSE_CLOUD_API_KEY=<key id> CLICKHOUSE_CLOUD_API_SECRET=<key secret>

DRY_RUN=1 cli/deploy.sh          # only prints the commands that would change something
cli/deploy.sh
```

The script runs these steps and then waits for the pipe to be Running:

1. Pub/Sub topic (no message retention)
2. Log Router sink, and publish permission on the topic for its writer identity
3. Custom role, service account, and key file for ClickPipes (no new key if `KEY_FILE` exists)
4. Tables and MVs from `sql/10` to `sql/50` (`tools/chq.py`)
5. ClickPipe (into the existing L0)

- The key file is the permission to read the topic. Store it like a password.
- If an organization policy blocks key creation, pass a key created through your approved process as `KEY_FILE`.
- Set up the ClickStack source in the UI with the fields under "ClickStack source" below (a single screen).
- `cli/destroy.sh` removes everything. The ClickHouse database is dropped only with `DROP_DATABASE=1`. A deleted custom role ID cannot be reused for weeks, so `cli/deploy.sh` undeletes a deleted role and reuses it.

The commands the script runs are in the next section.

## Individual commands and settings

Values match the Terraform defaults.

### Sink, topic, permissions

```bash
P=<project>; T=gcl-to-clickhouse; S=gcl-to-clickhouse

gcloud pubsub topics create $T --project $P
gcloud logging sinks create $S pubsub.googleapis.com/projects/$P/topics/$T \
  --project $P --log-filter="logName:\"projects/$P/logs/\""
W=$(gcloud logging sinks describe $S --project $P --format='value(writerIdentity)')
gcloud pubsub topics add-iam-policy-binding $T --project $P --member="$W" --role=roles/pubsub.publisher

gcloud iam roles create clickpipesPubsubIngestion --project $P --title="ClickPipes Pub/Sub ingestion" \
  --permissions=pubsub.subscriptions.consume,pubsub.subscriptions.create,pubsub.subscriptions.delete,pubsub.subscriptions.get,pubsub.topics.attachSubscription,pubsub.topics.get,pubsub.topics.list
gcloud iam service-accounts create clickpipes-gcl --project $P
gcloud projects add-iam-policy-binding $P \
  --member="serviceAccount:clickpipes-gcl@$P.iam.gserviceaccount.com" --role="projects/$P/roles/clickpipesPubsubIngestion"
gcloud iam service-accounts keys create clickpipes-key.json --iam-account="clickpipes-gcl@$P.iam.gserviceaccount.com"
```

The sink as a Cloud Logging API resource:

```json
{
  "name": "gcl-to-clickhouse",
  "destination": "pubsub.googleapis.com/projects/<project>/topics/gcl-to-clickhouse",
  "filter": "logName:\"projects/<project>/logs/\"",
  "writerIdentity": "serviceAccount:service-<project-number>@gcp-sa-logging.iam.gserviceaccount.com"
}
```

For multiple projects, create it under `organizations/<org>/sinks` or `folders/<folder>/sinks` with `"includeChildren": true`. (docs)

### Tables and MVs

```bash
export CH_SERVICE_ID=<service id>
python3 tools/chq.py --var LANDING_TTL_DAYS=7 --var LOGS_TTL_DAYS=400 --var MV_DEFINER=default \
  sql/10_landing_v1.sql sql/20_logs_v1.sql sql/30_logs_v1_mv.sql sql/40_rollup_1m_v1.sql sql/50_noise_rollup_v1.sql
```

`tools/chq.py` uses the Query API, so statements longer than 30 seconds time out on the client (the server keeps running them).
Run large backfills over a native `clickhouse client` connection.

### ClickPipe

```bash
clickhousectl cloud clickpipe create pubsub "$CH_SERVICE_ID" \
  --name gcl-v1 --topic gcl-to-clickhouse --project-id <project> --format JSONEachRow \
  --service-account-file clickpipes-key.json --seek-type latest \
  --database gcl --table gcl_landing_v1 \
  --column "_raw_message:String" --column "_message_id:String" \
  --column "_publish_time:DateTime64(3)" --column "_attributes:Map(String, String)"
```

The pipe creates its managed subscription `clickpipes-<pipe id>` with 7-day retention, a 60 s ack deadline, and ordering enabled.
Do not create it yourself.

### ClickStack source

Set these fields under Team Settings > Sources:

```json
{
  "kind": "log",
  "name": "Cloud Logging",
  "databaseName": "gcl",
  "tableName": "gcl_logs_v1",
  "timestampValueExpression": "Timestamp",
  "defaultTableSelectExpression": "Timestamp, ServiceName, SeverityText, ResourceType, Body",
  "serviceNameExpression": "ServiceName",
  "severityTextExpression": "SeverityText",
  "bodyExpression": "Body",
  "eventAttributesExpression": "LogAttributes",
  "resourceAttributesExpression": "ResourceAttributes",
  "traceIdExpression": "TraceId",
  "spanIdExpression": "SpanId",
  "implicitColumnExpression": "Body"
}
```

## Cleanup

```bash
terraform destroy
```

- Deleting the ClickPipe also deletes its managed subscription.
- The `gcl` database created from `sql/` is outside Terraform and remains. Drop it with `DROP DATABASE gcl` if you no longer need it.
- A pipe that is only stopped keeps its managed subscription, which keeps accumulating messages. Delete pipes you no longer use.
