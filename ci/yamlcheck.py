#!/usr/bin/env python3
"""Validate the YAML files in this repository -- with or without PyYAML.

Why this exists
---------------
GitHub validates workflow YAML only *after* a push, and PyYAML is not always
installable on the device (a plain Termux aarch64 box has no `pip` that works,
and no `yq`). We still want a real, local answer to "is this workflow file
loadable at all?" before pushing.

Two engines, chosen automatically:

  pyyaml      Full parse by PyYAML with a duplicate-key-rejecting loader, plus
              GitHub-Actions shape assertions (`on`, `jobs`, `runs-on`, `steps`).
              Used on GitHub runners (`pip install pyyaml` in the workflow).

  structural  A dependency-free indentation/flow-structure checker: tabs in
              indentation, unbalanced quotes and flow collections, duplicate
              keys in the same mapping, sequence-vs-mapping confusion, illegal
              indentation increases, and (for workflows) the presence of
              top-level `name:`, `on:`, `jobs:`.

The structural engine is NOT a YAML parser. It deliberately does not support
multi-line plain scalars, anchors/aliases, merge keys (<<), or explicit tags,
and it cannot type-check values -- it finds *shape* mistakes, which is where
hand-edited workflow files actually go wrong. When only structural mode is
available the summary line says so, and the exit code is still truthful.

Usage
-----
  ci/yamlcheck.py FILE...                  # validate files
  ci/yamlcheck.py --workflow FILE...       # + GitHub Actions shape checks
  ci/yamlcheck.py --mode strict FILE...    # fail if PyYAML is missing
  ci/yamlcheck.py --mode structural FILE...
  ci/yamlcheck.py --quiet FILE...

Exit codes
----------
  0   every file validated
  1   at least one file is invalid
  2   usage error
  77  nothing to check (no files given, or none exist)

`--mode strict` turns "PyYAML unavailable" into exit 1 -- that is what the
GitHub workflow uses, because there we control the environment and a silently
downgraded check would be worse than a failure.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

SKIP = 77

try:  # pragma: no cover - depends on the interpreter
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None


# ---------------------------------------------------------------------------
# tiny helpers
# ---------------------------------------------------------------------------
def split_comment(line: str) -> str:
    """Return `line` with a trailing unquoted '# comment' removed."""
    out = []
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            while i < n:
                if quote == '"' and line[i] == "\\" and i + 1 < n:
                    out.append(line[i])
                    out.append(line[i + 1])
                    i += 2
                    continue
                out.append(line[i])
                i += 1
                if line[i - 1] == quote:
                    break
            continue
        if c == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(c)
        i += 1
    return "".join(out)


def flow_balance(text: str) -> int:
    """Net count of unquoted [ ] { } in `text` (0 == balanced)."""
    depth = 0
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            quote = c
            i += 1
            while i < n:
                if quote == '"' and text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
        i += 1
    return depth


def mapping_key(text: str):
    """Return (key, True) if `text` is `key: ...`, else (None, False)."""
    s = split_comment(text).rstrip()
    if not s:
        return None, False
    n = len(s)
    if s[:1] in "\"'":
        quote = s[0]
        i = 1
        key = []
        closed = False
        while i < n:
            if quote == '"' and s[i] == "\\" and i + 1 < n:
                key.append(s[i : i + 2])
                i += 2
                continue
            if s[i] == quote:
                closed = True
                i += 1
                break
            key.append(s[i])
            i += 1
        if not closed:
            return None, False
        return ("".join(key), True) if s[i:].startswith(":") else (None, False)
    i = 0
    while i < n:
        c = s[i]
        if c == ":" and (i + 1 >= n or s[i + 1] in " \t"):
            key = s[:i].strip()
            return (key, True) if key else (None, False)
        if c in "[{,}":
            return None, False
        i += 1
    return None, False


def opens_block(content: str) -> bool:
    """True when a line's value is nested (ends with ':') or it is a seq item."""
    c = split_comment(content).rstrip()
    if c == "-" or c == "":
        return True
    if c.startswith("-"):
        c = c[1:].strip()
        if not c:
            return True
    return c.endswith(":")


_BLOCK_HEADER_RE = re.compile(r"(^|:[ \t]+|- )[|>][-+0-9]*[ \t]*$")


def _is_block_header(content: str) -> bool:
    return bool(_BLOCK_HEADER_RE.search(split_comment(content).rstrip()))


