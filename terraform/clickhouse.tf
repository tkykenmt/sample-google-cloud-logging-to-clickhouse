# Tables and materialized views (L0, L1, MV1, L3 rollup, noise counts) from sql/.
# The ClickHouse provider has no resource for DDL, so tools/chq.py runs the files through the Cloud Query API.
# Every statement is CREATE ... IF NOT EXISTS, so re-running is safe, and it also means a changed TTL or
# definer does not reach existing tables: change those with ALTER TABLE (docs/en/operations.md).
# The variables passed on the command line are restricted by their validation rules (variables.tf).
resource "terraform_data" "schema" {
  count = var.apply_schema ? 1 : 0

  triggers_replace = {
    service = var.clickhouse_service_id
    sql     = sha256(join("", [for f in local.schema_files : file("${path.module}/../${f}")]))
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/.."
    command     = "python3 tools/chq.py --service ${var.clickhouse_service_id} --var LANDING_TTL_DAYS=${var.landing_ttl_days} --var LOGS_TTL_DAYS=${var.logs_ttl_days} --var MV_DEFINER=${var.mv_definer} ${join(" ", local.schema_files)}"
  }
}

locals {
  # Names fixed by sql/10..50. Change them there first if you rename anything.
  database      = "gcl"
  landing_table = "gcl_landing_v1"
  logs_table    = "gcl_logs_v1"

  schema_files = [
    "sql/10_landing_v1.sql",
    "sql/20_logs_v1.sql",
    "sql/30_logs_v1_mv.sql",
    "sql/40_rollup_1m_v1.sql",
    "sql/50_noise_rollup_v1.sql",
  ]
}

# The pipe writes only the Pub/Sub virtual columns into the existing L0; MV1 does the parsing.
resource "clickhouse_clickpipe" "gcl" {
  name       = var.pipe_name
  service_id = var.clickhouse_service_id

  source = {
    pubsub = {
      project_id     = var.gcp_project_id
      topic          = google_pubsub_topic.logs.name
      format         = "JSONEachRow"
      seek_type      = var.pipe_seek_type
      seek_timestamp = var.pipe_seek_timestamp
      authentication = "SERVICE_ACCOUNT"
      service_account_key = {
        service_account_file = local.sa_key_b64
      }
    }
  }

  destination = {
    database      = local.database
    table         = local.landing_table
    managed_table = false
    columns = [
      { name = "_raw_message", type = "String" },
      { name = "_message_id", type = "String" },
      { name = "_publish_time", type = "DateTime64(3)" },
      { name = "_attributes", type = "Map(String, String)" },
    ]
  }

  scaling = {
    replicas               = var.pipe_replicas
    replica_cpu_millicores = var.pipe_replica_cpu_millicores
    replica_memory_gb      = var.pipe_replica_memory_gb
  }

  depends_on = [
    terraform_data.schema,
    terraform_data.subscription_cleanup,
    google_project_iam_member.clickpipes,
    google_pubsub_topic_iam_member.sink_publisher,
  ]
}
