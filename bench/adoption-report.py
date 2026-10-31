#!/usr/bin/env python3
"""Print this project's adoption numbers from the API, and optionally record them.

Why this exists: `docs/ADOPTION.md` holds a baseline measured by hand, and a hand-measured
baseline rots the moment nobody re-types it. One implementation, one table, and a record that
`ci/check-evidence.py` can validate.

Usage:
  bench/adoption-report.py                     # human table
  bench/adoption-report.py --record            # + evidence/adoption-<date>.json
  bench/adoption-report.py --repo owner/name   # another repository

Token: read from ~/.hermes/.env (GITHUB_TOKEN) or $GITHUB_TOKEN. Never printed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys

API = "https://api.github.com"


def token() -> str:
    if os.environ.get("GITHUB_TOKEN"):
        return os.environ["GITHUB_TOKEN"]
    env = pathlib.Path.home() / ".hermes/.env"
    for line in env.read_text().splitlines():
        if line.startswith("GITHUB_TOKEN="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("no GITHUB_TOKEN in env or ~/.hermes/.env")


TOK = token()


def get(path: str):
    """curl, not urllib: direct TLS from this phone times out while curl works."""
    out = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"adopt{abs(hash(path)) % 10**8}.json"
    cmd = ["curl", "-sS", "--max-time", "45", "-H", f"Authorization: Bearer {TOK}",
           "-H", "Accept: application/vnd.github+json", API + path, "-o", str(out), "-w", "%{http_code}"]
    code = subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    try:
        data = json.loads(out.read_text() or "{}")
    except json.JSONDecodeError:
        data = {}
    finally:
        out.unlink(missing_ok=True)
    if str(code) not in ("200", "301", "302"):
        return None
    return data


def collect(repo: str) -> dict:
    meta = get(f"/repos/{repo}") or {}
    created = dt.datetime.strptime(meta["created_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    now = dt.datetime.now(dt.timezone.utc)
    releases = get(f"/repos/{repo}/releases") or []
    views = get(f"/repos/{repo}/traffic/views") or {}
    clones = get(f"/repos/{repo}/traffic/clones") or {}
    refs = get(f"/repos/{repo}/traffic/popular/referrers") or []
    contributors = get(f"/repos/{repo}/contributors?per_page=100") or []
    open_issues = get(f"/repos/{repo}/issues?state=all&per_page=100") or []
    author = repo.split("/")[0]
    external = [i for i in open_issues if (i.get("user") or {}).get("login", "") != author
                and "pull_request" not in i]
    gate_date = created + dt.timedelta(days=60)
    return {
        "measured_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo": repo,
        "created_at": meta.get("created_at"),
        "age_days": round((now - created).total_seconds() / 86400, 2),
        "stars": meta.get("stargazers_count"),
        "forks": meta.get("forks_count"),
        "watchers": meta.get("subscribers_count"),
        "topics": meta.get("topics", []),
        "license": (meta.get("license") or {}).get("spdx_id"),
        "contributors": len(contributors),
        "contributor_logins": [c.get("login") for c in contributors][:10],
        "releases": [
            {"tag": r.get("tag_name"), "created": (r.get("created_at") or "")[:10],
             "downloads": sum(a.get("download_count", 0) for a in r.get("assets", []))}
            for r in releases
        ],
        "downloads_total": sum(a.get("download_count", 0) for r in releases for a in r.get("assets", [])),
        "views_14d": {"count": views.get("count", 0), "uniques": views.get("uniques", 0)},
        "clones_14d": {"count": clones.get("count", 0), "uniques": clones.get("uniques", 0)},
        "referrers": [(r.get("referrer"), r.get("count")) for r in refs][:5],
        "external_issues": len(external),
        "external_issue_numbers": [i["number"] for i in external][:10],
        "gate": {
            "rule": "closed while owner == author AND age_days < 60 AND stars < 10",
            "is_new": (now - created).total_seconds() / 86400 < 60,
            "low_stars": (meta.get("stargazers_count") or 0) < 10,
            "gate_clears_on_date": gate_date.date().isoformat(),
            "stars_needed": max(0, 10 - (meta.get("stargazers_count") or 0)),
        },
    }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="michaelamoetoevsky/uml4termux")
    ap.add_argument("--record", action="store_true", help="write evidence/adoption-<date>.json")
    args = ap.parse_args(argv[1:])

    d = collect(args.repo)
    if d["stars"] is None:
        print("could not read the repository (token scope or network)", file=sys.stderr)
        return 1

    print(f"  {d['repo']}  measured {d['measured_at']}")
    print(f"  age            {d['age_days']} days (created {d['created_at']})")
    print(f"  stars/forks    {d['stars']} / {d['forks']}   watchers {d['watchers']}")
    print(f"  contributors   {d['contributors']}  {d['contributor_logins']}")
    print(f"  releases       {len(d['releases'])}, downloads total {d['downloads_total']}")
    for r in d["releases"][:5]:
        print(f"    {r['tag']:10s} {r['created']}  {r['downloads']} downloads")
    print(f"  views 14d      {d['views_14d']['count']} ({d['views_14d']['uniques']} unique)")
    print(f"  clones 14d     {d['clones_14d']['count']} ({d['clones_14d']['uniques']} unique)")
    print(f"  referrers      {d['referrers']}")
    print(f"  external issues {d['external_issues']} {d['external_issue_numbers']}")
    print(f"  topics         {', '.join(d['topics']) or '(none)'}")
    print(f"  gate           is_new={d['gate']['is_new']} low_stars={d['gate']['low_stars']} "
          f"-> clears on {d['gate']['gate_clears_on_date']} or at {d['gate']['stars_needed']} more stars")

    if args.record:
        edir = pathlib.Path("evidence")
        edir.mkdir(exist_ok=True)
        dest = edir / f"adoption-{d['measured_at'][:10].replace('-', '')}.json"
        dest.write_text(json.dumps(d, indent=2) + "\n")
        print(f"  recorded -> {dest} (validate with ci/check-evidence.py --dir evidence)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))