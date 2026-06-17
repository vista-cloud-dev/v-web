#!/usr/bin/env python3
"""The MSL seam-contract pin gate (the v-stdlib → m-stdlib cross-repo drift gate).

Spec: docs/vsl-msl/msl-vsl-coordination-implementation-plan.md §5.2 + §6
      (VSL pins a frozen MSL release and asserts its seam signatures; the
      analogue of m-stdlib's own seam_contract.py, but pointed UP the
      dependency edge v -> m).

The seam contract is owned by m-stdlib (MSL): it tags a library release
(`msl_ref`, a git tag like `v0.6.0`) whose `dist/seam-snapshot.json` is the
frozen `seams` block. v-stdlib (VSL) consumes that base and must pin the exact
contract it built against, so "MSL changed a seam and VSL didn't notice" is a
red CI gate, not a production surprise (§5.2).

This is VSL T0b.4 ("freeze seam contract v1 — tag MSL; v-stdlib pins it"). The
pin lives in `dist/msl-seam-pin.json`:

    { "msl_ref": "v0.6.0", "seams": { <frozen copy of MSL's seams block> } }

`msl_ref` is the one hand-set knob (which MSL tag to pin); `seams` is the
synced copy. The gate two ways:

  1. well-formedness: `msl_ref` is a non-empty string and `seams` is a dict of
     valid seam records ({contract_version: int, entry_points: list});
  2. drift: when the pinned MSL contract is REACHABLE, the committed `seams`
     must equal MSL's `dist/seam-snapshot.json` AT `msl_ref` — a divergence
     means MSL moved the contract under us; re-sync (`--write`) and re-review
     before bumping the pin. RED on mismatch.

Reachability today = the sibling m-stdlib checkout (`$MSTDLIB`, default
~/vista-cloud-dev/m-stdlib) at the tagged ref, read with `git show`. When the
tag or the sibling is ABSENT (a fresh CI clone without the MSL repo), the gate
SKIPS green — the same cadence-degradation as check-citations. The network
fetch-at-tag path (fetch the published manifest in CI) is the T1.1 extension;
T0b.4 establishes the pin + the offline assertion against the empty baseline.

Usage:
    python3 tools/msl_seam_pin.py --write       # sync dist/msl-seam-pin.json from MSL @ msl_ref
    python3 tools/msl_seam_pin.py --check        # the CI gate (well-formedness + drift)
    python3 tools/msl_seam_pin.py --self-test    # pure-logic unit tests
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DIST_DIR = REPO_ROOT / "dist"
PIN_PATH = DIST_DIR / "msl-seam-pin.json"

# The MSL (m-stdlib) checkout to read the pinned contract from. Override with
# $MSTDLIB (same knob the Makefile uses to stage STDASSERT).
MSTDLIB = Path(os.environ.get("MSTDLIB", str(Path.home() / "vista-cloud-dev" / "m-stdlib")))
MSL_SNAPSHOT_REL = "dist/seam-snapshot.json"


# ── pure logic (unit-tested) ─────────────────────────────────────────────

def validate_pin(pin: object) -> list[str]:
    """Return well-formedness violations for a pin record."""
    violations: list[str] = []
    if not isinstance(pin, dict):
        return ["pin must be a JSON object with 'msl_ref' and 'seams'"]
    ref = pin.get("msl_ref")
    if not isinstance(ref, str) or not ref.strip():
        violations.append("'msl_ref' must be a non-empty string (the pinned MSL git tag)")
    seams = pin.get("seams")
    if not isinstance(seams, dict):
        violations.append("'seams' must be an object (name -> seam record)")
        return violations
    for name, rec in seams.items():
        if not isinstance(rec, dict):
            violations.append(f"seam {name!r}: record must be an object")
            continue
        if not isinstance(rec.get("contract_version"), int):
            violations.append(f"seam {name!r}: 'contract_version' must be an integer")
        if not isinstance(rec.get("entry_points"), list):
            violations.append(f"seam {name!r}: 'entry_points' must be a list")
    return violations


def find_drift(pinned_seams: dict, msl_seams: dict) -> list[str]:
    """Return drift violations between the pinned copy and MSL's contract."""
    if pinned_seams == msl_seams:
        return []
    violations: list[str] = []
    for name in sorted(set(pinned_seams) | set(msl_seams)):
        if name not in msl_seams:
            violations.append(f"seam {name!r} is pinned but no longer in the MSL contract")
        elif name not in pinned_seams:
            violations.append(f"seam {name!r} is new in the MSL contract but not pinned")
        elif pinned_seams[name] != msl_seams[name]:
            violations.append(f"seam {name!r} signature changed in MSL vs the pin")
    if not violations:  # equal-keys but a non-seam-keyed difference
        violations.append("pinned 'seams' differs from the MSL contract at msl_ref")
    return violations


