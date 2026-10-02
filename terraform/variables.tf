# --- Google Cloud ---------------------------------------------------------------------------------

variable "gcp_project_id" {
  description = "Project whose logs are exported, and where the topic and the ClickPipes service account live."
  type        = string
}

variable "topic_name" {
  description = "Pub/Sub topic that the Log Router sink publishes to."
  type        = string
  default     = "gcl-to-clickhouse"
}

variable "topic_storage_regions" {
  description = "Regions allowed to store messages (messageStoragePolicy). Empty = no restriction. Match the ClickHouse Cloud region to avoid cross-region delivery charges."
  type        = list(string)
  default     = []
}

variable "sink_name" {
  description = "Log Router sink name."
  type        = string
  default     = "gcl-to-clickhouse"
}

variable "sink_filter" {
  description = "Log Router filter. null = every log of the project (logName:\"projects/<project>/logs/\")."
  type        = string
  default     = null
}

variable "sink_exclusions" {
  description = "Exclusion filters on the Pub/Sub sink, for high-volume noise you never search in ClickHouse (it also cuts Pub/Sub cost)."
  type = list(object({
    name   = string
    filter = string
  }))
  default = []
}

variable "clickpipes_service_account_id" {
  description = "Account ID of the service account ClickPipes uses to read the topic."
  type        = string
  default     = "clickpipes-gcl"
}

variable "clickpipes_role_id" {
  description = "ID of the project-level custom role for ClickPipes."
  type        = string
  default     = "clickpipesPubsubIngestion"
}

variable "service_account_key_file" {
  description = "Path to an existing JSON key for the ClickPipes service account. null = create a key with Terraform (the key then lives in the state; keep the state private). Use a file when an organization policy blocks key creation."
  type        = string
  default     = null
}

# --- ClickHouse Cloud -----------------------------------------------------------------------------

variable "clickhouse_service_id" {
  description = "ID of an existing ClickHouse Cloud service (26.6 or later) in the same region as the topic's messages."
  type        = string
}

variable "apply_schema" {
  description = "Create the database, tables and materialized views (sql/10..50) with tools/chq.py during apply. Needs python3 and clickhousectl. Set false to run the SQL yourself before applying the pipe."
  type        = bool
  default     = true
}

variable "landing_ttl_days" {
  description = "L0 retention. Size it from: ingest delay + switch/backfill time + verification/rollback time."
  type        = number
  default     = 7
}

variable "logs_ttl_days" {
  description = "L1 and rollup retention."
  type        = number
  default     = 400
}

variable "mv_definer" {
  description = "User the materialized views run as (SQL SECURITY DEFINER). The pipe user then needs only INSERT on L0."
  type        = string
  default     = "default"
}

variable "pipe_name" {
  description = "ClickPipe name."
  type        = string
  default     = "gcl-v1"
}

variable "pipe_seek_type" {
  description = "Where the new managed subscription starts: latest, earliest or timestamp."
  type        = string
  default     = "latest"
}

variable "pipe_replicas" {
  description = "ClickPipe replicas. Start with 1 and increase while measuring the delay."
  type        = number
  default     = 1
}

variable "pipe_replica_cpu_millicores" {
  description = "CPU per ClickPipe replica (125-2000)."
  type        = number
  default     = 125
}

variable "pipe_replica_memory_gb" {
  description = "Memory per ClickPipe replica (0.5-8)."
  type        = number
  default     = 0.5
}

# --- ClickStack -----------------------------------------------------------------------------------

variable "clickstack_connection_id" {
  description = "ID of the ClickStack connection to this service (Team Settings > Connections). null = do not create the ClickStack source and dashboard."
  type        = string
  default     = null
}

variable "clickstack_source_name" {
  description = "Display name of the ClickStack log source."
  type        = string
  default     = "Cloud Logging"
}

variable "create_dashboard" {
  description = "Create the example dashboard (clickstack/dashboard.json) on the log source."
  type        = bool
  default     = true
}
