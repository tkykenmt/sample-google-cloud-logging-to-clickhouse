#!/usr/bin/env python3
"""Synthetic Google Cloud Logging LogEntry generator.

Produces LogEntry JSON documents shaped like what a Log Router Pub/Sub sink
publishes (message data = LogEntry JSON, attribute
logging.googleapis.com/timestamp). Stdlib only.

Modes:
  --out FILE           write JSON lines
  --publish TOPIC      publish to projects/<p>/topics/<t> via the Pub/Sub REST API
                       (token from `gcloud auth application-default print-access-token`)

Edge cases are mixed in at configurable rates so that parsing materialized
views can be tested against them: missing/late/future timestamps, unicode,
large payloads, nested and non-string jsonPayload values, duplicates, and
(optionally) non-JSON poison messages.
"""
import argparse
import base64
import datetime as dt
import json
import random
import string
import subprocess
import sys
import time
import urllib.request
import uuid

PROJECTS = ["example-prod", "example-stg"]
NAMESPACES = ["checkout", "catalog", "search", "kube-system"]
CONTAINERS = ["api", "worker", "envoy", "fluentbit"]
RUN_SERVICES = ["web-frontend", "order-api", "image-resizer"]
SEVERITIES = ["DEFAULT", "DEBUG", "INFO", "INFO", "INFO", "NOTICE", "WARNING", "ERROR", "CRITICAL", None]
METHODS = ["GET", "GET", "GET", "POST", "PUT", "DELETE"]
PATHS = ["/api/v1/items", "/api/v1/cart", "/healthz", "/search?q=%E6%A3%9A", "/static/app.js"]
JA_TEXT = ["在庫照会がタイムアウトしました", "決済処理を開始", "キャッシュを更新しました", "接続を再試行します"]


def rfc3339(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond:06d}" + f"{random.randint(0, 999):03d}Z"


def rid(n=16):
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=n))


def trace_fields(project):
    if random.random() < 0.5:
        return {}
    return {
        "trace": f"projects/{project}/traces/{uuid.uuid4().hex}",
        "spanId": uuid.uuid4().hex[:16],
        "traceSampled": random.random() < 0.3,
    }


def k8s_container(project, now):
    ns, ct = random.choice(NAMESPACES), random.choice(CONTAINERS)
    payload = {
        "message": random.choice(["request handled", "cache miss", "upstream timeout"] + JA_TEXT),
        "latency_ms": round(random.uniform(1, 900), 2),
        "user": {"id": random.randint(1, 10_000), "tier": random.choice(["free", "pro"])},
        "retry": random.random() < 0.1,
        "tags": ["a", "b"],
        "note": None,
    }
    e = {
        "resource": {"type": "k8s_container", "labels": {
            "project_id": project, "location": "asia-northeast1", "cluster_name": "gke-main",
            "namespace_name": ns, "pod_name": f"{ct}-{rid(5)}", "container_name": ct}},
        "logName": f"projects/{project}/logs/stdout",
        "jsonPayload": payload,
        "labels": {"k8s-pod/app": ct, "compute.googleapis.com/resource_name": f"node-{rid(4)}"},
    }
    return e


def cloud_run(project, now):
    svc = random.choice(RUN_SERVICES)
    e = {
        "resource": {"type": "cloud_run_revision", "labels": {
            "project_id": project, "service_name": svc, "revision_name": f"{svc}-0001-{rid(3)}",
            "location": "asia-northeast1", "configuration_name": svc}},
        "logName": f"projects/{project}/logs/run.googleapis.com%2Frequests",
        "httpRequest": {
            "requestMethod": random.choice(METHODS),
            "requestUrl": "https://example.com" + random.choice(PATHS),
            "status": random.choice([200, 200, 200, 201, 304, 404, 500, 503]),
            "responseSize": str(random.randint(100, 90_000)),
            "userAgent": "Mozilla/5.0 (synthetic)",
            "remoteIp": f"203.0.113.{random.randint(1, 254)}",
            "latency": f"{random.uniform(0.001, 3.5):.6f}s",
            "protocol": "HTTP/1.1",
        },
    }
    e.update(trace_fields(project))
    return e