# ── MSL contract reachability ────────────────────────────────────────────

def read_msl_seams(ref: str) -> dict | None:
    """MSL's seam-snapshot AT `ref` from the sibling checkout, or None if unreachable."""
    if not (MSTDLIB / ".git").exists():
        return None
    try:
        out = subprocess.run(
            ["git", "-C", str(MSTDLIB), "show", f"{ref}:{MSL_SNAPSHOT_REL}"],
            capture_output=True, text=True, check=True,
        )
        return json.loads(out.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


# ── self-test (pure logic) ───────────────────────────────────────────────

def self_test() -> int:
    failures: list[str] = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    # validate_pin
    expect(validate_pin({"msl_ref": "v0.6.0", "seams": {}}) == [],
           "a well-formed empty pin should validate")
    expect(validate_pin({"seams": {}}) and validate_pin("x"),
           "a missing ref / non-dict pin should be a violation")
    expect(validate_pin({"msl_ref": "", "seams": {}}),
           "an empty ref should be a violation")
    good_seam = {"STDENV": {"contract_version": 1, "entry_points": [{"label": "$$get^STDENV(name)"}]}}
    expect(validate_pin({"msl_ref": "v1.0.0", "seams": good_seam}) == [],
           "a well-formed populated pin should validate")
    expect(validate_pin({"msl_ref": "v1.0.0", "seams": {"X": {"contract_version": "1", "entry_points": []}}}),
           "a non-int contract_version should be a violation")

    # find_drift
    expect(find_drift({}, {}) == [], "empty == empty is no drift (the T0b.4 baseline)")
    expect(find_drift(good_seam, good_seam) == [], "identical contracts is no drift")
    expect(len(find_drift({}, good_seam)) == 1, "a new MSL seam not pinned is drift")
    expect(len(find_drift(good_seam, {})) == 1, "a pinned seam dropped from MSL is drift")
    changed = {"STDENV": {"contract_version": 2, "entry_points": [{"label": "$$get^STDENV(name,default)"}]}}
    expect(len(find_drift(good_seam, changed)) == 1, "a changed signature is drift")

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("msl_seam_pin self-test OK")
    return 0


# ── CLI ──────────────────────────────────────────────────────────────────

def _load_pin() -> dict:
    if not PIN_PATH.exists():
        return {}
    return json.loads(PIN_PATH.read_text(encoding="utf-8"))


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="MSL seam-contract pin gate (VSL -> MSL).")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true", help="Sync dist/msl-seam-pin.json from MSL @ msl_ref.")
    g.add_argument("--check", action="store_true", help="Run the well-formedness + drift gate.")
    g.add_argument("--self-test", action="store_true", help="Run the pure-logic self-test.")
    args = p.parse_args(argv)

    if args.self_test:
        return self_test()

    pin = _load_pin()
    ref = pin.get("msl_ref")

    if args.write:
        if not isinstance(ref, str) or not ref.strip():
            print(f"ERROR: set 'msl_ref' (the pinned MSL tag) in {PIN_PATH.name} first.", file=sys.stderr)
            return 1
        msl_seams = read_msl_seams(ref)
        if msl_seams is None:
            print(f"ERROR: MSL contract at {ref!r} is unreachable (checkout $MSTDLIB={MSTDLIB} "
                  f"and ensure the tag exists).", file=sys.stderr)
            return 1
        DIST_DIR.mkdir(parents=True, exist_ok=True)
        PIN_PATH.write_text(
            json.dumps({"msl_ref": ref, "seams": msl_seams}, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"wrote {PIN_PATH.relative_to(REPO_ROOT)} (pinned MSL {ref}, {len(msl_seams)} seams)")
        return 0

    # --check
    if not PIN_PATH.exists():
        print(f"ERROR: {PIN_PATH.relative_to(REPO_ROOT)} missing — run 'make pin' and commit.", file=sys.stderr)
        return 1

    violations = validate_pin(pin)
    if violations:
        print(f"ERROR: {PIN_PATH.name} is malformed:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1

    msl_seams = read_msl_seams(ref)
    if msl_seams is None:
        print(f"check-msl-pin: SKIP — MSL contract at {ref!r} unreachable "
              f"($MSTDLIB={MSTDLIB}); pin well-formed ({len(pin['seams'])} seams).")
        return 0

    drift = find_drift(pin["seams"], msl_seams)
    if drift:
        print(f"ERROR: pinned MSL seam contract drifted from {ref!r} (§5.2) — "
              f"re-review and run 'make pin':", file=sys.stderr)
        for d in drift:
            print(f"  - {d}", file=sys.stderr)
        return 1

    print(f"check-msl-pin: clean (pinned MSL {ref}, {len(pin['seams'])} seams match)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
