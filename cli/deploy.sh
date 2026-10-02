#!/bin/bash
# Build the pipeline with gcloud and clickhousectl, without Terraform. Same resources and defaults as terraform/.
# Safe to re-run: every step skips what already exists.
#
# Usage: cli/deploy.sh            (reads cli/.env if present, then the environment)
#        DRY_RUN=1 cli/deploy.sh  (prints the commands that would change something)
# Needs: gcloud (authenticated), clickhousectl with an API key (CLICKHOUSE_CLOUD_API_KEY/SECRET or
#        `clickhousectl cloud auth login --api-key ...`), python3.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f cli/.env ] && set -a && . cli/.env && set +a

: "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}" "${CH_SERVICE_ID:?set CH_SERVICE_ID}"
P=$GCP_PROJECT_ID

# A failed probe must mean "absent", not "not signed in": check both CLIs first.
gcloud auth print-access-token >/dev/null 2>&1 || { echo "gcloud is not authenticated: run gcloud auth login" >&2; exit 4; }
clickhousectl cloud service get "$CH_SERVICE_ID" >/dev/null 2>&1 || { echo "clickhousectl cannot read service $CH_SERVICE_ID: check the API key" >&2; exit 4; }
TOPIC=${TOPIC:-gcl-to-clickhouse}
SINK=${SINK:-gcl-to-clickhouse}
SINK_FILTER=${SINK_FILTER:-logName:\"projects/$P/logs/\"}
SA_ID=${SA_ID:-clickpipes-gcl}
SA_EMAIL="$SA_ID@$P.iam.gserviceaccount.com"
ROLE_ID=${ROLE_ID:-clickpipesPubsubIngestion}
KEY_FILE=${KEY_FILE:-clickpipes-key.json}
PIPE_NAME=${PIPE_NAME:-gcl-v1}
SEEK_TYPE=${SEEK_TYPE:-latest}
LANDING_TTL_DAYS=${LANDING_TTL_DAYS:-7}
LOGS_TTL_DAYS=${LOGS_TTL_DAYS:-400}
MV_DEFINER=${MV_DEFINER:-default}
TOPIC_STORAGE_REGIONS=${TOPIC_STORAGE_REGIONS:-}
PERMISSIONS=pubsub.subscriptions.consume,pubsub.subscriptions.create,pubsub.subscriptions.delete,pubsub.subscriptions.get,pubsub.topics.attachSubscription,pubsub.topics.get,pubsub.topics.list

step() { printf '\n== %s\n' "$*"; }
run() {  # run a command that changes something (printed only with DRY_RUN=1)
  printf '+ %s\n' "$*"
  [ -n "${DRY_RUN:-}" ] || "$@"
}
exists() { "$@" >/dev/null 2>&1; }  # read-only probe

step "Pub/Sub topic $TOPIC (no message retention; L0 is the replay buffer)"
if exists gcloud pubsub topics describe "$TOPIC" --project "$P"; then
  echo "exists"
else
  args=()
  [ -n "$TOPIC_STORAGE_REGIONS" ] && args+=(--message-storage-policy-allowed-regions="$TOPIC_STORAGE_REGIONS")
  run gcloud pubsub topics create "$TOPIC" --project "$P" ${args[@]+"${args[@]}"}
fi

step "Log Router sink $SINK"
if exists gcloud logging sinks describe "$SINK" --project "$P"; then
  echo "exists (filter and destination are left as they are)"
else
  run gcloud logging sinks create "$SINK" "pubsub.googleapis.com/projects/$P/topics/$TOPIC" \
    --project "$P" --log-filter="$SINK_FILTER" --description="Route logs to Pub/Sub for ClickHouse Cloud (ClickPipes)"
fi

step "Publisher role on the topic for the sink's writer identity"
WRITER=$(gcloud logging sinks describe "$SINK" --project "$P" --format='value(writerIdentity)' 2>/dev/null || true)
if [ -z "$WRITER" ]; then
  echo "writer identity not known yet (dry run); would grant roles/pubsub.publisher to it"
else
  run gcloud pubsub topics add-iam-policy-binding "$TOPIC" --project "$P" \
    --member="$WRITER" --role=roles/pubsub.publisher --quiet --format=none
fi

step "Custom role $ROLE_ID (ClickPipes creates and deletes its own managed subscription)"
DELETED=$(gcloud iam roles describe "$ROLE_ID" --project "$P" --format='value(deleted)' 2>/dev/null || echo missing)
case "$DELETED" in
  missing) run gcloud iam roles create "$ROLE_ID" --project "$P" --title="ClickPipes Pub/Sub ingestion" \
             --description="Consume a topic through a ClickPipes-managed subscription" --permissions="$PERMISSIONS" ;;
  True)    run gcloud iam roles undelete "$ROLE_ID" --project "$P"   # a deleted role ID cannot be reused for weeks
           run gcloud iam roles update "$ROLE_ID" --project "$P" --permissions="$PERMISSIONS" ;;
  *)       echo "exists" ;;
