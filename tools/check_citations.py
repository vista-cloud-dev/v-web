#!/usr/bin/env python3
"""The citation-provenance drift gate (drift gate #3).

Spec: docs/vsl-msl/msl-vsl-coordination-implementation-plan.md §5.5
      (citation provenance — the VDL drift gate, →VDL).

The design is grounded in VDL gold-docs (ICR numbers, API contracts). Each
citation lives in an `@source <doc_key>#anchor` field (recorded in
dist/icr-registry.json, §5.4) together with a recorded `body_sha`. This gate, for
every cited doc_key, asserts against the vdocs gold corpus that it:

  1. still resolves in the corpus;
  2. is still is_latest=1 (gold) — a demotion is RED;
  3. has an unchanged body_sha — a changed hash ⟹ the documentation moved ⟹ the
     grounding must be re-reviewed and re-blessed; RED until then.

The corpus (~/data/vdocs) is a shared, mutating lake that is ABSENT in CI, so the
gate runs on a cadence: it SKIPS green when the corpus is unavailable and reds
only on real drift when the corpus is present. Empty citations → green (the
T0b.3 baseline). Honor the vdocs shared-lake rule (no `vdocs run`/stage races);
this gate only issues read-only SELECTs + file hashes.

Usage:
    python3 tools/check_citations.py --check        # the gate
    python3 tools/check_citations.py --self-test    # pure-logic unit tests
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DIST_DIR = REPO_ROOT / "dist"
ICR_REGISTRY_PATH = DIST_DIR / "icr-registry.json"

VDOCS_ROOT = Path(os.environ.get("VDOCS_ROOT", str(Path.home() / "data" / "vdocs")))
INDEX_DB = VDOCS_ROOT / "index.db"
NORMALIZED_DIR = VDOCS_ROOT / "documents" / "silver" / "text" / "03-normalized"


def collect_citations() -> list[dict]:
    """Gather cited sources from dist/icr-registry.json.

    Returns a list of {doc_key, anchor, body_sha} dicts (body_sha may be "" when
    a citation hasn't been blessed yet — then only resolve+gold are checked).
    """
    citations: list[dict] = []
    if not ICR_REGISTRY_PATH.exists():
        return citations
    registry = json.loads(ICR_REGISTRY_PATH.read_text(encoding="utf-8"))
    for entries in registry.values():
        for e in entries:
            src = e.get("source")
            if not src or not src.get("doc_key"):
                continue
            citations.append({
                "doc_key": src["doc_key"],
                "anchor": src.get("anchor", ""),
                "body_sha": e.get("body_sha", ""),
            })
    return citations


class Corpus:
    """Read-only view over the vdocs gold corpus (index.db + normalized bodies)."""

    def __init__(self, index_db: Path, normalized_dir: Path):
        self._con = sqlite3.connect(f"file:{index_db}?mode=ro", uri=True)
        self._norm = normalized_dir

    def resolve(self, doc_key: str) -> dict | None:
        row = self._con.execute(
            "SELECT doc_key, is_latest FROM documents WHERE doc_key = ?", (doc_key,)
        ).fetchone()
        if row is None:
            return None
        return {"doc_key": row[0], "is_latest": row[1]}

    def body_sha(self, doc_key: str) -> str | None:
        body = self._norm / doc_key / "body.md"
        if not body.exists():
            return None
        return "sha256:" + hashlib.sha256(body.read_bytes()).hexdigest()


def validate_citations(citations: list[dict], corpus) -> list[str]:
    """Pure gate logic. `corpus` answers resolve(doc_key) + body_sha(doc_key).

    Returns violation strings (empty == green).
    """
    violations: list[str] = []
    for c in citations:
        key = c["doc_key"]
        row = corpus.resolve(key)
        if row is None:
            violations.append(f"citation {key!r} no longer resolves in the corpus")
            continue
        if not row.get("is_latest"):
            violations.append(f"citation {key!r} is no longer gold (is_latest=0) — re-review")
            continue
        recorded = c.get("body_sha", "")
        if recorded:
            actual = corpus.body_sha(key)
            if actual is None:
                violations.append(f"citation {key!r}: normalized body.md missing — cannot verify body_sha")
            elif actual != recorded:
                violations.append(
                    f"citation {key!r}: body_sha changed ({recorded} -> {actual}) — "
                    f"the documentation moved; re-review and re-bless"
                )
    return violations


# ── self-test (pure logic, with a fake corpus) ──────────────────────────

class _FakeCorpus:
    def __init__(self, docs):
        # docs: {doc_key: {"is_latest": int, "body_sha": str|None}}
        self._docs = docs

    def resolve(self, key):
        d = self._docs.get(key)
        return None if d is None else {"doc_key": key, "is_latest": d["is_latest"]}

    def body_sha(self, key):
        return self._docs.get(key, {}).get("body_sha")


def self_test() -> int:
    failures: list[str] = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    fake = _FakeCorpus({
        "XU/good": {"is_latest": 1, "body_sha": "sha256:abc"},
        "XU/demoted": {"is_latest": 0, "body_sha": "sha256:abc"},
        "XU/moved": {"is_latest": 1, "body_sha": "sha256:zzz"},
    })

    # empty → green
    expect(validate_citations([], fake) == [], "empty citations should be green")

    # resolve + gold + matching sha → green
    expect(validate_citations([{"doc_key": "XU/good", "anchor": "", "body_sha": "sha256:abc"}], fake) == [],
           "good citation should be green")

    # missing doc_key → red
    v = validate_citations([{"doc_key": "XU/gone", "anchor": "", "body_sha": ""}], fake)
    expect(len(v) == 1 and "no longer resolves" in v[0], f"missing doc should red: {v}")

    # demoted from gold → red
    v = validate_citations([{"doc_key": "XU/demoted", "anchor": "", "body_sha": "sha256:abc"}], fake)
    expect(len(v) == 1 and "no longer gold" in v[0], f"demoted doc should red: {v}")

    # body_sha drift → red
    v = validate_citations([{"doc_key": "XU/moved", "anchor": "", "body_sha": "sha256:abc"}], fake)
    expect(len(v) == 1 and "body_sha changed" in v[0], f"moved doc should red: {v}")

    # no recorded body_sha → only resolve+gold checked (green for a gold doc)
    expect(validate_citations([{"doc_key": "XU/good", "anchor": "", "body_sha": ""}], fake) == [],
           "unblessed citation to a gold doc should be green")

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("check_citations self-test OK")
    return 0


def _check() -> int:
    citations = collect_citations()
    if not citations:
        print("check-citations: clean (0 citations)")
        return 0
    if not INDEX_DB.exists():
        print(f"check-citations: SKIP — vdocs corpus not present at {VDOCS_ROOT} "
              f"(cadence gate; {len(citations)} citations unverified here)")
        return 0
    corpus = Corpus(INDEX_DB, NORMALIZED_DIR)
    violations = validate_citations(citations, corpus)
    if violations:
        print("ERROR: citation-provenance violations (§5.5):", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1
    print(f"check-citations: clean ({len(citations)} citations verified against the gold corpus)")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Citation-provenance drift gate.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)
    if args.self_test:
        return self_test()
    return _check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