def gce_text(project, now):
    return {
        "resource": {"type": "gce_instance", "labels": {
            "project_id": project, "instance_id": str(random.randint(10**18, 10**19 - 1)), "zone": "asia-northeast1-b"}},
        "logName": f"projects/{project}/logs/syslog",
        "textPayload": random.choice(["systemd[1]: Started Daily apt download.", "kernel: eth0 link up"] + JA_TEXT),
        "sourceLocation": {"file": "main.go", "line": str(random.randint(1, 900)), "function": "main.run"},
    }


def cloud_function(project, now):
    return {
        "resource": {"type": "cloud_function", "labels": {
            "project_id": project, "function_name": random.choice(["thumb", "notify"]), "region": "asia-northeast1"}},
        "logName": f"projects/{project}/logs/cloudfunctions.googleapis.com%2Fcloud-functions",
        "textPayload": f"Function execution took {random.randint(1, 3000)} ms, finished with status: 'ok'",
        "labels": {"execution_id": rid(12)},
    }


def audit(project, now):
    return {
        "resource": {"type": "gcs_bucket", "labels": {"project_id": project, "bucket_name": f"bkt-{rid(6)}", "location": "asia-northeast1"}},
        "logName": f"projects/{project}/logs/cloudaudit.googleapis.com%2Factivity",
        "protoPayload": {
            "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
            "serviceName": "storage.googleapis.com",
            "methodName": random.choice(["storage.buckets.create", "storage.setIamPermissions", "storage.buckets.delete"]),
            "authenticationInfo": {"principalEmail": "deployer@example-prod.iam.gserviceaccount.com"},
            "requestMetadata": {"callerIp": "203.0.113.7"},
            "status": {},
        },
        "operation": random.choice([{}, {"id": rid(10), "producer": "storage.googleapis.com", "first": True}]),
    }


def lease_update(project, now):
    """Kubernetes Lease renewal audit entry: the high-volume noise the example rule in sql/30 and sql/50 drops."""
    holder = random.choice(["kube-scheduler", "kube-controller-manager", "gke-node-" + rid(4)])
    return {
        "resource": {"type": "k8s_cluster", "labels": {"project_id": project, "cluster_name": "demo-cluster", "location": "asia-northeast1"}},
        "logName": f"projects/{project}/logs/cloudaudit.googleapis.com%2Factivity",
        "protoPayload": {
            "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
            "serviceName": "k8s.io",
            "methodName": "io.k8s.coordination.v1.leases.update",
            "resourceName": f"coordination.k8s.io/v1/namespaces/kube-system/leases/{holder}",
            "authenticationInfo": {"principalEmail": f"system:{holder}"},
            "requestMetadata": {"callerIp": "10.0.0.2"},
            "status": {},
        },
    }


KINDS = [(k8s_container, 0.45), (cloud_run, 0.25), (gce_text, 0.12), (cloud_function, 0.08), (audit, 0.10)]


def make_entry(args, now):
    if random.random() < args.lease_rate:
        f = lease_update
    else:
        f = random.choices([k for k, _ in KINDS], weights=[w for _, w in KINDS])[0]
    project = random.choice(PROJECTS)
    e = f(project, now)
    sev = random.choice(SEVERITIES)
    if sev:
        e["severity"] = sev
    ts = now
    r = random.random()
    if r < args.late_rate:
        ts = now - dt.timedelta(seconds=random.uniform(60, args.late_max_sec))
    elif r < args.late_rate + args.future_rate:
        ts = now + dt.timedelta(seconds=random.uniform(1, 3600))
    e["timestamp"] = rfc3339(ts)
    if random.random() < args.missing_ts_rate:
        e.pop("timestamp")
    e["receiveTimestamp"] = rfc3339(now)
    e["insertId"] = args.insert_id_prefix + rid(14)
    if random.random() < args.large_rate and "jsonPayload" in e:
        e["jsonPayload"]["blob"] = "x" * args.large_bytes
    return e


