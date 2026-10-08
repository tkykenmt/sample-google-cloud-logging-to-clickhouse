terraform {
  # 1.9: validation rules that refer to other variables. 1.7: mock providers in tests/.
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 9.0"
    }
    clickhouse = {
      source  = "ClickHouse/clickhouse"
      version = ">= 3.37, < 4.0"
    }
  }

  # The state holds the ClickPipes service account key (google_service_account_key.private_key and the
  # pipe's service_account_file). Use an encrypted remote backend with restricted access, for example:
  # backend "gcs" {
  #   bucket = "<state bucket>"
  #   prefix = "gcl-to-clickhouse"
  # }
}
