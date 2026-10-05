output "clickpipe_id" {
  description = "ID of the ClickPipe (for clickhousectl cloud clickpipe get/stop/start)."
  value       = clickhouse_clickpipe.gcl.id
}

output "clickpipe_state" {
  description = "State of the ClickPipe right after apply (Running when ingestion has started)."
  value       = clickhouse_clickpipe.gcl.state
}

output "clickpipes_service_account" {
  description = "Service account whose key ClickPipes uses to read the topic."
  value       = google_service_account.clickpipes.email
}

output "clickstack_source_id" {
  description = "ID of the ClickStack log source on L1, or null when clickstack_connection_id is not set."
  value       = one(clickhouse_clickstack_source.logs[*].id)
}

output "sink_writer_identity" {
  description = "Identity the sink publishes as (granted roles/pubsub.publisher on the topic)."
  value       = google_logging_project_sink.to_pubsub.writer_identity
}

output "topic" {
  description = "Full resource name of the Pub/Sub topic the sink publishes to."
  value       = google_pubsub_topic.logs.id
}
