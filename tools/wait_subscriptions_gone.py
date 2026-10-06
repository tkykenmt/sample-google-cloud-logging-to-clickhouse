#!/usr/bin/env python3
"""Wait until a topic has no ClickPipes subscriptions (clickpipes-*) left.

Deleting a ClickPipe returns at once; ClickPipes then deletes its managed subscription in the
background, with the service account key. Removing the key or its role before that leaves the
subscription behind, attached to the deleted topic. Run this between deleting the pipe and
removing the service account (Terraform does it on destroy, see terraform/gcp.tf).

Usage: wait_subscriptions_gone.py --project <project> --topic <topic> [--timeout 300]
Auth: GOOGLE_OAUTH_ACCESS_TOKEN if set, otherwise `gcloud auth application-default print-access-token`.
Exit 0 when none is left, 1 on timeout or when the topic cannot be read (the commands to finish by hand
are printed).
"""
import argparse, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request


def token():
    if os.environ.get("GOOGLE_OAUTH_ACCESS_TOKEN"):
        return os.environ["GOOGLE_OAUTH_ACCESS_TOKEN"]
    return subprocess.check_output(["gcloud", "auth", "application-default", "print-access-token"], text=True).strip()


def remaining(project, topic, tok):
    names, page = [], None
    while True:
        url = f"https://pubsub.googleapis.com/v1/projects/{project}/topics/{topic}/subscriptions?pageSize=1000"
        if page:
            url += "&pageToken=" + urllib.parse.quote(page)
        d = None
        # User ADC tokens may need a quota project: retry once with the topic's project as the quota project.
        for headers in ({"Authorization": f"Bearer {tok}"},
                        {"Authorization": f"Bearer {tok}", "x-goog-user-project": project}):
            try:
                d = json.load(urllib.request.urlopen(urllib.request.Request(url, headers=headers)))
                break
            except urllib.error.HTTPError as e:
                if e.code == 404:  # the topic is gone: nothing can be attached to it by name any more
                    return []
                if e.code != 403 or "x-goog-user-project" in headers:
                    raise
        names += d.get("subscriptions", [])
        page = d.get("nextPageToken")
        if not page:
            break
    return [n for n in names if n.split("/")[-1].startswith("clickpipes-")]


def manual(project, topic, left=None):
    print("Finish by hand once the pipe is deleted:", file=sys.stderr)
    if left:
        for n in left:
            print(f"  gcloud pubsub subscriptions delete {n.split('/')[-1]} --project {project}", file=sys.stderr)
    else:
        print(f"  gcloud pubsub topics list-subscriptions {topic} --project {project}", file=sys.stderr)
        print(f"  gcloud pubsub subscriptions delete <clickpipes-...> --project {project}", file=sys.stderr)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--topic", required=True)
    p.add_argument("--timeout", type=int, default=300)
    a = p.parse_args()
    try:
        tok = token()
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"no access token for Pub/Sub ({e})", file=sys.stderr)
        manual(a.project, a.topic)
        sys.exit(1)
    deadline = time.time() + a.timeout
    while True:
        try:
            left = remaining(a.project, a.topic, tok)
        except (urllib.error.URLError, ValueError) as e:
            print(f"could not list the subscriptions of {a.topic} ({e})", file=sys.stderr)
            manual(a.project, a.topic)
            sys.exit(1)
        if not left:
            print(f"no ClickPipes subscriptions left on {a.topic}")
            return
        if time.time() > deadline:
            print(f"still attached after {a.timeout} s:", file=sys.stderr)
            manual(a.project, a.topic, left)
            sys.exit(1)
        time.sleep(10)


if __name__ == "__main__":
    main()