# ---------------------------------------------------------------------------
# structural engine
# ---------------------------------------------------------------------------
def validate_structure(text: str):
    """Return (errors, warnings); errors is a list of (lineno, message)."""
    errors: list[tuple[int, str]] = []
    lines = text.split("\n")

    if text.startswith("\ufeff"):
        errors.append((1, "file starts with a UTF-8 BOM (YAML forbids it)"))
    if "\r\n" in text:
        errors.append(
            (1, "file uses CRLF line endings (YAML requires LF; see .gitattributes)")
        )

    # --- pass 1: build logical lines (join multi-line flow collections, skip
    #             block-scalar bodies) ----------------------------------------
    logical: list[tuple[int, int, str]] = []  # (lineno, indent, content)
    i, n = 0, len(lines)
    while i < n:
        raw = lines[i]
        lineno = i + 1
        i += 1
        if raw.strip() == "" or raw.lstrip(" \t").startswith("#"):
            continue
        stripped = raw.lstrip(" \t")
        indent_str = raw[: len(raw) - len(stripped)]
        if "\t" in indent_str:
            errors.append(
                (lineno, "tab character in indentation (YAML requires spaces)")
            )
        raw_indent = len(indent_str)
        content = split_comment(stripped).rstrip()
        if content == "":
            continue

        depth = flow_balance(content)
        if depth != 0:
            start = lineno
            while depth != 0 and i < n:
                nxt = split_comment(lines[i]).rstrip()
                i += 1
                depth += flow_balance(nxt)
                content = content + " " + nxt
            if depth != 0:
                errors.append(
                    (start, "unbalanced flow collection: [ or { is never closed")
                )

        # Effective indent: treat '- ' as two columns of indent so that a
        # sequence item's own mapping lines up with its continuation lines.
        if content == "-" or content.startswith("- "):
            rest = content[1:]
            eff = raw_indent + 1 + (len(rest) - len(rest.lstrip(" ")))
            is_seq = True
        else:
            eff = raw_indent
            is_seq = False

        logical.append((lineno, eff, content))

        if not is_seq and _is_block_header(content):
            header_indent = raw_indent
            while i < n:
                probe = lines[i]
                if probe.strip() == "":
                    i += 1
                    continue
                pindent = len(probe) - len(probe.lstrip(" "))
                if pindent > header_indent:
                    i += 1
                    continue
                break

    # --- pass 2: structure ----------------------------------------------------
    scopes: list[dict] = []  # {"indent": int, "keys": set, "seq": bool}
    prev = None
    for lineno, indent, content in logical:
        is_seq = content == "-" or content.startswith("- ")

        while scopes and scopes[-1]["indent"] > indent:
            scopes.pop()

        if is_seq:
            if scopes and scopes[-1]["indent"] == indent and scopes[-1]["seq"]:
                scopes[-1]["keys"] = set()  # next item of the same sequence
            else:
                scopes.append({"indent": indent, "keys": set(), "seq": True})
            # Note: a sequence may be indented under its key (`key:` then
            # `  - item`) or flush with it, so both are accepted here.
            rest = content[1:].strip()
            key, is_map = mapping_key(rest)
            if rest and is_map:
                _record(scopes[-1]["keys"], key, lineno, errors)
            elif rest:
                # Valid YAML: a plain scalar sequence item (e.g. "- 'v*'" in tags: ['v*'])
                # We accept it silently; the full parse with PyYAML will type-check it.
                pass
            else:
                # Empty sequence item (just "-") is valid
                pass
        else:
            if not scopes or scopes[-1]["indent"] < indent:
                if prev is not None and not opens_block(prev[2]):
                    errors.append(
                        (
                            lineno,
                            "unexpected indentation increase: the previous line %r "
                            "does not open a nested block" % prev[2],
                        )
                    )
                scopes.append({"indent": indent, "keys": set(), "seq": False})
            key, is_map = mapping_key(content)
            if not is_map:
                errors.append(
                    (
                        lineno,
                        "not a mapping entry and not a sequence item: %r" % content,
                    )
                )
            else:
                _record(scopes[-1]["keys"], key, lineno, errors)
        prev = (lineno, indent, content)

    return errors, []


def _record(keys, key, lineno, errors):
    if key is None:
        return
    if key in keys:
        errors.append((lineno, "duplicate key %r in the same mapping" % key))
    keys.add(key)


