terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    clickhouse = {
      source  = "ClickHouse/clickhouse"
      version = ">= 3.34"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
}

# Credentials come from CLICKHOUSE_ORG_ID, CLICKHOUSE_CLOUD_API_KEY and CLICKHOUSE_CLOUD_API_SECRET.
# clickstack_service_id routes the clickhouse_clickstack_* resources to the managed ClickStack of this service.
provider "clickhouse" {
  clickstack_service_id = var.clickhouse_service_id
}
