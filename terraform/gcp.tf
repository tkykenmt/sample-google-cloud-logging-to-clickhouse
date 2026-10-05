locals {
  sink_filter = coalesce(var.sink_filter, "logName:\"projects/${var.gcp_project_id}/logs/\"")
  sa_key_b64  = var.service_account_key_file != null ? filebase64(var.service_account_key_file) : google_service_account_key.clickpipes[0].private_key
}

# No message retention on the topic: L0 in ClickHouse is the replay buffer.
resource "google_pubsub_topic" "logs" {
  name         = var.topic_name
  kms_key_name = var.topic_kms_key_name

  dynamic "message_storage_policy" {
    for_each = length(var.topic_storage_regions) > 0 ? [1] : []
    content {
      allowed_persistence_regions = var.topic_storage_regions
    }
  }
}

# Sinks evaluate logs independently: adding this sink does not stop the _Default bucket from storing them.
resource "google_logging_project_sink" "to_pubsub" {
  name                   = var.sink_name
  destination            = "pubsub.googleapis.com/${google_pubsub_topic.logs.id}"
  filter                 = local.sink_filter
  unique_writer_identity = true
  description            = "Route logs to Pub/Sub for ClickHouse Cloud (ClickPipes)"

  dynamic "exclusions" {
    for_each = var.sink_exclusions
    content {
      name   = exclusions.value.name
      filter = exclusions.value.filter
    }
  }
}

resource "google_pubsub_topic_iam_member" "sink_publisher" {
  topic  = google_pubsub_topic.logs.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.to_pubsub.writer_identity
}

# The permissions of the official least-privilege role, granted at the project level as documented:
# https://clickhouse.com/docs/integrations/clickpipes/pubsub/auth
# ClickPipes lists topics and creates short-lived discovery subscriptions (clickpipes-discovery-<uuid>) as
# well as its managed subscription (clickpipes-<pipe id>), so it needs more than subscriber rights.
# The key can therefore create, consume and delete subscriptions anywhere in the project: use a project
# dedicated to log export if that is too broad, and treat the key as a secret.
resource "google_project_iam_custom_role" "clickpipes" {
  role_id     = var.clickpipes_role_id
  title       = "ClickPipes Pub/Sub ingestion"
  description = "Consume a topic through a ClickPipes-managed subscription"
  permissions = [
    "pubsub.subscriptions.consume",
    "pubsub.subscriptions.create",
    "pubsub.subscriptions.delete",
    "pubsub.subscriptions.get",
    "pubsub.topics.attachSubscription",
    "pubsub.topics.get",
    "pubsub.topics.list",
  ]
}

resource "google_service_account" "clickpipes" {
  account_id   = var.clickpipes_service_account_id
  display_name = "ClickPipes reader for ${var.topic_name}"
}

resource "google_project_iam_member" "clickpipes" {
  project = var.gcp_project_id
  role    = google_project_iam_custom_role.clickpipes.id
  member  = "serviceAccount:${google_service_account.clickpipes.email}"
}

resource "google_service_account_key" "clickpipes" {
  count              = var.service_account_key_file == null ? 1 : 0
  service_account_id = google_service_account.clickpipes.name
}
