#!/usr/bin/env python3
"""Publish a completed review round from its saved receipt, or keep it local."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def finish(receipt, pr):
    # The orchestrator retains this file and its basename across handoffs and retries.
    with receipt.open(encoding="utf-8") as record:
        fcntl.flock(record, fcntl.LOCK_EX)
        line = record.read()
        if line.endswith("\n"):
            line = line[:-1]
        checked = re.fullmatch(
            r"CC_CODEX_REQUIRED_REVIEW (APPROVE) thread=\S+ head=([0-9a-f]{40}) "
            r"tree=[0-9a-f]{40} base_sha=[0-9a-f]{40} spec_path=.+", line
        )
        decision = checked or re.fullmatch(
            r"cc-tuner-verdict: (APPROVE|REQUEST_CHANGES) ([0-9a-f]{40})", line
        )
        if not decision:
            raise ValueError("expected one completed verdict with its full reviewed SHA")
        verdict, sha = decision.groups()
        marker = f"cc-tuner-verdict: {verdict} {sha}"
        if pr is None:
            print(f"{marker}\nLocal receipt: {receipt}")
            return

        route = Path(__file__).parent / "setup" / "route.sh"
        result = subprocess.check_output(["bash", route, "preflight", "github"], text=True)
        label, _, host, project = result.splitlines()[-1].split("\t")
        if label != "destination" or not host or not project:
            raise ValueError("missing GitHub destination from route preflight")
        api = [os.environ.get("CC_TUNER_GH", "gh"), "api", "--hostname", host]
        endpoint = f"repos/{project}/pulls/{pr}"

        round_id = hashlib.sha256(receipt.name.encode()).hexdigest()
        tag = f"<!-- cc-tuner-round: {round_id} -->"
        body = f"{marker}\n\n{tag}"
        author = json.loads(subprocess.check_output([*api, "user"]))["id"]
        pages = json.loads(subprocess.check_output([*api, "--paginate", "--slurp", endpoint + "/reviews"]))
        for page in pages:
            for review in page:
                if (review.get("user") or {}).get("id") != author:
                    continue
                if tag not in (review["body"] or "").splitlines():
                    continue
                if (review["body"] != body or review["commit_id"] != sha
                        or review["state"] != "COMMENTED"):
                    raise ValueError("existing round disagrees with receipt; inspect the published review")
                print(review["html_url"])
                return

        pull = json.loads(subprocess.check_output([*api, endpoint]))
        if pull["head"]["sha"] != sha:
            # A lost response can leave a historical verdict pending after a normal push.
            commits = json.loads(subprocess.check_output([*api, "--paginate", "--slurp", endpoint + "/commits"]))
            if not any(commit["sha"] == sha for page in commits for commit in page):
                raise ValueError(f"reviewed commit {sha} is not in PR {pr}; retained {receipt}")
        subprocess.run([*api, endpoint + "/reviews", "--method", "POST", "-f", "event=COMMENT",
                        "-f", f"commit_id={sha}", "-f", f"body={body}", "--jq", ".html_url"], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path, help="one uniquely named file per review round")
    parser.add_argument("--pr", type=int, help="authorized GitHub PR number in the delivery repository")
    args = parser.parse_args()
    if args.pr is not None and args.pr < 1:
        parser.error("--pr requires a positive PR number")
    try:
        finish(args.receipt, args.pr)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"cc-tuner review: {error}")