def to_message(entry, args):
    if random.random() < args.poison_rate:
        data = b"not-json {" + rid(8).encode()
    else:
        data = json.dumps(entry, ensure_ascii=False, separators=(",", ":")).encode()
    attrs = {"logging.googleapis.com/timestamp": entry.get("timestamp", entry["receiveTimestamp"])}
    return {"data": base64.b64encode(data).decode(), "attributes": attrs}


class Publisher:
    def __init__(self, topic):
        self.url = f"https://pubsub.googleapis.com/v1/{topic}:publish"
        self.token, self.token_at = None, 0

    def _tok(self):
        if not self.token or time.time() - self.token_at > 1800:
            self.token = subprocess.check_output(
                ["gcloud", "auth", "application-default", "print-access-token"], text=True).strip()
            self.token_at = time.time()
        return self.token

    def publish(self, msgs):
        body = json.dumps({"messages": msgs}).encode()
        req = urllib.request.Request(self.url, data=body, method="POST", headers={
            "Authorization": "Bearer " + self._tok(), "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r).get("messageIds", [])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out")
    p.add_argument("--publish", help="projects/<project>/topics/<topic>")
    p.add_argument("--count", type=int, default=1000, help="entries for --out, or per-run cap for --publish")
    p.add_argument("--rate", type=float, default=50, help="messages/sec for --publish")
    p.add_argument("--duration", type=float, default=60, help="seconds for --publish")
    p.add_argument("--batch", type=int, default=200)
    p.add_argument("--max-messages", type=int, default=10**12)
    p.add_argument("--late-rate", type=float, default=0.02)
    p.add_argument("--late-max-sec", type=float, default=6 * 3600)
    p.add_argument("--future-rate", type=float, default=0.002)
    p.add_argument("--missing-ts-rate", type=float, default=0.002)
    p.add_argument("--large-rate", type=float, default=0.001)
    p.add_argument("--large-bytes", type=int, default=200_000)
    p.add_argument("--dup-rate", type=float, default=0.005, help="republish the same entry")
    p.add_argument("--lease-rate", type=float, default=0.0, help="share of Kubernetes Lease renewal entries (noise example)")
    p.add_argument("--poison-rate", type=float, default=0.0, help="non-JSON message bodies")
    p.add_argument("--seed", type=int)
    p.add_argument("--insert-id-prefix", default="", help="tag entries, e.g. to trigger a test failure")
    p.add_argument("--ids-out", help="append published message IDs here (one per line)")
    args = p.parse_args()
    if args.seed is not None:
        random.seed(args.seed)

    if args.out:
        with open(args.out, "w") as f:
            for _ in range(args.count):
                e = make_entry(args, dt.datetime.now(dt.timezone.utc))
                f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")
        print(f"wrote {args.count} entries to {args.out}")
        return

    if not args.publish:
        p.error("--out or --publish is required")
    pub = Publisher(args.publish)
    ids_f = open(args.ids_out, "a") if args.ids_out else None
    sent, start, last = 0, time.time(), None
    while time.time() - start < args.duration and sent < args.max_messages:
        tick = time.time()
        msgs = []
        for _ in range(args.batch):
            if last is not None and random.random() < args.dup_rate:
                msgs.append(last)
                continue
            last = to_message(make_entry(args, dt.datetime.now(dt.timezone.utc)), args)
            msgs.append(last)
        for attempt in range(5):
            try:
                ids = pub.publish(msgs)
                break
            except Exception as ex:  # transient HTTP errors: retry the same batch
                print(f"publish failed ({ex}); retry {attempt + 1}", file=sys.stderr)
                time.sleep(2 ** attempt)
        else:
            raise SystemExit("publish failed after retries")
        sent += len(ids)
        if ids_f:
            ids_f.write("\n".join(ids) + "\n")
            ids_f.flush()
        wait = args.batch / args.rate - (time.time() - tick)
        if wait > 0:
            time.sleep(wait)
    el = time.time() - start
    print(f"published {sent} messages in {el:.0f}s ({sent / el:.1f} msg/s)", file=sys.stderr)


if __name__ == "__main__":
    main()
