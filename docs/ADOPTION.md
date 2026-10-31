# Adoption — the measured baseline, and what would move it

Termux's packaging policy asks for "active, well-known projects with an established
community". That is a real requirement with an automated shadow, so this file keeps the
numbers rather than an opinion. Everything below was read from the GitHub API on
**2026-10-31**; the commands are included so the numbers can be re-measured instead of
trusted.

## Baseline

| Signal | Value | How it was read |
|---|---|---|
| stars | **0** | `GET /repos/michaelamoetoevsky/uml4termux` → `stargazers_count` |
| forks | **0** | → `forks_count` |
| watchers | **1** | → `subscribers_count` |
| contributors | **1** (`michaelamoetoevsky`) | `GET /repos/.../contributors` |
| repository age | **5.75 days** (created `2026-10-25T23:53:35Z`) | → `created_at` |
| releases | **5** | `GET /repos/.../releases` |
| release asset downloads | **88** (v0.5.0: 60, v0.4.0: 10, v0.2.0: 7, v0.3.0: 6, v0.1.0: 5) | → `assets[].download_count`, re-measured 18:11 UTC |
| views, 14 days | **377** (6 unique) | `GET /repos/.../traffic/views` |
| clones, 14 days | **963** (166 unique) | `GET /repos/.../traffic/clones` |
| referrers | `github.com` 50 | `GET /repos/.../traffic/popular/referrers` |
| topics | **10, set 2026-10-31** (was empty) | `GET /repos/...` → `topics` |
| external issues opened by others | 0 | `GET /repos/.../issues?state=all` |
| external PRs from others | 0 | `GET /repos/.../pulls?state=all` |

Read honestly: 76 downloads and one contributor is a project that a few people have run and
nobody else has worked on. 166 unique clones in fourteen days sounds better than it is —
most of them are CI runners cloning for a workflow. The unique-view count (6) is the
uncomfortable one, and it is the number to move first.

## The gate, as arithmetic

From `.github/workflows/lint_pr.yml` (job `check-new-package-source`), the pull request is
closed automatically when **all three** hold:

```
owner == PR author  AND  age_days < 60  AND  stars < 10
```

Today: true, true, true. So it stops closing when **either**

- **stars ≥ 10** — whenever that happens, or
- **age ≥ 60 days** — on **2026-12-24**, by the calendar alone.

That second path is why "not yet" is not "no": a resubmission after 2026-12-24 reaches a
human even with zero stars. Stars shorten the wait; they are not required.

## What this project will not do

No bought, traded, or sockpuppet stars. A star that a maintainer can trace to a farm (or to
one account's own second identity) does not just fail — it makes every later submission
suspect, and this repository's entire claim to credibility is that its numbers are real.
Adoption here means **someone other than the author ran it and found it useful**, which is
the same thing the policy is protecting.

## Milestones (each one measurable)

| # | Milestone | Measure | Status |
|---|---|---|---|
| A1 | The project is findable | 10 relevant topics set, description under 160 chars, README first screen says what it does and what it needs | **done 2026-10-31** (topics were empty; they are not any more) |
| A2 | A first external user reports an outcome | an issue/PR/discussion from an account other than the author | open |
| A3 | A first external contributor | `contributors` count ≥ 2, with a merged non-trivial PR | open |
| A4 | 10 stars, organically | `stargazers_count ≥ 10` | open |
| A5 | The packaging gate is passable | `lint-pr`'s `check-new-package-source` does not close the PR | open until 2026-12-24 or A4 |

## What actually moves A2–A4, in order of expected effect

1. **A demo that can be watched.** The README's first screen currently asks the reader to
   believe a table. A 40-second recording of `docker run` inside the guest on a phone is
   worth more than any bullet, and it is the one asset that travels on its own (Reddit,
   Hacker News, Termux discussions).
2. **Being where Termux users already are.** The Termux wiki, r/termux, the Termux issue
   tracker when someone asks about Docker (answer the question, mention the tool second),
   and the UML mailing list for the kernel side. Link the repository only where it answers
   the question being asked.
3. **The one number people search for.** "Docker on Termux without root" is the query; the
   project's README, description and topics now contain those words, which they did not
   before today.
4. **Contributor-sized work.** Issues labelled for outsiders — a second initramfs base, a
   macOS/glibc packaging path, better `proot-distro` comparison notes. One merged external
   PR is worth more for the policy than any amount of prose.

## Re-measuring

`bench/adoption-report.py` prints this whole table from the API and can write it as a dated
record (`--record` → `evidence/adoption-YYYYMMDD.json`). It exists because the first version of
this file was measured by hand and had already drifted by the time the next paragraph was
written (76 downloads measured at 17:5x, 88 at 18:11).


```sh
T=$(sed -n 's/^GITHUB_TOKEN=//p' ~/.hermes/.env | head -1)
curl -sS -H "Authorization: Bearer $T" https://api.github.com/repos/michaelamoetoevsky/uml4termux \
  | jq '{stars: .stargazers_count, forks: .forks_count, watchers: .subscribers_count, created: .created_at, topics}'
curl -sS -H "Authorization: Bearer $T" https://api.github.com/repos/michaelamoetoevsky/uml4termux/releases \
  | jq '[.[] | {tag: .tag_name, downloads: ([.assets[].download_count] | add)}]'
```

If a number in this file and a number from those commands disagree, the commands win — and
the file gets corrected in the same commit, not annotated underneath.