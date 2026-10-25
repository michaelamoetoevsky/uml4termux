#!/usr/bin/env python3
"""Validate device-run evidence files against evidence/schema.json.

Used by `make evidence-check`, `ci/local-ci.sh` and
.github/workflows/device-evidence.yml, so that a phone-side verification run
can be uploaded and checked by the same rules everywhere.

This is the check that keeps the project's central claim honest: a UML boot is
only ever *observed on a device*, never on a GitHub runner. An evidence record
is the artifact that carries that observation, so it must at least say which
device, which guest kernel, which capability probes were run, and what the
verdict was.

Engines
-------
jsonschema   Used when importable (it is on GitHub runners and on this
             project's reference Termux device). Full Draft-07 validation.
builtin      A deliberately small Draft-07 subset: type, required, properties,
             additionalProperties, items, enum, const, pattern, min/maxLength,
             minimum/maximum, minItems/maxItems, format (date-time / email /
             uri), and $ref to #/definitions/*. Unsupported keywords are
             reported as warnings, never silently ignored. This exists so a
             device with no pip and no jsonschema can still check its own
             evidence before uploading it.

Usage
-----
  ci/check-evidence.py [EVIDENCE.json ...]
  ci/check-evidence.py --schema evidence/schema.json evidence/*.json
  ci/check-evidence.py --dir evidence
  ci/check-evidence.py --list-fields     # print the schema's required tree and exit

With no file arguments, every *.json under evidence/ (except schema.json) is
checked -- that is what CI does.

Exit codes
----------
  0   all records valid
  1   at least one record invalid, or the schema itself is not a valid schema
  2   usage error
  77  nothing to validate (evidence/ empty or absent) -- distinct from PASS
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

SKIP = 77

try:
    import jsonschema  # type: ignore

    HAVE_JSONSCHEMA = True
except Exception:  # pragma: no cover
    jsonschema = None
    HAVE_JSONSCHEMA = False


# ---------------------------------------------------------------------------
# built-in minimal validator
# ---------------------------------------------------------------------------
class MiniValidator:
    """A small, explicit Draft-07 subset.

    Returns a list of "human readable" error strings of the form
    `$.a.b: <problem>`. Anything it cannot check is collected in `unsupported`.
    """

    def __init__(self, schema: dict):
        self.root = schema
        self.unsupported: set[str] = set()

    # -- public ------------------------------------------------------------
    def validate(self, instance) -> list:
        errors: list = []
        self._check(self.root, instance, "$", errors)
        return errors

    # -- helpers -----------------------------------------------------------
    def _resolve(self, ref: str):
        if not isinstance(ref, str) or not ref.startswith("#/"):
            self.unsupported.add("$ref:%s" % ref)
            return None
        node = self.root
        for part in ref[2:].split("/"):
            part = part.replace("~1", "/").replace("~0", "~")
            if isinstance(node, dict) and part in node:
                node = node[part]
            elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
                node = node[int(part)]
            else:
                self.unsupported.add("$ref:%s" % ref)
                return None
        return node

    def _type_name(self, value) -> str:
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, int):
            return "integer"
        if isinstance(value, float):
            return "number"
        if isinstance(value, str):
            return "string"
        if isinstance(value, list):
            return "array"
        if isinstance(value, dict):
            return "object"
        return type(value).__name__

    def _type_ok(self, want, value) -> bool:
        have = self._type_name(value)
        if want == "number":
            return have in ("number", "integer")
        if want == "integer":
            return have == "integer"
        return have == want

    def _check(self, schema, value, path: str, errors: list) -> None:
        if schema is True or schema == {}:
            return
        if schema is False:
            errors.append("%s: schema forbids any value here" % path)
            return
        if not isinstance(schema, dict):
            self.unsupported.add("boolean/other schema form")
            return

        if "$ref" in schema:
            target = self._resolve(schema["$ref"])
            if target is not None:
                self._check(target, value, path, errors)
            return

        for kw in ("allOf", "anyOf", "oneOf", "not", "if", "patternProperties",
                   "dependencies", "propertyNames", "contains", "uniqueItems"):
            if kw in schema:
                self.unsupported.add(kw)

        # type -------------------------------------------------------------
        types = schema.get("type")
        if types is not None:
            allowed = types if isinstance(types, list) else [types]
            if not any(self._type_ok(t, value) for t in allowed):
                errors.append(
                    "%s: expected type %s, got %s"
                    % (path, "/".join(str(t) for t in allowed), self._type_name(value))
                )
                return

        # enum / const ------------------------------------------------------
        if "const" in schema and value != schema["const"]:
            errors.append(
                "%s: must be %r, got %r" % (path, schema["const"], value)
            )
        if "enum" in schema and value not in schema["enum"]:
            errors.append(
                "%s: %r is not one of %s"
                % (path, value, ", ".join(repr(v) for v in schema["enum"]))
            )

        # numbers -----------------------------------------------------------
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in schema and value < schema["minimum"]:
                errors.append("%s: %r is below minimum %r" % (path, value, schema["minimum"]))
            if "maximum" in schema and value > schema["maximum"]:
                errors.append("%s: %r is above maximum %r" % (path, value, schema["maximum"]))
            if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
                errors.append("%s: %r must be > %r" % (path, value, schema["exclusiveMinimum"]))
            if "exclusiveMaximum" in schema and value >= schema["exclusiveMaximum"]:
                errors.append("%s: %r must be < %r" % (path, value, schema["exclusiveMaximum"]))

        # strings -----------------------------------------------------------
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                errors.append(
                    "%s: string is shorter than minLength %d" % (path, schema["minLength"])
                )
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                errors.append(
                    "%s: string is longer than maxLength %d" % (path, schema["maxLength"])
                )
            if "pattern" in schema:
                try:
                    if not re.search(schema["pattern"], value):
                        errors.append(
                            "%s: %r does not match pattern %r"
                            % (path, value, schema["pattern"])
                        )
                except re.error as exc:
                    self.unsupported.add("pattern(%s)" % exc)
            fmt = schema.get("format")
            if fmt == "date-time" and not _is_datetime(value):
                errors.append(
                    "%s: %r is not an ISO-8601 date-time with an offset "
                    "(e.g. 2026-10-26T04:30:00+07:00)" % (path, value)
                )
            elif fmt == "email" and "@" not in value:
                errors.append("%s: %r is not an email address" % (path, value))
            elif fmt == "uri" and "://" not in value:
                errors.append("%s: %r is not a URI" % (path, value))
            elif fmt and fmt not in ("date-time", "email", "uri"):
                self.unsupported.add("format:%s" % fmt)

        # arrays ------------------------------------------------------------
        if isinstance(value, list):
            if "minItems" in schema and len(value) < schema["minItems"]:
                errors.append(
                    "%s: needs at least %d item(s), has %d"
                    % (path, schema["minItems"], len(value))
                )
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                errors.append(
                    "%s: allows at most %d item(s), has %d"
                    % (path, schema["maxItems"], len(value))
                )
            items = schema.get("items")
            if items is not None:
                for idx, item in enumerate(value):
                    self._check(items, item, "%s[%d]" % (path, idx), errors)

        # objects -----------------------------------------------------------
        if isinstance(value, dict):
            for req in schema.get("required", []) or []:
                if req not in value:
                    errors.append("%s: missing required property '%s'" % (path, req))
            props = schema.get("properties", {}) or {}
            for name, subschema in props.items():
                if name in value:
                    self._check(subschema, value[name], "%s.%s" % (path, name), errors)
            additional = schema.get("additionalProperties", True)
            if additional is False:
                for name in value:
                    if name not in props:
                        errors.append(
                            "%s: unexpected property '%s' (additionalProperties: false)"
                            % (path, name)
                        )
            elif isinstance(additional, dict):
                for name in value:
                    if name not in props:
                        self._check(
                            additional, value[name], "%s.%s" % (path, name), errors
                        )


def _is_datetime(value: str) -> bool:
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        datetime.fromisoformat(s)
        return True
    except ValueError:
        return False


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------
def schema_summary(schema: dict, prefix: str = "$", seen=None, depth: int = 0):
    """Yield '$.device.required_field' lines for the required tree."""
    if seen is None:
        seen = set()
    if depth > 8 or not isinstance(schema, dict):
        return
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref in seen:
            return
        seen.add(ref)
        node = schema
        for part in ref[2:].split("/") if ref.startswith("#/") else []:
            node = node.get(part, {}) if isinstance(node, dict) else {}
        schema = node if isinstance(node, dict) else {}
    for req in schema.get("required", []) or []:
        yield "%s.%s" % (prefix, req)
        sub = (schema.get("properties") or {}).get(req, {})
        yield from schema_summary(sub, "%s.%s" % (prefix, req), seen, depth + 1)
    if isinstance(schema.get("items"), dict):
        yield from schema_summary(schema["items"], "%s[]" % prefix, seen, depth + 1)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Validate uml4termux evidence records.")
    ap.add_argument("files", nargs="*", help="evidence JSON files")
    ap.add_argument("--schema", default=None, help="path to schema.json")
    ap.add_argument("--dir", default=None, help="evidence directory to scan")
    ap.add_argument("--list-fields", action="store_true",
                    help="print the schema's required-field tree and exit")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    schema_path = args.schema or os.path.join(root, "evidence", "schema.json")
    evidence_dir = args.dir or os.path.join(root, "evidence")

    if not os.path.exists(schema_path):
        print("check-evidence: FAIL schema not found: %s" % schema_path, file=sys.stderr)
        return 1

    try:
        with open(schema_path, "r", encoding="utf-8") as fh:
            schema = json.load(fh)
    except (OSError, ValueError) as exc:
        print("check-evidence: FAIL schema is not readable JSON: %s" % exc, file=sys.stderr)
        return 1

    # The schema must itself be a valid Draft-07 schema.
    if HAVE_JSONSCHEMA:
        try:
            jsonschema.Draft7Validator.check_schema(schema)
        except Exception as exc:  # jsonschema.SchemaError
            print("check-evidence: FAIL evidence/schema.json is not a valid "
                  "JSON Schema:\n  %s" % exc, file=sys.stderr)
            return 1
    else:
        if not isinstance(schema, dict) or "$schema" not in schema:
            print("check-evidence: FAIL evidence/schema.json has no $schema key",
                  file=sys.stderr)
            return 1

    if args.list_fields:
        print("required fields per %s:" % os.path.relpath(schema_path, root))
        for line in schema_summary(schema):
            print("  %s" % line)
        return 0

    files = list(args.files)
    if not files:
        if not os.path.isdir(evidence_dir):
            print("check-evidence: SKIP no evidence/ directory")
            return SKIP
        for path in sorted(glob.glob(os.path.join(evidence_dir, "*.json"))):
            if os.path.basename(path) == os.path.basename(schema_path):
                continue
            files.append(path)

    files = [f for f in files if os.path.basename(f) != os.path.basename(schema_path)]

    if not files:
        print(
            "check-evidence: SKIP evidence/ holds no records yet "
            "(add evidence/<run>.json, or upload a device run -- see evidence/README.md)"
        )
        return SKIP

    if HAVE_JSONSCHEMA:
        validator = jsonschema.Draft7Validator(schema)
        engine = "jsonschema"
    else:
        mini = MiniValidator(schema)
        validator = None
        engine = "builtin (jsonschema not importable)"

    failed = 0
    unsupported: set = set()
    for path in files:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                record = json.load(fh)
        except ValueError as exc:
            print("check-evidence: FAIL %s: not valid JSON: %s" % (path, exc))
            failed += 1
            continue
        except OSError as exc:
            print("check-evidence: FAIL %s: cannot read: %s" % (path, exc))
            failed += 1
            continue

        if validator is not None:
            problems = sorted(
                validator.iter_errors(record),
                key=lambda e: (len(list(e.absolute_path)), list(e.absolute_path)),
            )
            msgs = []
            for err in problems:
                loc = "$"
                for part in err.absolute_path:
                    loc += "[%d]" % part if isinstance(part, int) else ".%s" % part
                msgs.append("%s: %s" % (loc, err.message))
        else:
            msgs = mini.validate(record)
            unsupported |= mini.unsupported

        if msgs:
            failed += 1
            print("check-evidence: FAIL %s (%d problem%s)"
                  % (path, len(msgs), "" if len(msgs) == 1 else "s"))
            for m in msgs:
                print("  - %s" % m)
            print("  required fields are listed by: ci/check-evidence.py --list-fields")
        elif not args.quiet:
            version = record.get("project_version", "?")
            verdict = record.get("verdict", "?")
            print("check-evidence: OK   %s (version=%s verdict=%s)"
                  % (path, version, verdict))

    if unsupported:
        print("check-evidence: WARN built-in engine could not evaluate: %s"
              % ", ".join(sorted(unsupported)))

    if not args.quiet:
        print("check-evidence: engine=%s files=%d failed=%d" % (engine, len(files), failed))

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
