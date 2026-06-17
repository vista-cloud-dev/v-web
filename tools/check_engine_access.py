#!/usr/bin/env python3
"""Engine-access gate — the committed-artifact backstop for the transport monopoly.

Spec: org CLAUDE.md §"m/v waterline" → "Engine access (dev/test/CI/agent)".

All work against a live M engine MUST go through the m-driver-sdk → m-ydb/m-iris
stack via the `m` toolchain (`m test --docker <c>`, `m coverage`, `m vista exec`,
or `mdriver.Client`). This gate red-gates any committed *executable* artifact
(Makefile, tests/, scripts/, *.sh) that hand-rolls engine access instead —
`docker exec … mumps|iris session`, a bare `mumps -direct`, `$gtm_dist/mumps`,
`csession`, etc. (It is the CI counterpart to the real-time PreToolUse hook
`~/scripts/lib/engine-stack-guard.sh`.)

Docs are NOT scanned — design notes legitimately quote the forbidden recipe as
"exploration only". A deliberate, unavoidable exception carries a `stack-exempt`
marker on the offending line.

Usage:
    python3 tools/check_engine_access.py --check       # the CI gate
    python3 tools/check_engine_access.py --self-test   # pure-logic unit tests
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Executable artifacts that could reach an engine. Docs/ deliberately excluded.
SCAN_FILES = ["Makefile"]
SCAN_DIRS = ["tests", "scripts"]
SCAN_GLOBS = ["*.sh"]

# Hand-rolled engine access = a sidestep of the driver stack.
FORBIDDEN = [
    re.compile(r"docker\s+(?:-\S+\s+)*exec\b"),      # docker exec into a container
    re.compile(r"\biris\s+session\b"),               # IRIS M shell
    re.compile(r"\bcsession\b"),                     # legacy Caché shell
    re.compile(r"\bmumps\s+-(?:direct|dir|r)\b"),    # GT.M/YDB direct/run
    re.compile(r"\$gtm_dist\b"),                     # raw GT.M dist invocation
    re.compile(r"\$ydb_dist/(?:yottadb|mumps)\b"),   # raw YDB dist invocation
]

ALLOW_MARKER = "stack-exempt"


def scan_text(text: str) -> list[tuple[int, str]]:
    """Return (lineno, line) for each offending line (1-based). Pure function."""
    hits: list[tuple[int, str]] = []
    for i, line in enumerate(text.splitlines(), 1):
        if ALLOW_MARKER in line:
            continue
        if any(rx.search(line) for rx in FORBIDDEN):
            hits.append((i, line.strip()))
    return hits


def _targets() -> list[Path]:
    out: list[Path] = []
    for f in SCAN_FILES:
        p = REPO_ROOT / f
        if p.is_file():
            out.append(p)
    for d in SCAN_DIRS:
        base = REPO_ROOT / d
        if base.is_dir():
            out.extend(p for p in base.rglob("*") if p.is_file())
    for g in SCAN_GLOBS:
        out.extend(REPO_ROOT.glob(g))
    # de-dup, stable
    seen, uniq = set(), []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def check() -> int:
    violations: list[str] = []
    for path in _targets():
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, line in scan_text(text):
            violations.append(f"{path.relative_to(REPO_ROOT)}:{lineno}: {line}")
    if violations:
        print("ERROR: hand-rolled engine access (sidesteps the m-driver-sdk stack):",
              file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        print("Use `m test --docker <c>` / `m vista exec` / `mdriver.Client` instead "
              "(org CLAUDE.md §waterline). A deliberate one-off may carry a "
              "`stack-exempt` marker on the line.", file=sys.stderr)
        return 1
    print(f"check-engine-access: clean ({len(_targets())} files scanned)")
    return 0


def self_test() -> int:
    fails: list[str] = []

    def expect(cond, msg):
        if not cond:
            fails.append(msg)

    expect(scan_text("docker exec -i vehu bash -lc 'mumps -direct'"),
           "raw docker exec should be flagged")
    expect(scan_text("\tdocker exec foia-t12 iris session IRIS"),
           "iris session should be flagged")
    expect(scan_text("X=$gtm_dist/mumps"), "$gtm_dist should be flagged")
    expect(not scan_text("\t$(M) test --engine ydb --docker vehu $(TESTS)"),
           "approved `m test --docker` must NOT be flagged")
    expect(not scan_text("docker ps --filter name=vehu"),
           "docker ps must NOT be flagged")
    expect(not scan_text("docker run -d --name foia-t12 foia:latest"),
           "docker run (lifecycle) must NOT be flagged")
    expect(not scan_text("docker exec vehu echo ok  # stack-exempt: probe"),
           "stack-exempt marker must allow the line")

    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("check_engine_access self-test OK")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Engine-access transport-monopoly gate.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="Run the CI gate.")
    g.add_argument("--self-test", action="store_true", help="Run the pure-logic self-test.")
    args = p.parse_args(argv)
    return self_test() if args.self_test else check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