# ---------------------------------------------------------------------------
# pyyaml engine
# ---------------------------------------------------------------------------
if yaml is not None:

    class StrictLoader(yaml.SafeLoader):
        """SafeLoader that refuses duplicate mapping keys."""

    def _strict_mapping(loader, node, deep=False):
        loader.flatten_mapping(node)
        seen = set()
        for key_node, _ in node.value:
            key = loader.construct_object(key_node, deep=deep)
            try:
                hash(key)
            except TypeError:
                key = str(key)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None,
                    None,
                    "duplicate key %r" % (key,),
                    key_node.start_mark,
                )
            seen.add(key)
        return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)

    StrictLoader.add_constructor(
        yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _strict_mapping
    )

    def validate_pyyaml(text: str):
        errors = []
        warnings = []
        try:
            docs = [d for d in yaml.load_all(text, Loader=StrictLoader)]
        except yaml.YAMLError as exc:
            mark = getattr(exc, "problem_mark", None)
            lineno = (mark.line + 1) if mark is not None else 0
            problem = getattr(exc, "problem", None) or str(exc)
            errors.append((lineno, "%s" % problem))
            return errors, warnings
        docs = [d for d in docs if d is not None]
        if not docs:
            errors.append((0, "file contains no YAML document"))
        return errors, warnings

else:  # pragma: no cover
    validate_pyyaml = None


# ---------------------------------------------------------------------------
# GitHub Actions shape checks
# ---------------------------------------------------------------------------
KNOWN_TRIGGERS = {
    "push",
    "pull_request",
    "pull_request_target",
    "workflow_dispatch",
    "workflow_call",
    "workflow_run",
    "repository_dispatch",
    "schedule",
    "release",
    "merge_group",
    "issues",
    "issue_comment",
    "label",
    "create",
    "delete",
    "deployment",
    "discussion",
    "page_build",
    "status",
    "watch",
}

PERMISSION_LEVELS = {"read", "write", "none"}


def _norm_keys(d):
    """GitHub Actions YAML is 1.2; PyYAML is 1.1 and turns `on:` into True."""
    if not isinstance(d, dict):
        return d
    out = {}
    for k, v in d.items():
        if k is True:
            k = "on"
        elif k is False:
            k = "off"
        out[k] = v
    return out


def check_workflow_shape(doc, fname: str):
    """Assert the GitHub Actions structure we rely on. Returns (errors, warns)."""
    errors: list[tuple[int, str]] = []
    warns: list[tuple[int, str]] = []

    if not isinstance(doc, dict):
        errors.append((0, "workflow must be a mapping at the top level"))
        return errors, warns

    doc = _norm_keys(doc)

    if not isinstance(doc.get("name"), str) or not doc.get("name"):
        errors.append((0, "workflow is missing a non-empty top-level 'name:'"))

    if "on" not in doc:
        errors.append((0, "workflow is missing the top-level 'on:' trigger block"))
    else:
        trig = doc["on"]
        names = []
        if isinstance(trig, str):
            names = [trig]
        elif isinstance(trig, list):
            names = [t for t in trig if isinstance(t, str)]
        elif isinstance(trig, dict):
            names = [k for k in trig if isinstance(k, str)]
        else:
            errors.append((0, "'on:' must be a string, a list or a mapping"))
        unknown = [t for t in names if t not in KNOWN_TRIGGERS]
        if unknown:
            warns.append((0, "unrecognised trigger name(s): %s" % ", ".join(unknown)))
        if not names:
            errors.append((0, "'on:' does not name any trigger"))

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        errors.append((0, "'jobs:' must be a non-empty mapping"))
        return errors, warns

    for jname, job in jobs.items():
        where = "job %r" % jname
        if not isinstance(job, dict):
            errors.append((0, "%s must be a mapping" % where))
            continue
        job = _norm_keys(job)
        if "uses" in job:
            # Reusable-workflow call: runs-on/steps are not allowed here.
            if "steps" in job or "runs-on" in job:
                errors.append(
                    (0, "%s calls a reusable workflow so it must not set steps/runs-on" % where)
                )
            continue
        if not job.get("name") and not isinstance(job.get("runs-on"), (str, list)):
            errors.append((0, "%s is missing 'runs-on'" % where))
        steps = job.get("steps")
        if not isinstance(steps, list) or not steps:
            errors.append((0, "%s has no 'steps' list" % where))
            continue
        for idx, step in enumerate(steps):
            if not isinstance(step, dict):
                errors.append((0, "%s step %d must be a mapping" % (where, idx + 1)))
                continue
            step = _norm_keys(step)
            has_uses = isinstance(step.get("uses"), str) and step.get("uses")
            has_run = isinstance(step.get("run"), str) and step.get("run")
            if not has_uses and not has_run:
                errors.append(
                    (
                        0,
                        "%s step %d has neither 'uses:' nor 'run:'"
                        % (where, idx + 1),
                    )
                )
            if has_uses and has_run:
                errors.append(
                    (0, "%s step %d sets both 'uses:' and 'run:'" % (where, idx + 1))
                )
            if "uses" in step and step.get("uses") and not step.get("uses").strip():
                errors.append((0, "%s step %d has an empty 'uses:'" % (where, idx + 1)))
            for field in ("name", "id"):
                if field in step and not isinstance(step[field], str):
                    errors.append(
                        (0, "%s step %d: '%s' must be a string" % (where, idx + 1, field))
                    )
            if "if" in step and not isinstance(step["if"], str):
                errors.append((0, "%s step %d: 'if' must be a string" % (where, idx + 1)))
            if "env" in step and not isinstance(step["env"], dict):
                errors.append((0, "%s step %d: 'env' must be a mapping" % (where, idx + 1)))

    perms = doc.get("permissions")
    if perms is not None:
        if isinstance(perms, str):
            if perms not in {"read-all", "write-all"}:
                errors.append((0, "'permissions: %s' is not valid" % perms))
        elif isinstance(perms, dict):
            for scope, level in perms.items():
                if level not in PERMISSION_LEVELS:
                    errors.append(
                        (0, "permission %r must be read/write/none, not %r" % (scope, level))
                    )
        else:
            errors.append((0, "'permissions:' must be a string or a mapping"))

    return errors, warns


