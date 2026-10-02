locals {
  clickstack = var.clickstack_connection_id != null
}

# Log source on L1. Column mapping follows the ClickStack OTel log schema used by gcl_logs_v1.
resource "clickhouse_clickstack_source" "logs" {
  count         = local.clickstack ? 1 : 0
  name          = var.clickstack_source_name
  kind          = "log"
  connection_id = var.clickstack_connection_id

  from = {
    database_name = "gcl"
    table_name    = "gcl_logs_v1"
  }

  timestamp_value_expression           = "Timestamp"
  displayed_timestamp_value_expression = "Timestamp"
  default_table_select_expression      = "Timestamp, ServiceName, SeverityText, ResourceType, Body"
  service_name_expression              = "ServiceName"
  severity_text_expression             = "SeverityText"
  body_expression                      = "Body"
  event_attributes_expression          = "LogAttributes"
  resource_attributes_expression       = "ResourceAttributes"
  trace_id_expression                  = "TraceId"
  span_id_expression                   = "SpanId"
  implicit_column_expression           = "Body"
  use_text_index_for_implicit_column   = "auto"

  highlighted_row_attribute_expressions = [
    { sql_expression = "ResourceType", alias = "type" },
    { sql_expression = "LogId", alias = "log" },
    { sql_expression = "ProjectId", alias = "project" },
  ]

  depends_on = [terraform_data.schema]
}

resource "clickhouse_clickstack_dashboard" "overview" {
  count = local.clickstack && var.create_dashboard ? 1 : 0
  dashboard_json = templatefile("${path.module}/clickstack/dashboard.json.tftpl", {
    source_id = clickhouse_clickstack_source.logs[0].id
  })
}
