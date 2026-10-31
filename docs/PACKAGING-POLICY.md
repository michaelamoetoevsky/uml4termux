# Termux packaging policy — clause by clause, with the evidence

The package was submitted as [termux/termux-packages#33074](https://github.com/termux/termux-packages/pull/33074)
and closed automatically. This document records **why**, quoted from the files that decide
it, and separates the two questions that are easy to confuse:

1. **Is the package technically acceptable?** — yes, and their own linter now says so
   (evidence below).
2. **Is the project eligible?** — not yet, by an automated rule with three numeric inputs.
   Two of them are facts I can measure; one of them is time.

---

## 1. The seven policy clauses

Quoted from [`CONTRIBUTING.md` § Packaging policy](https://github.com/termux/termux-packages/blob/master/CONTRIBUTING.md#packaging-policy)
(fetched 2026-10-31, 765 lines) and checked against this repository.

| Clause | Status | Evidence |
|---|---|---|
| Must be active, well-known project with an established community | **not met yet** | 0 stars, 0 forks, 1 watcher, 5.75 days old — see `docs/ADOPTION.md` for the arithmetic and the date this stops mattering |
| Widely recognised open-source licence | **met** | `TERMUX_PKG_LICENSE=GPL-2.0-only`; GitHub reports `GPL-2.0`; licence list check in their linter: PASS |
| Not installable through a language package manager | **met** | it is not on crates.io, npm or PyPI; the Rust front end is built from this repository's own sources and ships in its release |
| Resulting package under 100 MiB | **met by three orders of magnitude** | release tarball 222 203 B; the ~1.5 GB runtime is fetched on first use with pinned digests, not packaged |
| Not duplicating existing functionality | **met, and the difference is the point** | `proot-distro` runs userspace through `ptrace` with no kernel of its own; this runs a real Linux kernel (UML) and therefore real Docker with `overlay2`, cgroup v2 and netfilter — the thing `proot-distro` cannot do |
| No hacking/phishing/spam/DDoS purpose | **met** | it boots a VM the user owns, on the user's own device |
| Root not required | **met** | verified on an unprivileged Termux app throughout; the guest is root inside its own kernel, which is not Android root |

## 2. What actually closed the pull request

Not a maintainer's judgement call: an automated job,
[`.github/workflows/lint_pr.yml`](https://github.com/termux/termux-packages/blob/master/.github/workflows/lint_pr.yml),
job `check-new-package-source`, fetched 2026-10-31. Its condition, verbatim:

```python
same_owner = repo_data["owner"]["login"].lower() == pr_author.lower()
age_days   = (datetime.now(timezone.utc) - created).total_seconds() / 86400
is_new     = age_days < 60
low_stars  = repo_data["stargazers_count"] < 10

if same_owner and is_new and low_stars:
    # comment, label "invalid", close the PR
```

Our inputs, read from the API on 2026-10-31:

| Input | Value | Threshold | Verdict |
|---|---|---|---|
| `owner == PR author` | `michaelamoetoevsky` | — | true, and not changeable |
| `age_days` | 5.75 (created `2026-10-25T23:53:35Z`) | `< 60` | **true until 2026-12-24** |
| `stargazers_count` | 0 | `< 10` | true |

So the gate fires on **all three**, and it stops firing when **either** the repository is 60
days old (**2026-12-24**) **or** it has 10 stars. Both are facts, not arguments. Note the
corollary: the same job's `check-new-package-source` check-run reports **success** even when
it closes the PR — it succeeds at doing its job, which is why a green check next to a closed
PR is not a contradiction.

## 3. Is the package itself acceptable? Their linter says yes

`scripts/lint-packages.sh` (831 lines, fetched from their `master`) run against our
`build.sh` inside an Alpine container (Termux has no `/bin`, so `xxd` and `realpath
--relative-to` are unavailable there; the container gives the script the environment it
expects). Output, verbatim:

```
Layout: PASS
Package name 'uml4termux': PASS
End of line check: PASS
File permission check: PASS
Indentation check: PASS
Syntax check: PASS
Trailing whitespace check: PASS
TERMUX_PKG_HOMEPAGE: PASS
TERMUX_PKG_DESCRIPTION: PASS
TERMUX_PKG_LICENSE: PASS
TERMUX_PKG_MAINTAINER: PASS
TERMUX_PKG_API_LEVEL: PASS
TERMUX_PKG_VERSION: TERMUX_PKG_SRCURL: PASS - (Tag/HTTPS) github.com/michaelamoetoevsky/uml4termux
TERMUX_PKG_SHA256: PASS
TERMUX_PKG_BUILD_IN_SRC: PASS

Checked 1 packages.
Everything seems ok.
```

**Two real defects were found by running it, and fixed:**

1. the file ended `20 7d` (`space`, `}`) with **no trailing newline** — their linter refuses
   that, and it is the same class of defect that has bitten this repository's own generated
   files;
2. **indentation used spaces**, and their convention is tabs (`Indentation check: FAILED —
   Use tabs for indentation`).

Neither would have been caught by reading the file, and neither is caught by `lint-pr`
(which only warns about maintainer edits). The linter's version check is disabled upstream
(`TEMPORARY - REMOVE WHEN THIS FUNCTION IS FIXED`), so no version choreography is needed.

## 4. What would change the outcome

- **Nothing about the code.** The package is packaging-correct today.
- **Either** the date **2026-12-24** passes (age ≥ 60 days), **or** the project reaches
  **10 stars**. `docs/ADOPTION.md` carries the baseline, the milestones and the rule that
  stars are never manufactured — a self-starred or traded star is a lie that a maintainer
  can see in the referrer history, and it would poison every later submission.
- If a maintainer disagrees with the bot's reading, the PR comment invites exactly that
  conversation; it was held open for that, with the facts and no argument about the policy.

## 5. Re-submission checklist (so the second attempt is one action)

1. Re-check the gate inputs: `age_days ≥ 60` or `stars ≥ 10` (`docs/ADOPTION.md` has the
   exact API calls).
2. Branch from the **upstream** `master` sha, never from the fork's `master` — the first
   attempt (#33073) carried an unrelated file because of that, and had to be closed.
3. Copy `packaging/termux/build.sh` unchanged: it passes `lint-packages.sh` as of this
   commit.
4. Enable "Allow edits by maintainers" on the fork before opening (the bot asks for it).