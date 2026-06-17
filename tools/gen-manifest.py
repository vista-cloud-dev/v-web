#!/usr/bin/env python3
"""Generate dist/vsl-manifest.json from src/VSL*.m.

Spec: docs/guides/m-doc-grammar.md (the doc-comment grammar this consumes)
      docs/plans/discoverability-and-tooling-plan.md  § 3.2 (the schema)

The generator walks src/STD*.m, parses each routine into a module entry
plus per-label entries, and emits a single JSON manifest. The schema is
deliberately stable: downstream consumers (m-cli `m doc`, the VS Code
extension, the AI skill) depend on it.

This is a hand-rolled parser, not a tree-sitter pass — see
docs/tracking/module-tracker.md D3 for the deferred decision. v1 is
intentionally simple and forgiving: unknown tags are dropped, malformed
doc blocks degrade rather than crash, and labels without a `; doc:`
block (internal helpers) are excluded automatically.

Usage:
    python3 tools/gen-manifest.py                # writes dist/stdlib-manifest.json + dist/errors.json
    python3 tools/gen-manifest.py --self-test    # parse a synthetic fixture and check structure
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

def _relpath(path: Path) -> str:
    """Return path relative to REPO_ROOT when possible; fall back to str(path)."""
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


KNOWN_TAGS = {
    "@param", "@returns", "@raises", "@example",
    "@since", "@stable", "@see", "@deprecated", "@internal",
    "@seam",
}

# A `@seam` tag body: a seam name (the STD* module/contract it belongs to)
# optionally followed by a contract version `v<N>` (default 1). Examples:
#   @seam STDENV v2
#   @seam STDFS
# The seam name groups entry points into one versioned contract (§5.2 of the
# MSL⟷VSL coordination plan); the contract version bumps only when a seam
# signature changes incompatibly, enforced by the seam-snapshot bump-forcer.
SEAM_BODY_RE = re.compile(r"^(?P<name>[A-Za-z][A-Za-z0-9]*)(?:\s+v(?P<version>\d+))?\s*$")

# A label line at column 1: optional name, optional formal-list, optional inline comment.
# Examples:
#   parse(text,root)        ; Parse `text` into `root`. Returns 1/0.
#   lastError()     ; Return the message from the most recent failed parse.
#   parseFail
LABEL_RE = re.compile(
    r"^(?P<name>[A-Za-z][A-Za-z0-9]*)"
    r"(?:\((?P<formals>[^)]*)\))?"
    r"(?:\s+(?P<rest>.*))?$"
)

# A `; doc:` line. Allow leading whitespace (the routine indent), then `; doc:`,
# then a single optional space, then body.
DOC_LINE_RE = re.compile(r"^\s+;\s*doc:\s?(?P<body>.*)$")

# A regular comment line (not `; doc:`). Used for the routine-header block.
COMMENT_LINE_RE = re.compile(r"^\s+;\s?(?P<body>.*)$")

# A routine line: column 1, ALL-CAPS, then `;` and inline comment.
# YDB allows routine names up to 31 characters; use {0,30} as a sane
# upper bound that catches every m-stdlib `STD*` name (STDCOMPRESS at
# 11 chars is the longest today). The 8-char cap previously here was
# the M89 standard limit, which YDB and IRIS both relax.
ROUTINE_LINE_RE = re.compile(
    r"^(?P<name>[A-Z][A-Z0-9]{0,30})\s+;\s?(?P<rest>.*)$"
)

# A `set $ecode=",U-STDxxx-NAME,"` site (any quoting variant). Used to detect
# raised codes inside a label body for cross-checking against `@raises`.
ECODE_SITE_RE = re.compile(r"""\$ecode\s*=\s*["'],U-(?P<code>[A-Z0-9-]+),["']""", re.IGNORECASE)


def parse_module_file(path: Path) -> dict:
    """Parse one src/STDxxx.m into a module entry.

    Returns the module dict (without the wrapping {modules: {NAME: ...}}).
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    module = {
        "synopsis": "",
        "description": "",
        "errors": [],
        "labels": {},
        "source": {"file": _relpath(path), "line": 1},
    }

    if not lines:
        return module

    # Line 1: routine line with synopsis as inline comment.
    m = ROUTINE_LINE_RE.match(lines[0])
    if m:
        module_name = m.group("name")
        module["synopsis"] = m.group("rest").strip()
    else:
        # Tolerate a non-conforming first line: derive module name from filename.
        module_name = path.stem.upper()

    # Header block: contiguous comment-only lines following line 1, before the
    # first label. Stops at the first `quit` or non-comment line at module
    # scope (the `quit` that exits the routine head).
    header_body_lines: list[str] = []
    i = 1
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        # Stop at the routine-scope `quit` (which terminates the header).
        # In src/STD*.m the convention is `        quit` indented at the
        # routine's standard indent.
        stripped = line.strip()
        if stripped.lower() == "quit":
            i += 1
            break
        # Stop at a label line (col 1 alphanum).
        if line[0].isalpha() and not line.startswith(" ") and not line.startswith("\t"):
            break
        cm = COMMENT_LINE_RE.match(line)
        if cm:
            header_body_lines.append(cm.group("body").rstrip())
            i += 1
            continue
        # Anything else — skip silently (could be a setup line we don't care about)
        i += 1

    module["description"] = "\n".join(header_body_lines).strip()

    # Module tier: a header-block "doc: @tier <core|optional>" tag classifies
    # the module. "optional" means it needs a compiled $&/$ZF call-out library
    # to function and is excluded from the dependency-free core (and from the
    # default `make test`). Absent tag → "core".
    tier = "core"
    for body in header_body_lines:
        m_tier = re.match(r"doc:\s*@tier\s+(\S+)", body.strip())
        if m_tier:
            tier = m_tier.group(1).strip().lower()
            break
    module["tier"] = tier

    # Walk the rest of the file label-by-label.
    while i < len(lines):
        line = lines[i]
        # Label line: column-1 alphabetic identifier.
        if line and line[0].isalpha() and not line[0].isspace():
            label_name, formals, label_synopsis, label_start = parse_label_line(line, i)
            # Find label body bounds: from the next line until the next col-1 label or EOF.
            body_start = i + 1
            body_end = body_start
            while body_end < len(lines):
                ln = lines[body_end]
                if ln and ln[0].isalpha() and not ln[0].isspace():
                    break
                body_end += 1
            doc_lines = collect_doc_lines(lines, body_start, body_end)
            label_body = lines[body_start:body_end]
            entry = build_label_entry(
                module_name=module_name,
                label_name=label_name,
                formals=formals,
                synopsis=label_synopsis,
                doc_lines=doc_lines,
                label_body=label_body,
                source_path=_relpath(path),
                source_line=label_start + 1,  # 1-indexed
            )
            if entry is not None:
                module["labels"][label_name] = entry
                # Aggregate errors at module level.
                for r in entry.get("raises", []):
                    code = r.get("code")
                    if code and code not in module["errors"]:
                        module["errors"].append(code)
            i = body_end
        else:
            i += 1

    return module


def parse_label_line(line: str, lineno: int) -> tuple[str, list[str], str, int]:
    """Parse a label line into (name, formals, synopsis, start_line)."""
    # Split off the inline comment (`;`) — synopsis lives there.
    synopsis = ""
    code = line
    if ";" in line:
        # Find the first `;` that's not inside a string. For label lines
        # this is essentially always the literal `;` because formal-list
        # parens contain only identifiers.
        idx = line.index(";")
        code = line[:idx].rstrip()
        synopsis = line[idx + 1:].strip()
    m = LABEL_RE.match(code.strip())
    if not m:
        return ("", [], synopsis, lineno)
    name = m.group("name")
    formals_raw = m.group("formals") or ""
    formals = [f.strip() for f in formals_raw.split(",") if f.strip()]
    return (name, formals, synopsis, lineno)


def collect_doc_lines(lines: list[str], start: int, end: int) -> list[str]:
    """Return the `; doc:` block bodies (in order) within [start, end).

    Only the contiguous run of `; doc:` lines beginning at `start` (skipping
    blanks at the very top is fine) is taken — the doc block is the prefix,
    not random `; doc:` lines deeper in the body.
    """
    out: list[str] = []
    i = start
    # Allow leading blank lines (rare).
    while i < end and not lines[i].strip():
        i += 1
    while i < end:
        m = DOC_LINE_RE.match(lines[i])
        if not m:
            break
        out.append(m.group("body").rstrip())
        i += 1
    return out


def parse_doc_block(doc_lines: list[str]) -> dict:
    """Parse a doc block into structured tag dict + free-form description.

    Returns: {"tags": {tag_name: [body, body, ...]}, "description": str, "internal": bool}

    Rules (matching docs/guides/m-doc-grammar.md §3):
    - A line whose body's first token is `@<word>` starts a new tag.
    - A non-tag line whose body STARTS WITH WHITESPACE is continuation of the
      most recent tag (extends its body with a newline join).
    - A non-tag line whose body does NOT start with whitespace flushes the
      current tag (if any) and joins the free-form description.
    - An empty `; doc:` line flushes the current tag without ending the doc
      block — anything that follows starts fresh.

    The body strings passed in here have already had the trailing whitespace
    rstripped (collect_doc_lines did that) but their LEADING whitespace is
    preserved — that's the signal the rules above key on.
    """
    tags: dict[str, list[str]] = {}
    description_lines: list[str] = []
    current_tag: str | None = None
    current_buf: list[str] = []
    internal = False

    def flush_tag() -> None:
        nonlocal current_tag, current_buf
        if current_tag is not None:
            tags.setdefault(current_tag, []).append("\n".join(current_buf).rstrip())
        current_tag = None
        current_buf = []

    for raw in doc_lines:
        if not raw.strip():
            flush_tag()
            continue
        stripped = raw.lstrip()
        first_token = stripped.split(None, 1)[0]
        is_indented = bool(raw) and raw[0].isspace()

        if first_token in KNOWN_TAGS:
            flush_tag()
            if first_token == "@internal":
                internal = True
                # Body ignored; @internal is a flag, not a tag with content.
                continue
            current_tag = first_token
            tail = stripped[len(first_token):].lstrip()
            current_buf = [tail] if tail else []
        elif is_indented and current_tag is not None:
            # Indented continuation extends the current tag's body.
            current_buf.append(stripped)
        else:
            # Non-indented prose line (or indented line outside any tag) →
            # close the current tag and join into the description block.
            flush_tag()
            description_lines.append(stripped)

    flush_tag()

    return {
        "tags": tags,
        "description": "\n".join(description_lines).strip(),
        "internal": internal,
    }


def build_label_entry(
    *,
    module_name: str,
    label_name: str,
    formals: list[str],
    synopsis: str,
    doc_lines: list[str],
    label_body: list[str],
    source_path: str,
    source_line: int,
) -> dict | None:
    """Construct a label entry, or None if the label should be excluded."""
    if not doc_lines:
        # No `; doc:` block → internal helper. Skip.
        return None

    parsed = parse_doc_block(doc_lines)
    if parsed["internal"]:
        return None

    tags = parsed["tags"]

    # Determine extrinsic vs procedure: any `quit <expression>` in the body?
    is_extrinsic = False
    for ln in label_body:
        s = ln.strip()
        if s.lower().startswith("quit ") or s.lower().startswith("q "):
            after = s.split(None, 1)[1].strip() if " " in s else ""
            # Strip postcondition: `quit:cond expr`
            if after.startswith(":"):
                # Skip to the next whitespace-separated token.
                rest = after.split(None, 1)
                if len(rest) > 1 and rest[1] and not rest[1].startswith(";"):
                    is_extrinsic = True
                    break
            elif after and not after.startswith(";"):
                is_extrinsic = True
                break

    sig_form = "extrinsic" if is_extrinsic else "procedure"
    formals_str = ", ".join(formals)
    if is_extrinsic:
        signature = f"$${label_name}^{module_name}({formals_str})"
    else:
        signature = f"do {label_name}^{module_name}({formals_str})"

    # @param tags: parse "NAME [TYPE] BODY" shape leniently.
    params: list[dict] = []
    for body in tags.get("@param", []):
        parts = body.split(None, 2)
        if not parts:
            continue
        name = parts[0]
        if len(parts) == 1:
            params.append({"name": name, "type": "", "doc": ""})
        elif len(parts) == 2:
            # Could be "NAME BODY" with no TYPE — treat parts[1] as type if it
            # looks like a single token vocabulary word, else as doc.
            if parts[1].isalpha() and parts[1].islower():
                params.append({"name": name, "type": parts[1], "doc": ""})
            else:
                params.append({"name": name, "type": "", "doc": parts[1]})
        else:
            params.append({"name": name, "type": parts[1], "doc": parts[2]})

    # @returns: "TYPE BODY" or "BODY" alone.
    returns: dict | None = None
    if "@returns" in tags and tags["@returns"]:
        body = tags["@returns"][0]
        parts = body.split(None, 1)
        if len(parts) == 0:
            returns = {"type": "", "doc": ""}
        elif len(parts) == 1:
            returns = {"type": parts[0] if parts[0].isalpha() else "", "doc": "" if parts[0].isalpha() else parts[0]}
        else:
            returns = {"type": parts[0], "doc": parts[1]}

    # @raises: "CODE BODY" → list of {code, doc}.
    raises: list[dict] = []
    for body in tags.get("@raises", []):
        parts = body.split(None, 1)
        if not parts:
            continue
        code = parts[0]
        doc = parts[1] if len(parts) > 1 else ""
        raises.append({"code": code, "doc": doc})

    examples = list(tags.get("@example", []))
    since = tags["@since"][0] if "@since" in tags and tags["@since"] else ""
    stable = tags["@stable"][0] if "@stable" in tags and tags["@stable"] else ""
    see_raw = tags["@see"][0] if "@see" in tags and tags["@see"] else ""
    see_also = [s.strip() for s in see_raw.split(",") if s.strip()] if see_raw else []
    deprecated = tags["@deprecated"][0] if "@deprecated" in tags and tags["@deprecated"] else ""

    # @seam: marks this label as a side-effecting seam entry point. The body is
    # "NAME [v<N>]" — the seam contract it belongs to plus an optional contract
    # version (default 1). Aggregated into the manifest's top-level `seams` block.
    seam: dict | None = None
    if "@seam" in tags and tags["@seam"]:
        sm = SEAM_BODY_RE.match(tags["@seam"][0].strip())
        if sm:
            seam = {
                "name": sm.group("name"),
                "contract_version": int(sm.group("version")) if sm.group("version") else 1,
            }

    # Cross-check: codes that appear in `set $ecode=` sites inside the body.
    raised_in_body: list[str] = []
    for ln in label_body:
        for m in ECODE_SITE_RE.finditer(ln):
            code = "U-" + m.group("code")
            if code not in raised_in_body:
                raised_in_body.append(code)

    return {
        "form": sig_form,
        "signature": signature,
        "synopsis": synopsis,
        "params": params,
        "returns": returns,
        "raises": raises,
        "raised_in_body": raised_in_body,  # informational; useful for the lint rule (WA3)
        "examples": examples,
        "since": since,
        "stable": stable,
        "see_also": see_also,
        "deprecated": deprecated,
        "seam": seam,
        "description": parsed["description"],
        "source": {"file": source_path, "line": source_line},
    }


def read_stdlib_version() -> str:
    """Read the most-recent versioned entry from the changelog.

    Skips an `[Unreleased]` heading if present so the manifest's
    stdlib_version stays anchored to the last shipped tag while
    work accumulates against the next one.

    The changelog moved in commit 90e694e from `CHANGELOG.md` at the
    repo root to `docs/tracking/changelog.md` (per the four-bucket
    tracking-doc model). Look at the new path first, fall back to the
    old one for back-compat with checkouts predating that commit.
    """
    candidates = (
        REPO_ROOT / "docs" / "tracking" / "changelog.md",
        REPO_ROOT / "CHANGELOG.md",
    )
    changelog = next((p for p in candidates if p.exists()), None)
    if changelog is None:
        return ""
    for line in changelog.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^##\s*\[([^\]]+)\]", line)
        if m:
            v = m.group(1).strip()
            if v.lower() == "unreleased":
                continue
            return v
    return ""


def build_seams(modules: dict[str, dict]) -> dict:
    """Aggregate the `seams` contract view from per-label @seam tags.

    Returns `{ "<seam>": { "contract_version": N, "entry_points": [ {label,
    args, returns, raises}, ... ] } }`, keyed by seam name. Entry points are
    sorted by label and seams by name so the artifact is deterministic (a
    requirement for the drift gate). All entry points of one seam must declare
    the same contract version; a disagreement is a hard error (a forgotten bump
    on one of several entry points is exactly what the bump-forcer guards).
    """
    seams: dict[str, dict] = {}
    versions: dict[str, int] = {}
    for module_name in sorted(modules):
        labels = modules[module_name]["labels"]
        for label_name in sorted(labels):
            label = labels[label_name]
            seam = label.get("seam")
            if not seam:
                continue
            name = seam["name"]
            version = seam["contract_version"]
            if name in versions and versions[name] != version:
                raise ValueError(
                    f"seam {name!r} declares inconsistent contract_version "
                    f"({versions[name]} vs {version}) across its entry points — "
                    f"bump every entry point of a seam together"
                )
            versions[name] = version
            seams.setdefault(name, {"contract_version": version, "entry_points": []})
            seams[name]["entry_points"].append({
                "label": label["signature"],
                "args": list(label.get("params", [])),
                "returns": label.get("returns"),
                "raises": list(label.get("raises", [])),
            })
    for name in seams:
        seams[name]["entry_points"].sort(key=lambda e: e["label"])
    return {name: seams[name] for name in sorted(seams)}


def build_manifest() -> tuple[dict, dict]:
    """Walk src/ and produce (manifest, errors_index)."""
    modules: dict[str, dict] = {}
    errors_index: dict[str, dict] = {}

    for path in sorted(SRC_DIR.glob("VSL*.m")):
        module = parse_module_file(path)
        # Re-derive the module name from the routine line; fall back to filename stem.
        # parse_module_file already normalises this internally.
        name_from_first_line = ""
        first_line = path.read_text(encoding="utf-8").splitlines()
        if first_line:
            m = ROUTINE_LINE_RE.match(first_line[0])
            if m:
                name_from_first_line = m.group("name")
        module_name = name_from_first_line or path.stem.upper()
        modules[module_name] = module

        # Build the errors inverted index from each label's raises.
        for label_name, label in module["labels"].items():
            for r in label.get("raises", []):
                code = r["code"]
                bucket = errors_index.setdefault(code, {"module": module_name, "labels": []})
                if label_name not in bucket["labels"]:
                    bucket["labels"].append(label_name)

    # No `generated_at` field by design — it would change every run and
    # would force the WA5 manifest-check gate to fail spuriously. The
    # version of the source the manifest was generated from is captured
    # by `stdlib_version`; the file's git history captures the rest.
    manifest = {
        "stdlib_version": read_stdlib_version(),
        "modules": modules,
        "errors": errors_index,
        "seams": build_seams(modules),
    }
    return manifest, errors_index


def write_outputs(manifest: dict, errors_index: dict) -> None:
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    manifest_path = DIST_DIR / "vsl-manifest.json"
    errors_path = DIST_DIR / "vsl-errors.json"
    # Pretty-print with stable key order so diffs read cleanly.
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=False, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    errors_path.write_text(
        json.dumps(errors_index, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"wrote {manifest_path.relative_to(REPO_ROOT)} "
        f"({len(manifest['modules'])} modules, "
        f"{sum(len(m['labels']) for m in manifest['modules'].values())} public labels)"
    )
    print(f"wrote {errors_path.relative_to(REPO_ROOT)} ({len(errors_index)} error codes)")


def self_test() -> int:
    """Parse a tiny synthetic fixture and check structure. Returns exit code."""
    fixture = """STDFOO   ; m-stdlib — fixture for self-test.
        ;
        ; A toy module used only by tools/gen-manifest.py --self-test.
        ;
        quit
        ;
greet(who)      ; Say hi to `who` and return the greeting.
        ; doc: @param who    string  the name to greet
        ; doc: @returns      string  the rendered greeting
        ; doc: @example      write $$greet^STDFOO("world")  ; "hello, world"
        ; doc: @since        v0.1.0
        ; doc: @stable       stable
        ; doc: @see          $$bye^STDFOO
        ; doc: @seam         STDFOO v2
        ; doc: A free-form description. Continuation prose lives here.
        quit "hello, "_who
        ;
internalHelper  ; Internal — not part of public API.
        ; doc: @internal
        ; doc: This is documented for maintainers but should not appear in the manifest.
        quit
        ;
silentHelper    ; No doc block → also excluded.
        quit
"""
    import tempfile, shutil
    tmp = Path(tempfile.mkdtemp())
    try:
        path = tmp / "STDFOO.m"
        path.write_text(fixture, encoding="utf-8")
        # Re-route SRC_DIR for this run.
        global SRC_DIR
        original = SRC_DIR
        SRC_DIR = tmp
        try:
            mod = parse_module_file(path)
        finally:
            SRC_DIR = original

        failures: list[str] = []

        def expect(cond, msg):
            if not cond:
                failures.append(msg)

        expect(mod["synopsis"] == "m-stdlib — fixture for self-test.",
               f"module synopsis wrong: {mod['synopsis']!r}")
        expect("greet" in mod["labels"], "greet label missing")
        expect("internalHelper" not in mod["labels"], "internalHelper should be excluded (@internal)")
        expect("silentHelper" not in mod["labels"], "silentHelper should be excluded (no doc block)")

        if "greet" in mod["labels"]:
            g = mod["labels"]["greet"]
            expect(g["form"] == "extrinsic", f"greet should be extrinsic, got {g['form']}")
            expect(g["signature"] == "$$greet^STDFOO(who)",
                   f"signature wrong: {g['signature']!r}")
            expect(g["synopsis"] == "Say hi to `who` and return the greeting.",
                   f"label synopsis wrong: {g['synopsis']!r}")
            expect(len(g["params"]) == 1 and g["params"][0]["name"] == "who",
                   f"params wrong: {g['params']}")
            expect(g["params"][0]["type"] == "string",
                   f"param type wrong: {g['params'][0]}")
            expect(g["returns"] is not None and g["returns"]["type"] == "string",
                   f"returns wrong: {g['returns']}")
            expect(g["since"] == "v0.1.0", f"since wrong: {g['since']!r}")
            expect(g["stable"] == "stable", f"stable wrong: {g['stable']!r}")
            expect("$$bye^STDFOO" in g["see_also"], f"see_also wrong: {g['see_also']}")
            expect(len(g["examples"]) == 1, f"examples count wrong: {g['examples']}")
            expect(g["seam"] is not None and g["seam"]["name"] == "STDFOO"
                   and g["seam"]["contract_version"] == 2,
                   f"seam wrong: {g['seam']}")
            expect(g["description"].startswith("A free-form description"),
                   f"description wrong: {g['description']!r}")

        # Seam aggregation: build_seams over a one-module dict.
        seams = build_seams({"STDFOO": mod})
        expect("STDFOO" in seams, "STDFOO seam missing from build_seams")
        if "STDFOO" in seams:
            expect(seams["STDFOO"]["contract_version"] == 2,
                   f"seam contract_version wrong: {seams['STDFOO']}")
            eps = seams["STDFOO"]["entry_points"]
            expect(len(eps) == 1 and eps[0]["label"] == "$$greet^STDFOO(who)",
                   f"seam entry_points wrong: {eps}")

        if failures:
            for f in failures:
                print(f"FAIL: {f}", file=sys.stderr)
            return 1
        print(f"self-test OK ({len([m for m in mod['labels']])} public labels in fixture)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Generate dist/stdlib-manifest.json + dist/errors.json from src/STD*.m.")
    p.add_argument("--self-test", action="store_true", help="Run the inline parser self-test and exit.")
    args = p.parse_args(argv)

    if args.self_test:
        return self_test()

    if not SRC_DIR.exists():
        print(f"src/ not found at {SRC_DIR}", file=sys.stderr)
        return 2

    manifest, errors_index = build_manifest()
    write_outputs(manifest, errors_index)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
