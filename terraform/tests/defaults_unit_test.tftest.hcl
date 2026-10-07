# Plan-only tests with mock providers: no credentials, no cloud resources, and no local-exec
# (provisioners do not run at plan). Run from terraform/: terraform init -backend=false && terraform test

mock_provider "google" {}
mock_provider "clickhouse" {
  mock_data "clickhouse_clickpipes_service_context" {
    defaults = {
      gcp_workload_identity = {
        supported = true
        ready     = true
        principal = "ch-test@clickpipes-production.iam.gserviceaccount.com"
      }
    }
  }
}

variables {
  gcp_project_id        = "my-project"
  clickhouse_service_id = "00000000-0000-0000-0000-000000000000"
}

run "defaults" {
  command = plan

  assert {
    condition     = google_logging_project_sink.to_pubsub.filter == "logName:\"projects/my-project/logs/\""
    error_message = "By default the sink must export every log of the project."
  }

  assert {
    condition     = length(google_service_account_key.clickpipes) == 1
    error_message = "Without service_account_key_file, Terraform creates exactly one key."
  }

  assert {
    condition     = length(terraform_data.schema) == 1
    error_message = "The schema step runs by default."
  }

  assert {
    condition     = length(clickhouse_clickstack_source.logs) == 0 && length(clickhouse_clickstack_dashboard.overview) == 0
    error_message = "No ClickStack objects without clickstack_connection_id."
  }

  assert {
    condition     = clickhouse_clickpipe.gcl.destination.database == "gcl" && clickhouse_clickpipe.gcl.destination.table == "gcl_landing_v1"
    error_message = "The pipe must write to the L0 table created by sql/10."
  }

  assert {
    condition     = clickhouse_clickpipe.gcl.source.pubsub.seek_type == "latest" && clickhouse_clickpipe.gcl.source.pubsub.seek_timestamp == null
    error_message = "The pipe starts at latest by default."
  }
}

run "toggles" {
  command = plan

  variables {
    apply_schema             = false
    clickstack_connection_id = "c"
    create_dashboard         = false
    service_account_key_file = "tests/fixtures/key.json"
    sink_filter              = "resource.type=\"k8s_container\""
  }

  assert {
    condition     = length(terraform_data.schema) == 0
    error_message = "apply_schema = false skips the schema step."
  }

  assert {
    condition     = length(clickhouse_clickstack_source.logs) == 1 && length(clickhouse_clickstack_dashboard.overview) == 0
    error_message = "A connection ID creates the source; create_dashboard = false skips the dashboard."
  }

  assert {
    condition     = length(google_service_account_key.clickpipes) == 0
    error_message = "An existing key file means no key is created."
  }

  assert {
    condition     = google_logging_project_sink.to_pubsub.filter == "resource.type=\"k8s_container\""
    error_message = "sink_filter replaces the default filter."
  }
}

run "seek_timestamp" {
  command = plan

  variables {
    pipe_seek_type      = "timestamp"
    pipe_seek_timestamp = "2026-10-05T00:00:00Z"
  }

  assert {
    condition     = clickhouse_clickpipe.gcl.source.pubsub.seek_timestamp == "2026-10-05T00:00:00Z"
    error_message = "seek_timestamp is passed to the pipe."
  }
}

run "rejects_unknown_seek_type" {
  command = plan

  variables {
    pipe_seek_type = "oldest"
  }

  expect_failures = [var.pipe_seek_type]
}

run "rejects_timestamp_without_time" {
  command = plan

  variables {
    pipe_seek_type = "timestamp"
  }

  expect_failures = [var.pipe_seek_timestamp]
}

run "rejects_unsafe_definer" {
  command = plan

  variables {
    mv_definer = "x; rm -rf ~"
  }

  expect_failures = [var.mv_definer]
}

run "rejects_out_of_range_sizing" {
  command = plan

  variables {
    pipe_replica_cpu_millicores = 4000
    pipe_replica_memory_gb      = 0.1
  }

  expect_failures = [var.pipe_replica_cpu_millicores, var.pipe_replica_memory_gb]
}

run "rejects_project_number" {
  command = plan

  variables {
    gcp_project_id = "123456789012"
  }

  expect_failures = [var.gcp_project_id]
}

run "rejects_domain_scoped_project" {
  command = plan

  variables {
    gcp_project_id = "example.com:my-project"
  }

  expect_failures = [var.gcp_project_id]
}

run "rejects_non_rfc3339_seek_timestamp" {
  command = plan

  variables {
    pipe_seek_type      = "timestamp"
    pipe_seek_timestamp = "2026-10-05 00:00:00"
  }

  expect_failures = [var.pipe_seek_timestamp]
}

run "workload_identity" {
  command = plan

  variables {
    clickpipes_auth = "workload_identity"
  }

  assert {
    condition     = length(google_service_account.clickpipes) == 0 && length(google_service_account_key.clickpipes) == 0 && length(google_project_iam_member.clickpipes) == 0
    error_message = "Workload identity creates no service account, key or key binding."
  }

  assert {
    condition     = google_project_iam_member.clickpipes_workload_identity[0].member == "serviceAccount:ch-test@clickpipes-production.iam.gserviceaccount.com"
    error_message = "The custom role is granted to the ClickPipes-managed principal."
  }

  assert {
    condition     = clickhouse_clickpipe.gcl.source.pubsub.authentication == "SERVICE_ACCOUNT_WORKLOAD_IDENTITY" && clickhouse_clickpipe.gcl.source.pubsub.service_account_key == null
    error_message = "The pipe uses workload identity and no key."
  }

  assert {
    condition     = output.clickpipes_service_account == "ch-test@clickpipes-production.iam.gserviceaccount.com"
    error_message = "The output shows the principal to authorize."
  }
}

run "rejects_key_file_with_workload_identity" {
  command = plan

  variables {
    clickpipes_auth          = "workload_identity"
    service_account_key_file = "tests/fixtures/key.json"
  }

  expect_failures = [var.service_account_key_file]
}
