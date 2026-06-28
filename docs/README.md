# v-web docs

`v-web` is the **VistA Web Services** package (`VWEB*`): the inbound socket
adapter that drives the m-stdlib `STDHTTPD` server framework over a real socket.
Layer `v` (VistA-coupled), consuming m-stdlib (`STDHTTPD`/`STDHTTPMSG`/`STDNET`/
`STDJSON`/`STDJWT`) and v-stdlib (`VSLTASK`/`VSLCFG`/`VSLENV`/`VSLFS`/`VSLSEC`)
upward.

## Layout

| Folder | Holds |
|---|---|
| `implementation-tracker.md` | **live** Tier-D status tracker for the M6 capstone + Phase-4 work |
| `memory/` | auto-memory — durable gotchas/invariants only (not a per-increment journal) |
| `archive/` | retired docs from this repo (executed kickoff prompts, etc.) — never deleted |

(No `guides/`, `modules/`, or `design/` yet — added when there's content for them.)

## Key docs

- **[implementation-tracker.md](implementation-tracker.md)** — the milestone
  tracker. M6.1–M6.6 (HTTP codec → framework → listener → FHIR `/Patient` → auth →
  end-to-end smoke; **M6 capstone CLOSED**) and Phase-4/M3 (the `VWEBT` traffic-tap
  operator console). Next: Phase 5 / M4 (GA).
- **memory/v-web-durable-gotchas.md** — the durable engineering lessons
  (M/MUMPS call conventions, STDHTTPD/STDJSON seams, byte-mode, auth posture,
  test-harness traps, live-VistA portability).
- **memory/stdnet-iris-crlf-rawread-gap.md** — the two STDNET-on-IRIS socket
  gaps the serve vertical found (both fixed in m-stdlib; why the MSL pin is
  v0.12.2). IRIS-portability reference.
- **memory/phase4-traffic-console.md** — the `VWEBT` RPC+HL7→S3 tap operator
  console (Phase-4/M3).

## Doc gate

Intra-repo markdown link/anchor integrity only (the shared `doc-framework`
`link-check.py`, run by `.github/workflows/docs-validate.yml`). Local run:

```
python3 ../doc-framework/tools/link-check.py docs/
```