esac

step "Service account $SA_EMAIL"
if exists gcloud iam service-accounts describe "$SA_EMAIL" --project "$P"; then
  echo "exists"
else
  run gcloud iam service-accounts create "$SA_ID" --project "$P" --display-name="ClickPipes reader for $TOPIC"
fi
run gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$SA_EMAIL" \
  --role="projects/$P/roles/$ROLE_ID" --condition=None --quiet --format=none

step "Service account key $KEY_FILE"
if [ -f "$KEY_FILE" ]; then
  echo "using the existing file"
else
  # Blocked when the organization policy iam.disableServiceAccountKeyCreation applies: create the key
  # through your approved process and pass it as KEY_FILE.
  run gcloud iam service-accounts keys create "$KEY_FILE" --iam-account="$SA_EMAIL" --project "$P"
fi

step "ClickHouse tables and MVs (sql/10..50; CREATE ... IF NOT EXISTS)"
run python3 tools/chq.py --service "$CH_SERVICE_ID" \
  --var LANDING_TTL_DAYS="$LANDING_TTL_DAYS" --var LOGS_TTL_DAYS="$LOGS_TTL_DAYS" --var MV_DEFINER="$MV_DEFINER" \
  sql/10_landing_v1.sql sql/20_logs_v1.sql sql/30_logs_v1_mv.sql sql/40_rollup_1m_v1.sql sql/50_noise_rollup_v1.sql

step "ClickPipe $PIPE_NAME (writes only the Pub/Sub virtual columns into the existing L0)"
pipe_id() {
  clickhousectl cloud clickpipe list "$CH_SERVICE_ID" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit("could not list ClickPipes: check the clickhousectl API key")
d = d if isinstance(d, list) else d.get("result", d)
print(next((p["id"] for p in d if p.get("name") == sys.argv[1]), ""))' "$PIPE_NAME"
}
ID=$(pipe_id)
if [ -n "$ID" ]; then
  echo "exists ($ID)"
else
  run clickhousectl cloud clickpipe create pubsub "$CH_SERVICE_ID" \
    --name "$PIPE_NAME" --topic "$TOPIC" --project-id "$P" --format JSONEachRow \
    --service-account-file "$KEY_FILE" --seek-type "$SEEK_TYPE" \
    --database gcl --table gcl_landing_v1 \
    --column "_raw_message:String" --column "_message_id:String" \
    --column "_publish_time:DateTime64(3)" --column "_attributes:Map(String, String)"
  ID=$(pipe_id)
fi

if [ -n "${DRY_RUN:-}" ] || [ -z "$ID" ]; then
  exit 0
fi
step "Waiting for the pipe to be Running"
for _ in $(seq 1 30); do
  STATE=$(clickhousectl cloud clickpipe get "$CH_SERVICE_ID" "$ID" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))')
  echo "state: $STATE"
  [ "$STATE" = "Running" ] && break
  sleep 10
done
cat <<MSG

Done. Next:
  - ClickStack source: docs/en/setup.md, "ClickStack source" (or terraform/clickstack.tf)
  - Checks: CH_SERVICE_ID=$CH_SERVICE_ID python3 tools/chq.py verify/checks.sql
  - The key file $KEY_FILE grants access to the topic; store it like a password.
MSG
