provider "google" {
  project = var.gcp_project_id

  default_labels = {
    managed-by = "terraform"
    app        = "gcl-to-clickhouse"
  }
}

# Credentials come from CLICKHOUSE_ORG_ID, CLICKHOUSE_CLOUD_API_KEY and CLICKHOUSE_CLOUD_API_SECRET.
# clickstack_service_id routes the clickhouse_clickstack_* resources to the managed ClickStack of this service.
provider "clickhouse" {
  clickstack_service_id = var.clickhouse_service_id
}
