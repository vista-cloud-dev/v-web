#!/usr/bin/env python3
"""The ICR / DBIA-conformance registry + gate (drift gate #2).

Spec: docs/vsl-msl/msl-vsl-coordination-implementation-plan.md §5.4
      (the L4 ICR registry + DBIA-conformance gate, VSL→L4).

Every L4 (VistA-native) call site in source carries a doc-tag naming the
Integration Control Registration (ICR/DBIA) it relies on:

    ; doc: @icr 2118 @call CALL^%ZISTCP @status Supported @custodian XU
    ;      @source XU/krn_8_0_dg_device_handler_ug#CALL^%ZISTCP

`make icr` collects these into dist/icr-registry.json, keyed by the module that
makes the call. `make check-icr`:

  1. drift: the committed registry equals a fresh regeneration;
  2. every external-reference call site (^DIC/^DIE/^XPAR/^XU*/^%ZIS*/…) is
     declared with a non-retired Supported/Controlled-Subscription ICR — an
     undeclared call, or a Private/retired one, is RED;
  3. no set/kill/$ORDER against a VistA-file global outside a declared
     FileMan-DBS call — the "no direct global access" rule, mechanized.

In an `m`-layer repo (m-stdlib) there are no L4 calls, so the registry is empty
and the gate is trivially green — but it runs everywhere so a leaked
below-the-waterline call cannot merge silently.

Usage:
    python3 tools/gen-icr.py --write        # write dist/icr-registry.json
    python3 tools/gen-icr.py --check        # the gate
    python3 tools/gen-icr.py --self-test    # pure-logic unit tests
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "src"
DIST_DIR = REPO_ROOT / "dist"
REGISTRY_PATH = DIST_DIR / "icr-registry.json"

# VistA-native (L4) routine/global namespace prefixes. A `^`-reference whose
# name starts with one of these is an L4 call that requires a declared ICR.
# (The repo's own STD*/VSL* and pure-M scratch globals are NOT L4.)
VISTA_API_PREFIXES = (
    "DIC", "DIE", "DIQ", "DIK", "DID", "DIR", "DIWP", "DIWF", "DIW", "DGENV", "DG",
    "XPDUTL", "XPDIL", "XPDIJ", "XPDID", "XPDI", "XPD",
    "XPAR", "XUS", "XUSEC", "XUSHSH", "XU", "XLFDT", "XLFSTR", "XLF", "XQ",
    "%ZIS", "%ZISTCP", "%ZISH", "%ZTLOAD", "%ZTER", "VA", "XM",
)

# ICR statuses that satisfy the DBIA-conformance rule (§5.4). Anything else
# (Private, Supplemental, Retired, …) is a violation when a call relies on it.
OK_STATUSES = frozenset({"Supported", "Controlled Subscription"})

# Notional ICR markers (in place of a number). The VistA DBIA/ICR *registry* is
# a manually human-curated FORUM list — not in code, not in a FileMan DD, not
# enforced programmatically — so the *number* is notional and must never be a
# hard gate requirement (coordination plan §5.4; user directive 2026-06-16). A
# declaration may carry one of these markers instead of a number; the gate's
# real invariants stay (@status Supported + no direct global access), and the
# missing number raises NO warning. The canonical case is the FileMan DBS API
# (GETS^DIQ / $$GET1^DIQ / UPDATE^DIE / FILE^DIE / $$FIND1^DIC), for which no ICR
# number exists in the gold corpus by design.
NOTIONAL_MARKERS = frozenset({"DBS", "notional"})

# A reference to an external routine or global: ^NAME or label^NAME.
REF_RE = re.compile(r"\^(%?[A-Z][A-Z0-9]*)")
# A direct set/kill against a global (point 3): SET ^NAME(...) / KILL ^NAME(...).
GLOBAL_WRITE_RE = re.compile(r"\b(?:set|kill|s|k)\s+\^(%?[A-Z][A-Z0-9]*)\(", re.IGNORECASE)


def strip_comment(line: str) -> str:
    """Drop the trailing `;` comment from an M line (naive — good enough for the
    call-site scan, which only needs the code portion; string literals in
    m-stdlib's seam call sites do not contain `;`)."""
    # Respect quoted strings: only cut at a `;` that is outside double-quotes.
    out = []
    in_str = False
    for ch in line:
        if ch == '"':
            in_str = not in_str
        if ch == ";" and not in_str:
            break
        out.append(ch)
    return "".join(out)


def is_l4_name(name: str) -> bool:
    """True iff a `^`-reference name belongs to a VistA-native (L4) namespace."""
    up = name.upper()
    if up.startswith("STD") or up.startswith("VSL"):
        return False
    return any(up.startswith(p) for p in VISTA_API_PREFIXES)


def parse_icr_tag(body: str) -> dict:
    """Parse an `@icr …` doc-tag body into a registry entry.

    Body shape: `<icr> @call <ref> @status <s> @custodian <c> @source <src>`,
    where `<icr>` is either a number (a real DBIA) or a notional marker
    (`DBS`/`notional` — see NOTIONAL_MARKERS; the number is notional and never a
    gate requirement). Fields after the leading token are `@key value` segments;
    a value runs to the next `@key` (so multi-word statuses like "Controlled
    Subscription" work).
    """
    body = body.strip()
    # Leading ICR token: a number, or a notional marker.
    m = re.match(r"(?P<icr>\S+)\s*(?P<rest>.*)$", body, re.DOTALL)
    if not m or m.group("icr").startswith("@"):
        raise ValueError(f"@icr tag missing leading ICR number/marker: {body!r}")
    first = m.group("icr")
    if first.isdigit():
        icr_val: object = int(first)
    elif first in NOTIONAL_MARKERS:
        icr_val = first
    else:
        raise ValueError(
            f"@icr leading token {first!r} is neither a number nor a notional "
            f"marker {sorted(NOTIONAL_MARKERS)}: {body!r}"
        )
    entry: dict = {"icr": icr_val}
    rest = m.group("rest")
    # Split into @key value segments.
    for seg in re.split(r"(?=@[a-z])", rest):
        seg = seg.strip()
        if not seg.startswith("@"):
            continue
        key, _, val = seg[1:].partition(" ")
        val = val.strip()
        if key == "source":
            anchor = ""
            doc_key = val
            if "#" in val:
                doc_key, anchor = val.split("#", 1)
            entry["source"] = {"doc_key": doc_key.strip(), "anchor": anchor.strip()}
        else:
            entry[key] = val
    return entry


def build_registry() -> dict:
    """Walk src/ and collect @icr declarations keyed by module name."""
    registry: dict[str, list] = {}
    if not SRC_DIR.exists():
        return registry
    for path in sorted(SRC_DIR.glob("*.m")):
        module = path.stem.upper()
        lines = path.read_text(encoding="utf-8").splitlines()
        # Join continuation `; doc:` lines isn't needed here — the convention is
        # one @icr per declaration; but allow the tag to span the doc body.
        doc_buf = _collect_icr_bodies(lines)
        for body in doc_buf:
            entry = parse_icr_tag(body)
            registry.setdefault(module, []).append(entry)
    # Deterministic order.
    return {k: registry[k] for k in sorted(registry)}


def _collect_icr_bodies(lines: list[str]) -> list[str]:
    """Return the body text of every `@icr` doc-tag in a routine.

    A declaration starts on a `; doc: @icr …` line and absorbs subsequent
    indented `; doc:` continuation lines (so a long @source can wrap).
    """
    bodies: list[str] = []
    doc_re = re.compile(r"^\s+;\s*doc:\s?(?P<body>.*)$")
    cur: list[str] | None = None
    for line in lines:
        m = doc_re.match(line)
        if not m:
            if cur is not None:
                bodies.append(" ".join(cur).strip())
                cur = None
            continue
        body = m.group("body").rstrip()
        token = body.lstrip().split(None, 1)[0] if body.strip() else ""
        if token == "@icr":
            if cur is not None:
                bodies.append(" ".join(cur).strip())
            cur = [body.lstrip()[len("@icr"):].strip()]
        elif cur is not None and body[:1].isspace():
            cur.append(body.strip())
        elif cur is not None:
            bodies.append(" ".join(cur).strip())
            cur = None
    if cur is not None:
        bodies.append(" ".join(cur).strip())
    return bodies


def scan_call_sites() -> list[tuple[str, str, int, str]]:
    """Return (module, ref, lineno, kind) for every L4 call/global-write site.

    `kind` is "call" (a ^ROUTINE reference) or "global" (a direct set/kill ^GBL().
    Comment-aware: only the code portion of each line is scanned.
    """
    sites: list[tuple[str, str, int, str]] = []
    if not SRC_DIR.exists():
        return sites
    for path in sorted(SRC_DIR.glob("*.m")):
        module = path.stem.upper()
        for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = strip_comment(raw)
            if not code.strip():
                continue
            for m in GLOBAL_WRITE_RE.finditer(code):
                if is_l4_name(m.group(1)):
                    sites.append((module, m.group(1), n, "global"))
            for m in REF_RE.finditer(code):
                if is_l4_name(m.group(1)):
                    sites.append((module, m.group(1), n, "call"))
    return sites


def find_icr_violations(registry: dict, sites: list[tuple[str, str, int, str]]) -> list[str]:
    """Pure gate logic. Returns violation strings (empty == green)."""
    violations: list[str] = []

    # (a) Every declared ICR must carry an OK status.
    for module, entries in registry.items():
        for e in entries:
            status = e.get("status", "")
            if status not in OK_STATUSES:
                violations.append(
                    f"{module}: ICR {e.get('icr')} ({e.get('call', '?')}) has "
                    f"non-conformant status {status!r} (need one of {sorted(OK_STATUSES)})"
                )

    # Build the set of declared, conformant call refs per module.
    declared: dict[str, set[str]] = {}
    for module, entries in registry.items():
        for e in entries:
            if e.get("status") in OK_STATUSES and e.get("call"):
                declared.setdefault(module, set()).add(e["call"])

    # (b)/(c) Every L4 call/global-write site must be declared.
    for module, ref, lineno, kind in sites:
        mod_decl = declared.get(module, set())
        # A call site `^ROU` matches a declared `LABEL^ROU` or `^ROU`.
        matched = any(d == ref or d.endswith("^" + ref) for d in mod_decl)
        if not matched:
            what = "direct global write" if kind == "global" else "L4 call"
            violations.append(
                f"{module}:{lineno}: undeclared {what} ^{ref} — declare it with a "
                f"Supported/Controlled-Subscription @icr tag (no direct global access)"
            )
    return violations


# ── self-test ───────────────────────────────────────────────────────────

def self_test() -> int:
    failures: list[str] = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    # parse_icr_tag
    e = parse_icr_tag("2118 @call CALL^%ZISTCP @status Supported @custodian XU "
                      "@source XU/krn_8_0_dg_device_handler_ug#CALL^%ZISTCP")
    expect(e["icr"] == 2118, f"icr number wrong: {e}")
    expect(e["call"] == "CALL^%ZISTCP", f"call wrong: {e}")
    expect(e["status"] == "Supported", f"status wrong: {e}")
    expect(e["source"]["doc_key"] == "XU/krn_8_0_dg_device_handler_ug", f"source wrong: {e}")
    expect(e["source"]["anchor"] == "CALL^%ZISTCP", f"anchor wrong: {e}")

    # multi-word status
    e2 = parse_icr_tag("10063 @call $$EN^XPAR @status Controlled Subscription @custodian XT")
    expect(e2["status"] == "Controlled Subscription", f"multiword status wrong: {e2}")

    # notional ICR marker (FileMan DBS — no number exists; never a blocker)
    e3 = parse_icr_tag("DBS @call $$GET1^DIQ @status Supported @custodian DI "
                       "@source DI/fm22_2dg#get1diq-data-retriever-single-field")
    expect(e3["icr"] == "DBS", f"notional icr marker wrong: {e3}")
    expect(e3["call"] == "$$GET1^DIQ" and e3["status"] == "Supported", f"notional fields wrong: {e3}")
    # a notional-Supported call is conformant (green) — the number is not required
    expect(find_icr_violations({"VSLFS": [e3]}, [("VSLFS", "DIQ", 9, "call")]) == [],
           "notional Supported DBS call should be green")
    # a bogus leading token (typo) is rejected, not silently accepted
    try:
        parse_icr_tag("DBZ @call X^Y @status Supported")
        expect(False, "bogus icr marker should raise")
    except ValueError:
        pass

    # is_l4_name
    expect(is_l4_name("DIC") and is_l4_name("%ZISTCP") and is_l4_name("XPAR"), "L4 names misclassified")
    expect(is_l4_name("XPDUTL") and is_l4_name("%ZTLOAD"), "KIDS/TaskMan L4 names misclassified")
    expect(not is_l4_name("STDENV") and not is_l4_name("VSLCFG") and not is_l4_name("VSLENV"), "own namespaces flagged as L4")

    # strip_comment keeps quoted ;, drops real comment
    expect(strip_comment('  set x="a;b" ; note') == '  set x="a;b" ', "strip_comment wrong")

    # gate: empty → green
    expect(find_icr_violations({}, []) == [], "empty registry should be green")

    # gate: undeclared call → red
    v = find_icr_violations({}, [("VSLIO", "%ZISTCP", 42, "call")])
    expect(len(v) == 1 and "undeclared" in v[0], f"undeclared call should red: {v}")

    # gate: declared Supported → green
    reg = {"VSLIO": [{"icr": 2118, "call": "CALL^%ZISTCP", "status": "Supported"}]}
    expect(find_icr_violations(reg, [("VSLIO", "%ZISTCP", 42, "call")]) == [],
           "declared Supported call should be green")

    # gate: declared Private → red (bad status)
    regp = {"VSLIO": [{"icr": 9999, "call": "CALL^%ZISTCP", "status": "Private"}]}
    vp = find_icr_violations(regp, [("VSLIO", "%ZISTCP", 42, "call")])
    expect(any("non-conformant status" in x for x in vp), f"Private ICR should red: {vp}")

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("gen-icr self-test OK")
    return 0


def _write() -> int:
    registry = build_registry()
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    REGISTRY_PATH.write_text(
        json.dumps(registry, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    n = sum(len(v) for v in registry.values())
    print(f"wrote {REGISTRY_PATH.relative_to(REPO_ROOT)} ({n} ICR declarations across {len(registry)} modules)")
    return 0


def _check() -> int:
    registry = build_registry()
    if not REGISTRY_PATH.exists():
        if registry:
            print("ERROR: dist/icr-registry.json missing — run 'make icr' and commit.", file=sys.stderr)
            return 1
        committed = {}
    else:
        committed = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    if committed != registry:
        print("ERROR: dist/icr-registry.json drifted from src/ @icr tags — run 'make icr' and commit.",
              file=sys.stderr)
        return 1
    violations = find_icr_violations(registry, scan_call_sites())
    if violations:
        print("ERROR: ICR/DBIA-conformance violations (§5.4):", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1
    n = sum(len(v) for v in registry.values())
    print(f"check-icr: clean ({n} ICR declarations)")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="ICR / DBIA-conformance registry + gate.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    g.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.write:
        return _write()
    return _check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
