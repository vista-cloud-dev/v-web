#!/usr/bin/env python3
"""The seam-contract snapshot + bump-forcer (drift gate #1).

Spec: docs/vsl-msl/msl-vsl-coordination-implementation-plan.md §5.2 + §9
      (the `seams` block in stdlib-manifest.json + the STDSNAP bump-forcer).

The `seams` block is generated into dist/stdlib-manifest.json from `@seam`
doc-tags (see tools/gen-manifest.py). This tool maintains a *projection* of
just that block — dist/seam-snapshot.json — and gates it two ways:

  1. drift: the committed snapshot must equal a fresh regeneration from source
     (the same regenerate-and-diff model as `make manifest-check`);
  2. bump-forcer: any *existing* seam whose normalized entry-point record
     changes vs the committed (git HEAD) snapshot MUST also raise its
     `contract_version` in the same commit — a signature change cannot merge
     silently (§9). New seams are fine; a version that stays equal or moves
     backward across a record change is RED.

Usage:
    python3 tools/seam_contract.py --write        # regenerate dist/seam-snapshot.json
    python3 tools/seam_contract.py --check        # the CI gate (drift + bump-forcer)
    python3 tools/seam_contract.py --self-test    # pure bump-forcer unit tests
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DIST_DIR = REPO_ROOT / "dist"
SNAPSHOT_PATH = DIST_DIR / "seam-snapshot.json"


def _records(seam: dict) -> object:
    """The version-independent part of a seam (everything but contract_version)."""
    return seam.get("entry_points", [])


def find_bump_violations(old: dict, new: dict) -> list[str]:
    """Return human-readable violations for seams that changed without a bump.

    `old` and `new` are seam-snapshot dicts (name → {contract_version,
    entry_points}). A violation is raised for a seam present in BOTH whose
    entry-point records differ while its contract_version did not strictly
    increase.
    """
    violations: list[str] = []
    for name in sorted(set(old) & set(new)):
        if _records(old[name]) == _records(new[name]):
            continue  # signature unchanged — no bump required.
        old_v = old[name].get("contract_version", 1)
        new_v = new[name].get("contract_version", 1)
        if new_v <= old_v:
            violations.append(
                f"seam {name!r} signature changed but contract_version did not "
                f"increase ({old_v} -> {new_v}); bump it in the same commit"
            )
    return violations


# ── self-test (pure bump-forcer logic) ──────────────────────────────────

def self_test() -> int:
    def seam(version, *labels):
        return {
            "contract_version": version,
            "entry_points": [{"label": lbl, "args": [], "returns": None, "raises": []} for lbl in labels],
        }

    failures: list[str] = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    # 1. Unchanged seam → no violation.
    base = {"STDENV": seam(1, "$$get^STDENV(name)")}
    expect(find_bump_violations(base, base) == [],
           "unchanged seam should not be a violation")

    # 2. Signature changed, version NOT bumped → violation.
    changed = {"STDENV": seam(1, "$$get^STDENV(name,default)")}
    v = find_bump_violations(base, changed)
    expect(len(v) == 1 and "STDENV" in v[0],
           f"changed-without-bump should be one STDENV violation, got {v}")

    # 3. Signature changed AND version bumped → no violation.
    bumped = {"STDENV": seam(2, "$$get^STDENV(name,default)")}
    expect(find_bump_violations(base, bumped) == [],
           "changed-with-bump should be clean")

    # 4. Version moved BACKWARD on a changed record → violation.
    backward = {"STDENV": seam(1, "$$get^STDENV(name,default)")}
    prev = {"STDENV": seam(2, "$$get^STDENV(name)")}
    expect(len(find_bump_violations(prev, backward)) == 1,
           "a backward version on a changed seam should be a violation")

    # 5. Brand-new seam (only in new) → no violation.
    expect(find_bump_violations({}, base) == [],
           "a newly-added seam should not be a violation")

    # 6. Empty → empty → no violation (the T0b.3 green baseline).
    expect(find_bump_violations({}, {}) == [],
           "empty snapshots should be clean")

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("seam_contract self-test OK")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Seam-contract snapshot + bump-forcer.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true", help="Regenerate dist/seam-snapshot.json from source.")
    g.add_argument("--check", action="store_true", help="Run the drift + bump-forcer gate.")
    g.add_argument("--self-test", action="store_true", help="Run the pure bump-forcer self-test.")
    args = p.parse_args(argv)

    if args.self_test:
        return self_test()

    # --write / --check need the generator's seam view.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import importlib
    gen = importlib.import_module("gen-manifest".replace("-", "_")) if False else None  # noqa
    # gen-manifest.py is not importable by that name (hyphen); load it directly.
    import importlib.util
    spec = importlib.util.spec_from_file_location("gen_manifest", Path(__file__).resolve().parent / "gen-manifest.py")
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    manifest, _ = gen.build_manifest()
    fresh = manifest["seams"]

    if args.write:
        DIST_DIR.mkdir(parents=True, exist_ok=True)
        SNAPSHOT_PATH.write_text(
            json.dumps(fresh, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"wrote {SNAPSHOT_PATH.relative_to(REPO_ROOT)} ({len(fresh)} seams)")
        return 0

    # --check
    if not SNAPSHOT_PATH.exists():
        print("ERROR: dist/seam-snapshot.json missing — run 'make seams' and commit.", file=sys.stderr)
        return 1
    committed = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))

    # (1) drift: the committed snapshot must equal a fresh regeneration.
    if committed != fresh:
        print("ERROR: dist/seam-snapshot.json drifted from src/ @seam tags — "
              "run 'make seams' and commit.", file=sys.stderr)
        return 1

    # (2) bump-forcer: compare the committed snapshot against git HEAD's copy;
    # a changed seam record must carry a strictly higher contract_version.
    head = _git_head_snapshot()
    violations = find_bump_violations(head, committed)
    if violations:
        print("ERROR: seam signature changed without a contract_version bump (§9):", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1

    print(f"check-seams: clean ({len(committed)} seams)")
    return 0


def _git_head_snapshot() -> dict:
    """Read dist/seam-snapshot.json as committed at HEAD ({} if absent/new file)."""
    try:
        out = subprocess.run(
            ["git", "show", "HEAD:dist/seam-snapshot.json"],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True,
        )
        return json.loads(out.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return {}


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
