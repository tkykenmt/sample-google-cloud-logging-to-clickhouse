output "topic" {
  value = google_pubsub_topic.logs.id
}

output "sink_writer_identity" {
  description = "Identity the sink publishes as (granted roles/pubsub.publisher on the topic)."
  value       = google_logging_project_sink.to_pubsub.writer_identity
}

output "clickpipes_service_account" {
  value = google_service_account.clickpipes.email
}

output "clickpipe_id" {
  value = clickhouse_clickpipe.gcl.id
}

output "clickpipe_state" {
  value = clickhouse_clickpipe.gcl.state
}

output "clickstack_source_id" {
  value = local.clickstack ? clickhouse_clickstack_source.logs[0].id : null
}
