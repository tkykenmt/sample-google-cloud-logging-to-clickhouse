# Setup

English | [日本語](../ja/setup.md)

Terraform creates the Google Cloud resources, the ClickHouse tables and MVs, the ClickPipe, and the ClickStack source and dashboard.
With Terraform, run only the "Steps" section of this page.
Without Terraform, build the same configuration in the consoles with [Setup in the browser](setup-console.md) (run one or the other, not both).
To build the same pieces one at a time with gcloud and clickhousectl and see what each does, follow part 3 of the [Hands-on](hands-on.md).
The reasoning is in [Design](design.md).

## Before you start

- **Try it in a test project first.** From the moment `terraform apply` runs, the sink sends every log of the project to the topic.
- **Pub/Sub is billed.** In the test environment, the volume sent to Pub/Sub was about 5 times the Cloud Logging billable volume ([Findings](findings.md), "Bytes that drive Pub/Sub cost"). Most of the difference was audit logs routed to `_Required`, which Cloud Logging does not bill (for billable logs alone it was about 1.2 times). High-volume noise can be excluded at the sink with `sink_exclusions`.
- **The service account key is stored in the Terraform state.** Keep the state in an encrypted remote backend with restricted access (`terraform/terraform.tf` has an example).
- **The ClickPipes permissions cover the whole project.** The official least-privilege role ([Pub/Sub IAM permissions](https://clickhouse.com/docs/integrations/clickpipes/pubsub/auth)) allows creating, consuming and deleting subscriptions anywhere in the project. If that is too broad, put the topic in a project dedicated to log export.
- **Storage in the existing `_Default` bucket does not change.** Stopping it is not part of the setup; see "Switching production logs" in [Operations](operations.md).

## What gets created

| Where | Resource | Role | Defined in |
|---|---|---|---|
| Google Cloud | Pub/Sub topic | Sink destination. No message retention | `terraform/gcp.tf` |
| Google Cloud | Log Router sink | Sends every log of the project (default) to the topic | `terraform/gcp.tf` |
| Google Cloud | Topic IAM | Grants publish to the sink's writer identity | `terraform/gcp.tf` |
| Google Cloud | Custom role, service account, key | Lets ClickPipes read the topic and create its managed subscription | `terraform/gcp.tf` |
| ClickHouse Cloud | Tables and MVs in database `gcl` | L0, L1, MV1, L3 (per-minute counts), noise counts | `sql/10` to `sql/50` |
| ClickHouse Cloud | ClickPipe | Ingests the topic into L0 | `terraform/clickhouse.tf` |
| ClickStack | Log source and dashboard | Search and visualize L1 (optional) | `terraform/clickstack.tf` |

Terraform creates the tables and MVs by running the files in `sql/` through `tools/chq.py`.
The ClickHouse Terraform provider has no resource for DDL.
Every statement is `CREATE ... IF NOT EXISTS`, so re-running leaves existing tables unchanged.
For the same reason, changing a TTL or similar value after creation does not reach existing tables (see "Changing settings after creation").

## Prerequisites

- A ClickHouse Cloud service (26.6 or later). Restrict the topic's message storage to the same region with `topic_storage_regions` (step 2).
- A ClickHouse Cloud API key with write access, and the organization ID.
- Permissions in the Google Cloud project to create topics, sinks, service accounts, custom roles, and IAM bindings.
- The Pub/Sub, Cloud Logging and IAM APIs enabled in the project (step 1).
- Terraform 1.9 or later, `gcloud`, `python3`, and `clickhousectl` on your machine.
- The first `tools/chq.py` run makes `clickhousectl` create a Query API endpoint and key on the service (it prints `Provisioning Query API endpoint + key`).
- If an organization policy (`iam.disableServiceAccountKeyCreation`) blocks service account key creation, a key file created through your approved process (`service_account_key_file`).

## Steps

### 1. Authenticate

```bash
# Credentials for the Terraform google provider (Application Default Credentials)
gcloud auth application-default login

# Enable the APIs in use (no-op if already enabled)
gcloud services enable pubsub.googleapis.com logging.googleapis.com iam.googleapis.com --project <project>

# The Terraform ClickHouse provider reads all three; clickhousectl (called by tools/chq.py) reads the API key pair
export CLICKHOUSE_ORG_ID=<organization id>
export CLICKHOUSE_CLOUD_API_KEY=<key id>
export CLICKHOUSE_CLOUD_API_SECRET=<key secret>
clickhousectl cloud service get <service id>   # seeing the service means the key works
```

If the current directory has `.clickhouse/credentials.json` (saved by `clickhousectl cloud auth login`), `clickhousectl` uses it before the environment variables.
Run `tools/chq.py` from the top of the repository and keep credentials for other organizations out of it.

### 2. Set the variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars`, replace `gcp_project_id` and `clickhouse_service_id`, and uncomment `topic_storage_regions` with the service's region.
Everything else works with the defaults.
The main variables are below.
All variables and defaults are in `terraform/variables.tf`, and invalid values are rejected at `terraform plan`.

| Variable | Default | How to choose |
|---|---|---|
| `gcp_project_id` | ― | ID of the project whose logs you export |
| `clickhouse_service_id` | ― | ID of the destination service |
| `sink_filter` | Every log of the project | Leave as is; narrow by log kind on the ClickHouse side |
| `sink_exclusions` | None | To drop high-volume noise you never search in ClickHouse at the sink |
| `topic_storage_regions` | Unrestricted | Set it to the region of the ClickHouse Cloud service (e.g. `["asia-northeast1"]`); crossing regions adds delivery egress charges |
| `topic_kms_key_name` | None (Google-managed key) | To encrypt the topic with a customer-managed key (CMEK) |
| `landing_ttl_days` | 7 | Ingest delay + switch and backfill + verification and rollback, plus a margin |
| `logs_ttl_days` | 400 | Log retention requirement |
| `pipe_seek_type` | `latest` | Start position of a new managed subscription. Leave as is: the topic keeps no messages |
| `pipe_replicas` etc. | 1 replica, smallest size | Increase after measuring volume and delay |
| `clickstack_connection_id` | None | To create the ClickStack source and dashboard (step 4) |

### 3. Check the plan, then apply

```bash
terraform init
terraform plan
```

Check the resources to be created and the sink `filter` in the plan output.
Without ClickStack, 10 resources are created (including `terraform_data.subscription_cleanup`, which waits during destroy; 9 with `service_account_key_file`).

```bash
terraform apply
```

Apply runs in this order:

1. Create the topic, sink, IAM, and service account.
2. Run `sql/10` to `sql/50` to create the tables and MVs (skipped with `apply_schema = false`).
3. Create the ClickPipe with the existing L0 as its destination.

### 4. Create the ClickStack source (optional)

Find the ID of the connection to this service under Team Settings > Connections in ClickStack.
Add `clickstack_connection_id` to `terraform.tfvars` and apply again; this creates the L1 log source and the example dashboard "Cloud Logging overview".

```bash
terraform apply
```

### 5. Check that it works

```bash
terraform output clickpipe_state   # Running

# Latency, stuck batches, duplicates, late arrivals, parser health, etc. (tools/chq.py reads CH_SERVICE_ID)
cd ..
export CH_SERVICE_ID=<service id>
python3 tools/chq.py verify/checks.sql
```

If logs from the sink are arriving in L0 and L1, ingestion is working.
This completes the setup.
The periodic checks are in "Daily checks" in [Operations](operations.md).

## Changing settings after creation

| What | How |
|---|---|
| Sink filter and exclusions, pipe size, ClickStack source | Change `terraform.tfvars` and run `terraform apply` |
| TTL of L0, L1 and the aggregate tables | `ALTER TABLE ... MODIFY TTL` ("Changing retention" in [Operations](operations.md)). Keep `terraform.tfvars` in line for a rebuild |
| L1 columns or parsing | The procedures in [Operations](operations.md) (`MODIFY QUERY` on the MV) |

## Removing the resources

```bash
cd terraform
terraform destroy
cd ..
export CH_SERVICE_ID=<service id>
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
```

- `terraform destroy` removes only what Terraform created.
- Delete the pipe before the database. In the other order, the pipe's inserts keep failing until it is deleted.
- When the ClickPipe is deleted, ClickPipes deletes its managed subscription asynchronously. `terraform destroy` waits for that (`tools/wait_subscriptions_gone.py`, up to 5 minutes) before removing the key and the role binding. Without the wait, the managed subscription was left behind, attached to the deleted topic (`_deleted-topic_`). If it is still there after 5 minutes, destroy warns and continues; run the printed `gcloud pubsub subscriptions delete` command to remove it.
- The database `gcl` created by `sql/` is not managed by Terraform; remove it with `DROP DATABASE`.
- A deleted custom role stays soft-deleted and can be restored within 7 days. Its ID cannot be reused until it is permanently deleted ([Deleting a custom role](https://cloud.google.com/iam/docs/creating-custom-roles#deleting-custom-role)). To try again right away, change `clickpipes_role_id`.
