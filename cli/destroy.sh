#!/bin/bash
# Remove what cli/deploy.sh created. The ClickHouse database is dropped only with DROP_DATABASE=1.
# Usage: cli/destroy.sh   |   DRY_RUN=1 cli/destroy.sh   |   DROP_DATABASE=1 cli/destroy.sh
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
SA_ID=${SA_ID:-clickpipes-gcl}
SA_EMAIL="$SA_ID@$P.iam.gserviceaccount.com"
ROLE_ID=${ROLE_ID:-clickpipesPubsubIngestion}
KEY_FILE=${KEY_FILE:-clickpipes-key.json}
PIPE_NAME=${PIPE_NAME:-gcl-v1}

step() { printf '\n== %s\n' "$*"; }
run() { printf '+ %s\n' "$*"; [ -n "${DRY_RUN:-}" ] || "$@" || true; }

step "ClickPipe $PIPE_NAME (its managed subscription is deleted with it)"
ID=$(clickhousectl cloud clickpipe list "$CH_SERVICE_ID" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit("could not list ClickPipes: check the clickhousectl API key")
d = d if isinstance(d, list) else d.get("result", d)
print(next((p["id"] for p in d if p.get("name") == sys.argv[1]), ""))' "$PIPE_NAME")
[ -n "$ID" ] && run clickhousectl cloud clickpipe delete "$CH_SERVICE_ID" "$ID" || echo "not found"

step "Sink, topic, service account, custom role"
run gcloud logging sinks delete "$SINK" --project "$P" --quiet
run gcloud pubsub topics delete "$TOPIC" --project "$P" --quiet
run gcloud projects remove-iam-policy-binding "$P" --member="serviceAccount:$SA_EMAIL" \
  --role="projects/$P/roles/$ROLE_ID" --condition=None --quiet --format=none
run gcloud iam service-accounts delete "$SA_EMAIL" --project "$P" --quiet
# A deleted custom role stays soft-deleted and its ID cannot be reused for weeks; deploy.sh undeletes it.
run gcloud iam roles delete "$ROLE_ID" --project "$P" --quiet
[ -f "$KEY_FILE" ] && run rm -f "$KEY_FILE"

if [ -n "${DROP_DATABASE:-}" ]; then
  step "ClickHouse database gcl"
  run python3 tools/chq.py --service "$CH_SERVICE_ID" -q "DROP DATABASE IF EXISTS gcl SYNC"
else
  echo; echo "The database gcl was kept (DROP_DATABASE=1 drops it)."
fi
