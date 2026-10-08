locals {
  sink_filter = coalesce(var.sink_filter, "logName:\"projects/${var.gcp_project_id}/logs/\"")

  # Workload identity: ClickPipes reads with its own Google service account (no key). Otherwise a service
  # account of this project and its JSON key.
  workload_identity = var.clickpipes_auth == "workload_identity"
  sa_key_b64 = local.workload_identity ? null : (
    var.service_account_key_file != null ? filebase64(var.service_account_key_file) : google_service_account_key.clickpipes[0].private_key
  )
  clickpipes_principal = local.workload_identity ? data.clickhouse_clickpipes_service_context.service[0].gcp_workload_identity.principal : google_service_account.clickpipes[0].email
}

# Workload identity (Private Preview): the Google service account ClickPipes manages for this ClickHouse
# Cloud service. The data source waits until the identity is ready and fails if it is not supported.
# https://clickhouse.com/docs/integrations/clickpipes/security/gcp-workload-identity
data "clickhouse_clickpipes_service_context" "service" {
  count = local.workload_identity ? 1 : 0

  service_id    = var.clickhouse_service_id
  ready_timeout = "5m"
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
# The identity can therefore create, consume and delete subscriptions anywhere in the project: use a
# project dedicated to log export if that is too broad, and treat a key as a secret.
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
  count = local.workload_identity ? 0 : 1

  account_id   = var.clickpipes_service_account_id
  display_name = "ClickPipes reader for ${var.topic_name}"

  # Removed only after the pipe has switched away from this key (see the workload identity binding below).
  lifecycle {
    create_before_destroy = true
  }
}

resource "google_project_iam_member" "clickpipes" {
  count = local.workload_identity ? 0 : 1

  project = var.gcp_project_id
  role    = google_project_iam_custom_role.clickpipes.id
  member  = "serviceAccount:${google_service_account.clickpipes[0].email}"

  # Removed only after the pipe has switched away from this key (see the workload identity binding below).
  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_account_key" "clickpipes" {
  count = !local.workload_identity && var.service_account_key_file == null ? 1 : 0

  service_account_id = google_service_account.clickpipes[0].name

  # Removed only after the pipe has switched away from this key (see the workload identity binding below).
  lifecycle {
    create_before_destroy = true
  }
}

# A separate resource from the key binding, so that switching an existing deployment to workload identity
# grants the new identity first, then updates the pipe, then removes the old binding, account and key.
resource "google_project_iam_member" "clickpipes_workload_identity" {
  count = local.workload_identity ? 1 : 0

  project = var.gcp_project_id
  role    = google_project_iam_custom_role.clickpipes.id
  member  = "serviceAccount:${local.clickpipes_principal}"
}

# State addresses from before clickpipes_auth existed.
moved {
  from = google_service_account.clickpipes
  to   = google_service_account.clickpipes[0]
}

moved {
  from = google_project_iam_member.clickpipes
  to   = google_project_iam_member.clickpipes[0]
}

# Deleting the ClickPipe returns at once, and ClickPipes deletes its managed subscription afterwards
# with this service account. On destroy, wait for that before the key, the role binding and the topic
# go; otherwise the subscription is left behind, attached to the deleted topic (seen in testing).
# The pipe depends on this resource, so it is destroyed first.
resource "terraform_data" "subscription_cleanup" {
  # Replaced (so the destroy-time wait runs for the old topic) when the project or topic changes.
  triggers_replace = [var.gcp_project_id, var.topic_name]

  input = {
    project = var.gcp_project_id
    topic   = google_pubsub_topic.logs.name
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    working_dir = "${path.module}/.."
    command     = "python3 tools/wait_subscriptions_gone.py --project ${self.input.project} --topic ${self.input.topic}"
  }

  depends_on = [
    google_project_iam_member.clickpipes,
    google_project_iam_member.clickpipes_workload_identity,
    google_project_iam_custom_role.clickpipes,
    google_service_account_key.clickpipes,
    google_pubsub_topic_iam_member.sink_publisher,
  ]
}