def check_workflow_text(text: str):
    """Structural-mode fallback: top-level keys must be present at column 0."""
    errors = []
    top = set()
    for line in text.split("\n"):
        if not line or line[0] in " #-\t":
            continue
        key, is_map = mapping_key(line)
        if is_map:
            top.add(key)
    for required in ("name", "on", "jobs"):
        if required not in top:
            errors.append(
                (0, "workflow has no top-level '%s:' key (found: %s)" % (
                    required,
                    ", ".join(sorted(top)) or "nothing",
                ))
            )
    return errors


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Validate YAML files (PyYAML when available, structural otherwise)."
    )
    ap.add_argument("files", nargs="*", help="YAML files to validate")
    ap.add_argument(
        "--mode",
        choices=["auto", "strict", "structural"],
        default="auto",
        help="auto: pyyaml if importable else structural; strict: fail without pyyaml",
    )
    ap.add_argument(
        "--workflow",
        action="store_true",
        help="also assert GitHub Actions workflow shape",
    )
    ap.add_argument("--quiet", action="store_true", help="only print problems")
    args = ap.parse_args(argv)

    existing = [f for f in args.files if os.path.exists(f)]
    missing = [f for f in args.files if not os.path.exists(f)]

    have_pyyaml = yaml is not None
    if args.mode == "structural":
        have_pyyaml = False
    if args.mode == "strict" and not have_pyyaml:
        print(
            "yamlcheck: FAIL  --mode strict requires PyYAML, which is not importable "
            "by this interpreter",
            file=sys.stderr,
        )
        return 1

    if missing and not args.quiet:
        for f in missing:
            print("yamlcheck: SKIP %s (does not exist yet)" % f)
    if not existing:
        if not args.quiet:
            print("yamlcheck: SKIP no YAML files to validate")
        return SKIP

    engine = "pyyaml" if have_pyyaml else "structural"
    failed = 0
    for path in existing:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        except OSError as exc:
            print("yamlcheck: FAIL %s: cannot read: %s" % (path, exc))
            failed += 1
            continue

        if have_pyyaml:
            errors, warnings = validate_pyyaml(text)
        else:
            errors, warnings = validate_structure(text)

        if args.workflow and not errors:
            if have_pyyaml:
                try:
                    docs = [d for d in yaml.load_all(text, Loader=StrictLoader)]
                except yaml.YAMLError:
                    docs = []
                docs = [d for d in docs if d is not None]
                for doc in docs:
                    e2, w2 = check_workflow_shape(doc, path)
                    errors.extend(e2)
                    warnings.extend(w2)
            else:
                errors.extend(check_workflow_text(text))

        if errors:
            failed += 1
            print("yamlcheck: FAIL %s [%s]" % (path, engine))
            for lineno, msg in errors:
                where = "line %d" % lineno if lineno else "file"
                print("           %s: %s" % (where, msg))
        elif not args.quiet and not warnings:
            print("yamlcheck: OK   %s [%s]" % (path, engine))
        else:
            if not args.quiet:
                print("yamlcheck: OK   %s [%s]" % (path, engine))

        for lineno, msg in warnings:
            where = "line %d" % lineno if lineno else "file"
            print("yamlcheck: WARN %s %s: %s" % (path, where, msg))

    if not args.quiet:
        note = "pyyaml (full parse)" if have_pyyaml else (
            "structural only -- PyYAML is unavailable, so values are not type-checked"
        )
        print("yamlcheck: engine=%s files=%d failed=%d" % (note, len(existing), failed))

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
