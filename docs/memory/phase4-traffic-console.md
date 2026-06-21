---
name: phase4-traffic-console
description: v-web Phase 4 / M3 (RPC+HL7->S3 tap) — VWEBT traffic-tap health console (GET /traffic/health SSE), increment 1 done dual-engine.
metadata:
  type: project
---

**VSL/MSL Phase 4 / M3 — increment 1 DONE (2026-06-21, branch `phase4-traffic-console`).**
The RPC+HL7->S3 traffic tap's live health console. First increment: the read-only
snapshot endpoint that makes the tap's safety/standby state observable. Part of the
[[rpc-traffic-s3-streaming]] workstream (shared status in the `docs` repo); kickoff
prompt `docs/prompts/s3tap-phase4-resume-kickoff.md`.

**Built — `VWEBT`** (new routine, layer `v`):
- `snapshot(.J)` — a PURE READER that mirrors the live VSL* tap instruments into a
  STDJSON typed-node object (`o`/`s:`/`n:`): standby `state`/`healthy`/`ready`; the
  capture gate `enabled`/`consumer`/`alwayson`; auto-failover `disabled`(reason) +
  `offwindows` count; ring `ring`/`head`/`tail`; throughput `writes`/`bytes`/`denied`
  + tapped-latency `p50`/`p95`/`p99`. Adds NO capture/egress logic.
- `health(.REQ,.RSP)` — `GET /traffic/health` -> one SSE-framed snapshot event:
  `Content-Type: text/event-stream`, body `retry: 5000\nevent: health\ndata: <json>\n\n`.
- `routes(.SRV)` — registers the route; called from `routes^VWEBR` (so it sits behind
  the VWEBA auth middleware — `/traffic/health` is NOT in the open allow-list, so the
  operator console is auth-protected; only `/healthz` stays open).

**Instrument entry points consumed** (verified against v-stdlib `ship-all-routines`
source, not invented): `$$state`/`$$healthy`/`$$enabled`/`$$disabled`/`$$size`/
`$$head`/`$$tail`/`$$offWindows`/`$$cfg^VSLTAP`, `$$writes`/`$$bytes`/`$$denied`/
`$$pctl`/`$$ready^VSLTAPHL`. Consumer-presence reads `$$cfg^VSLTAP("consumer",0)`
(no dedicated getter). `$$ready^VSLTAPHL` is network-free (flags + heartbeat +
fenced `^XTMP` probe), so it's safe to call per request.

**FRAMEWORK CONSTRAINT (the SSE design driver):** STDHTTPD `serializeRsp` always
emits Content-Length and closes — **no server-side chunking in v0.1**. So a genuine
long-lived single-connection SSE push is NOT available below the waterline. The
endpoint emits a correct `text/event-stream` **snapshot PER REQUEST**; a browser
EventSource auto-reconnects (the `retry:` field paces it) for the live cadence.
True server-push streaming = a downstream STDHTTPD (m-stdlib) gap, out of scope for
this v-web phase. Set `RSP("body")` + `RSP("hdr","Content-Type")` directly (NOT
`RSP("json")`) so serializeRsp keeps the caller's Content-Type.

**GOTCHA (re-confirmed, already in [[m6.6-vweb-smoke]]):** `parseRsp` PRESERVES
response header-name case (unlike `parseReq` which lowercases) — assert wire headers
via the case-insensitive `$$hdr^STDHTTPMSG(.R,"content-type")`, never
`$get(R("hdr","content-type"))`. This was the one red assertion in the TDD-green pass.

**Dist regen required after adding a routine:** `make namespaces` (registry now 7
routines) AND **add the routine to `kids/vweb.build.json` `routines` list** (it is an
explicit list, NOT a glob — VWEBT was silently absent until added) + `make kids`.
KIDS stays `VWEB*1.0*3` (unreleased branch work).

**Verified:** TDD red (6/32) -> green; **YDB 125/125 + IRIS 125/125** full suite
(VWEBTTST 32/32 dual-engine; VWEBE2ETST updated to assert the 3-route table incl.
`/traffic/health`, 16/16). `make check-fast` all engine-free gates green.

**REMAINS for M3** (next increments): the SPA dashboard rendering (A/B latency panel,
standby panel, spool/off-window panel); the **fidelity panel** (`VSLTAPFC` reconcile/
manifest — needs a stored last-run result or a live run, no passive getter yet); the
**operator tap toggle** route (`arm^VSLTAP`/`off^VSLTAP`, POST, VWEBA-protected). The
snapshot already serves the DATA backing the A/B/standby/spool panels.
