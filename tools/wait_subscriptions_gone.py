#!/usr/bin/env python3
"""Wait until a topic has no ClickPipes subscriptions (clickpipes-*) left.

Deleting a ClickPipe returns at once; ClickPipes then deletes its managed subscription in the
background, with the service account key. Removing the key or its role before that leaves the
subscription behind, attached to the deleted topic. Run this between deleting the pipe and
removing the service account (Terraform does it on destroy, see terraform/gcp.tf).

Usage: wait_subscriptions_gone.py --project <project> --topic <topic> [--timeout 300]
Auth: an access token from `gcloud auth application-default print-access-token`.
Exit 0 when none is left, 1 on timeout (the remaining names are printed).
"""
import argparse, json, subprocess, sys, time, urllib.error, urllib.request


def remaining(project, topic, token):
    url = f"https://pubsub.googleapis.com/v1/projects/{project}/topics/{topic}/subscriptions"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "x-goog-user-project": project})
    try:
        names = json.load(urllib.request.urlopen(req)).get("subscriptions", [])
    except urllib.error.HTTPError as e:
        if e.code == 404:  # the topic is gone: nothing can be attached to it by name any more
            return []
        raise
    return [n for n in names if n.split("/")[-1].startswith("clickpipes-")]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--topic", required=True)
    p.add_argument("--timeout", type=int, default=300)
    a = p.parse_args()
    token = subprocess.check_output(["gcloud", "auth", "application-default", "print-access-token"], text=True).strip()
    deadline = time.time() + a.timeout
    while True:
        left = remaining(a.project, a.topic, token)
        if not left:
            print(f"no ClickPipes subscriptions left on {a.topic}")
            return
        if time.time() > deadline:
            print("still attached after the timeout (delete them once the pipe is gone):", file=sys.stderr)
            for n in left:
                print(f"  gcloud pubsub subscriptions delete {n.split('/')[-1]} --project {a.project}", file=sys.stderr)
            sys.exit(1)
        time.sleep(10)


if __name__ == "__main__":
    main()
