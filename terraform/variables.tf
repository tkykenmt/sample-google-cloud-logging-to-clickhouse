# Variables are grouped by where the resource lives, and sorted alphabetically within each group.

# --- Google Cloud ---------------------------------------------------------------------------------

variable "clickpipes_role_id" {
  description = "ID of the project-level custom role for ClickPipes."
  type        = string
  default     = "clickpipesPubsubIngestion"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,64}$", var.clickpipes_role_id))
    error_message = "clickpipes_role_id must be 3-64 letters, digits, underscores or periods."
  }
}

variable "clickpipes_service_account_id" {
  description = "Account ID of the service account ClickPipes uses to read the topic."
  type        = string
  default     = "clickpipes-gcl"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.clickpipes_service_account_id))
    error_message = "clickpipes_service_account_id must be 6-30 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "gcp_project_id" {
  description = "Project whose logs are exported, and where the topic and the ClickPipes service account live."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project_id))
    error_message = "gcp_project_id must be a project ID (6-30 lowercase letters, digits or hyphens), not a project name or number."
  }
}

variable "service_account_key_file" {
  description = "Path to an existing JSON key for the ClickPipes service account. null = create a key with Terraform (the key then lives in the state; keep the state in an encrypted backend). Use a file when an organization policy blocks key creation."
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

variable "sink_filter" {
  description = "Log Router filter. null = every log of the project (logName:\"projects/<project>/logs/\")."
  type        = string
  default     = null
}

variable "sink_name" {
  description = "Log Router sink name."
  type        = string
  default     = "gcl-to-clickhouse"
}

variable "topic_kms_key_name" {
  description = "Cloud KMS key for the topic (CMEK), as projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>. null = Google-managed encryption. The Pub/Sub service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter on the key."
  type        = string
  default     = null
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

# --- ClickHouse Cloud -----------------------------------------------------------------------------

variable "apply_schema" {
  description = "Create the database, tables and materialized views (sql/10..50) with tools/chq.py during apply. Needs python3 and clickhousectl. Set false to run the SQL yourself before applying the pipe."
  type        = bool
  default     = true
}

variable "clickhouse_service_id" {
  description = "ID of an existing ClickHouse Cloud service (26.6 or later) in the same region as the topic's messages."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.clickhouse_service_id))
    error_message = "clickhouse_service_id must be the service UUID."
  }
}

variable "landing_ttl_days" {
  description = "L0 retention. Size it from: ingest delay + switch/backfill time + verification/rollback time. Used only when the tables are created; change it later with ALTER TABLE ... MODIFY TTL (docs/en/operations.md)."
  type        = number
  default     = 7

  validation {
    condition     = var.landing_ttl_days >= 1 && floor(var.landing_ttl_days) == var.landing_ttl_days
    error_message = "landing_ttl_days must be a whole number of days, 1 or more."
  }
}

variable "logs_ttl_days" {
  description = "L1 and rollup retention. Used only when the tables are created; change it later with ALTER TABLE ... MODIFY TTL."
  type        = number
  default     = 400

  validation {
    condition     = var.logs_ttl_days >= 1 && floor(var.logs_ttl_days) == var.logs_ttl_days
    error_message = "logs_ttl_days must be a whole number of days, 1 or more."
  }
}

variable "mv_definer" {
  description = "User the materialized views run as (SQL SECURITY DEFINER). The pipe user then needs only INSERT on L0. Used only when the views are created."
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.mv_definer))
    error_message = "mv_definer must be a plain user name (letters, digits, underscores). Quote-requiring names are not supported by sql/30 and sql/50."
  }
}

variable "pipe_name" {
  description = "ClickPipe name."
  type        = string
  default     = "gcl-v1"
}

variable "pipe_replica_cpu_millicores" {
  description = "CPU per ClickPipe replica (125-2000)."
  type        = number
  default     = 125

  validation {
    condition     = var.pipe_replica_cpu_millicores >= 125 && var.pipe_replica_cpu_millicores <= 2000
    error_message = "pipe_replica_cpu_millicores must be between 125 and 2000."
  }
}

variable "pipe_replica_memory_gb" {
  description = "Memory per ClickPipe replica (0.5-8)."
  type        = number
  default     = 0.5

  validation {
    condition     = var.pipe_replica_memory_gb >= 0.5 && var.pipe_replica_memory_gb <= 8
    error_message = "pipe_replica_memory_gb must be between 0.5 and 8."
  }
}

variable "pipe_replicas" {
  description = "ClickPipe replicas. Start with 1 and increase while measuring the delay."
  type        = number
  default     = 1

  validation {
    condition     = var.pipe_replicas >= 1 && floor(var.pipe_replicas) == var.pipe_replicas
    error_message = "pipe_replicas must be a whole number, 1 or more."
  }
}

variable "pipe_seek_timestamp" {
  description = "Start position when pipe_seek_type = \"timestamp\", in RFC 3339 (e.g. 2026-10-05T00:00:00Z). The topic must retain messages from that time."
  type        = string
  default     = null

  validation {
    condition     = (var.pipe_seek_type == "timestamp") == (var.pipe_seek_timestamp != null)
    error_message = "Set pipe_seek_timestamp exactly when pipe_seek_type is \"timestamp\"."
  }
}

variable "pipe_seek_type" {
  description = "Where the new managed subscription starts: latest, earliest or timestamp (with pipe_seek_timestamp). earliest and timestamp reach back only as far as the topic retains messages; this configuration sets no topic retention."
  type        = string
  default     = "latest"

  validation {
    condition     = contains(["latest", "earliest", "timestamp"], var.pipe_seek_type)
    error_message = "pipe_seek_type must be latest, earliest or timestamp."
  }
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
  description = "Create the example dashboard (clickstack/dashboard.json.tftpl) on the log source."
  type        = bool
  default     = true
}
