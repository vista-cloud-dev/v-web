#!/usr/bin/env python3
"""The namespace registry + gate (drift gate #4).

Spec: docs/vsl-msl/msl-vsl-coordination-implementation-plan.md §3 (registry-
      driven everything) + the VSL implementation plan T0b.3 (the namespace-
      registry gate; the M5/VSLBLD build-out tightens it further).

A repo declares the routine/global namespace prefixes it owns in
repo.meta.json:

    "namespaces": { "routines": ["STD"], "globals": ["STD"] }

`make namespaces` discovers the actual routine names + persistent globals from
src/ and writes dist/namespace-registry.json. `make check-namespaces`:

  1. drift: the committed registry equals a fresh discovery;
  2. every discovered routine lives under a declared routine prefix;
  3. every discovered persistent global lives under a declared global prefix
     (scratch globals — ^%*, ^$*, ^||*, ^mtmp*, ^CacheTemp*, ^IRIS.Temp* — are
     exempt);
  4. collision-free: the declared prefixes of one kind do not nest (no prefix is
     a prefix of another). Cross-repo collision is the org meta-gate's job.

Usage:
    python3 tools/gen_namespace_registry.py --write
    python3 tools/gen_namespace_registry.py --check
    python3 tools/gen_namespace_registry.py --self-test
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
META_PATH = REPO_ROOT / "repo.meta.json"
REGISTRY_PATH = DIST_DIR / "namespace-registry.json"

ROUTINE_LINE_RE = re.compile(r"^(?P<name>[A-Z%][A-Z0-9]*)\s+;")
GLOBAL_WRITE_RE = re.compile(r"\b(?:set|kill|s|k)\s+\^(?P<name>[A-Za-z%|$][A-Za-z0-9.]*)", re.IGNORECASE)

# Scratch / temp global namespaces that no application owns — exempt from the
# namespace rule (they are process-local or vendor-temp, not persistent app data).
SCRATCH_GLOBAL_RE = re.compile(r"^(%|\$|\||mtmp|CacheTemp|IRIS\.Temp|utility|tmp)", re.IGNORECASE)


def strip_comment(line: str) -> str:
    out, in_str = [], False
    for ch in line:
        if ch == '"':
            in_str = not in_str
        if ch == ";" and not in_str:
            break
        out.append(ch)
    return "".join(out)


def discover(src_dir: Path) -> dict:
    """Discover routine names + persistent globals written under src/."""
    routines: set[str] = set()
    globals_: set[str] = set()
    if src_dir.exists():
        for path in sorted(src_dir.glob("*.m")):
            lines = path.read_text(encoding="utf-8").splitlines()
            if lines:
                m = ROUTINE_LINE_RE.match(lines[0])
                routines.add(m.group("name") if m else path.stem.upper())
            for raw in lines:
                code = strip_comment(raw)
                for gm in GLOBAL_WRITE_RE.finditer(code):
                    name = gm.group("name")
                    if not SCRATCH_GLOBAL_RE.match(name):
                        globals_.add(name)
    return {"routines": sorted(routines), "globals": sorted(globals_)}


def load_declared(meta_path: Path) -> dict:
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    ns = meta.get("namespaces", {})
    return {"routines": list(ns.get("routines", [])), "globals": list(ns.get("globals", []))}


def build_registry(src_dir: Path = SRC_DIR, meta_path: Path = META_PATH) -> dict:
    return {"declared": load_declared(meta_path), "discovered": discover(src_dir)}


def find_namespace_violations(registry: dict) -> list[str]:
    """Pure gate logic. Returns violation strings (empty == green)."""
    violations: list[str] = []
    declared = registry["declared"]
    discovered = registry["discovered"]

    for kind in ("routines", "globals"):
        prefixes = declared.get(kind, [])
        # (4) collision-free: no declared prefix nests inside another.
        for i, a in enumerate(prefixes):
            for j, b in enumerate(prefixes):
                if i != j and a != b and b.startswith(a):
                    violations.append(f"declared {kind} namespace {a!r} nests {b!r} — prefixes must be disjoint")
        # (2)/(3) every discovered name under a declared prefix.
        for name in discovered.get(kind, []):
            if not any(name.startswith(p) for p in prefixes):
                violations.append(
                    f"{kind[:-1]} {name!r} is not under any declared namespace "
                    f"{prefixes} — register its prefix in repo.meta.json"
                )
    return violations


# ── self-test ───────────────────────────────────────────────────────────

def self_test() -> int:
    failures: list[str] = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    # clean
    reg = {"declared": {"routines": ["STD"], "globals": ["STD"]},
           "discovered": {"routines": ["STDARGS", "STDJSON"], "globals": ["STDLIB"]}}
    expect(find_namespace_violations(reg) == [], "clean registry should be green")

    # routine outside declared prefix → red
    reg2 = {"declared": {"routines": ["STD"], "globals": ["STD"]},
            "discovered": {"routines": ["STDARGS", "ZZNS"], "globals": []}}
    v = find_namespace_violations(reg2)
    expect(len(v) == 1 and "ZZNS" in v[0], f"unregistered routine should red: {v}")

    # global outside declared prefix → red
    reg3 = {"declared": {"routines": ["STD"], "globals": ["STD"]},
            "discovered": {"routines": [], "globals": ["XPAR"]}}
    expect(any("XPAR" in x for x in find_namespace_violations(reg3)), "unregistered global should red")

    # nested declared prefixes → red
    reg4 = {"declared": {"routines": ["ST", "STD"], "globals": []},
            "discovered": {"routines": [], "globals": []}}
    expect(any("nests" in x for x in find_namespace_violations(reg4)), "nested prefixes should red")

    # empty everything → green
    expect(find_namespace_violations({"declared": {"routines": [], "globals": []},
                                      "discovered": {"routines": [], "globals": []}}) == [],
           "empty should be green")

    # discover() over a synthetic dir
    import tempfile, shutil
    tmp = Path(tempfile.mkdtemp())
    try:
        (tmp / "STDFOO.m").write_text('STDFOO ; m.\n        set ^STDLIB("x")=1\n        set ^%scratch=2 ; exempt\n        quit\n')
        d = discover(tmp)
        expect(d["routines"] == ["STDFOO"], f"discover routines wrong: {d}")
        expect(d["globals"] == ["STDLIB"], f"discover globals wrong (scratch must be exempt): {d}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("gen_namespace_registry self-test OK")
    return 0


def _write() -> int:
    registry = build_registry()
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    REGISTRY_PATH.write_text(
        json.dumps(registry, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {REGISTRY_PATH.relative_to(REPO_ROOT)} "
          f"({len(registry['discovered']['routines'])} routines, "
          f"{len(registry['discovered']['globals'])} globals)")
    return 0


def _check() -> int:
    registry = build_registry()
    if not REGISTRY_PATH.exists():
        print("ERROR: dist/namespace-registry.json missing — run 'make namespaces' and commit.", file=sys.stderr)
        return 1
    committed = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    if committed != registry:
        print("ERROR: dist/namespace-registry.json drifted from src/ + repo.meta.json — "
              "run 'make namespaces' and commit.", file=sys.stderr)
        return 1
    violations = find_namespace_violations(registry)
    if violations:
        print("ERROR: namespace-registry violations:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1
    print(f"check-namespaces: clean ({len(registry['discovered']['routines'])} routines, "
          f"{len(registry['discovered']['globals'])} globals)")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Namespace registry + gate.")
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
