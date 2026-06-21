---
name: phase4-traffic-console
description: v-web Phase 4 / M3 (RPC+HL7->S3 tap) — VWEBT traffic-tap console. Increment 1 (GET /traffic/health SSE) + increment 2 (operator toggle, fidelity panel, GET /traffic SPA) DONE dual-engine 164/0. M3 exit gate met.
metadata:
  type: project
---

**VSL/MSL Phase 4 / M3 — increment 2 DONE: the M3 EXIT GATE is MET (2026-06-21,
branch `phase4-traffic-console`).** Increment 1 made the tap observable; increment 2
makes it **operable and complete** — the operator can flip the tap, the fidelity proof
is visible, and a live SPA renders it. Built TDD red-first, dual-engine; **full v-web
suite 164/0 on BOTH engines** (YDB m-test-engine + IRIS m-test-iris); all engine-free
gates green; m-reviewer pass (no blockers). Kickoff:
`docs/prompts/s3tap-phase4-complete-m3-kickoff.md`.

**Three pieces this increment:**
- **Operator toggle** — `POST /traffic/tap?action=arm|off|rearm` (`tap^VWEBT`) calls
  ONLY `arm`/`off`/`rearm^VSLTAP` (reader+toggle; all safety logic stays in VSLTAP),
  then returns the fresh `$$snapshot` so the UI updates at once. VWEBA-protected
  (`/traffic/tap` not in `isOpen` → unauthenticated = 401). Action comes from the
  **query string, NOT a JSON body** (see the STDJSON-IRIS bug below). `rearm` clears a
  clean auto-failover cool-down (spec D-4); tested OFF→armed→auto-disable→re-arm.
- **Fidelity panel** — leaf-first in v-stdlib: **`VSLTAPFC do persist(res,ts)` →
  `^VSLTAP("fc","last")` + `$$lastFidelity()`** ([[phase4-fidelity-persist]] in
  v-stdlib). `snapshot^VWEBT` reads it via `fidelity()` into a `J("fidelity")` object:
  match `pct`, matched/mismatch/missing/extra counts, `status` (ok|mismatch|**pending**
  when no run — honest, never a fabricated %), `ts`. Also added `latbound` to the
  snapshot for the A/B threshold.
- **SPA** — `GET /traffic` (`console^VWEBT`) returns one self-contained, **dependency-
  free** `text/html` page (no CDN — serves inside VistA): opens an `EventSource` on
  `/traffic/health` (auto-reconnect = live cadence) and renders four panels (standby ·
  A/B latency · fidelity · spool) + the arm/off/rearm buttons (fetch POST). Built as
  thin M routes over hand-rolled `page()`/`js()`/`panel*()` helpers; **ASCII-only**
  (stripped em-dash/middot/µ/ellipsis to avoid an IRIS wide-char hazard).

**SSE-auth decision (the browser `EventSource` cannot set an `Authorization` header):**
chose option (a) — a **`?access_token=` query-string fallback in VWEBA, scoped ONLY to
`/traffic/*` paths** (`traffic(path)` helper; a query token on `/Patient/*` is ignored →
still 401, proven by `tQueryTokenScopedToTraffic`). The page forwards its own
`access_token` to both the EventSource URL and the toggle fetch. **Accepted risk
(documented in-code):** a token in the URL lands in access logs / proxy caches / history —
acceptable for the operator console only; a future POST-to-cookie exchange or short-TTL
console token is the hardening (flag for the M6.x security/retrospective doc).

**GOTCHA — m-stdlib STDJSON `$ECODE`-poisoning on IRIS (real below-the-waterline bug,
OWED to m-stdlib):** a **non-empty `$ECODE` on entry to `$$parse^STDJSON` makes the IRIS
`parseObject` loop (`quit:done!($ecode'="")`, `STDJSON.m:~88-94`) bail after the opening
brace and return an EMPTY tree on perfectly valid JSON** (`parse` still returns 1). Stale
`$ECODE` leaks across calls in a long process (prior fenced ops / a prior failed parse —
note: a failed IRIS parse's catch CLEARS `$ECODE`, which is why "the first parse absorbs
the poison" and a *second* parse of the same string then succeeds — this masqueraded as a
bogus "single-member objects fail on IRIS" symptom during diagnosis). **Workaround here:**
`fidelity()` does `set $ecode=""` before the parse (safe — the snapshot path has no real
pending error; same idiom STDJSON's own `irisParse` uses). The toggle sidesteps it
entirely by reading the query param instead of parsing a single-member JSON body. **The
durable fix belongs in m-stdlib** (`parse^STDJSON` should clear `$ECODE` at entry on IRIS)
so every STDJSON consumer doesn't re-discover it — file an m-stdlib issue.

**Diagnostic note (cost real time):** the `m test` runner surfaces only pass/fail COUNTS,
not per-assertion FAIL text (it parses `Summary.Assertions` but `toRow` discards them), and
`m vista exec` against `m-test-iris` returns empty stdout — so isolating an IRIS-only
failure means bisecting by commenting tests + weighted/`[`-contains assertions, not reading
an error message. (Also: the Bash tool persists cwd — running `make test` after a `cd` into
m-cli/m-stdlib silently ran the WRONG repo's suite; always confirm cwd.)

**Routes now (in `routes^VWEBR`, behind VWEBA):** `/healthz` (open) · `/Patient/:id` ·
**`/traffic` · `/traffic/health` · `/traffic/tap`** — VWEBE2ETST `tStackComposes` updated
3→5 routes. Adding routes inside an existing routine needs NO `kids/vweb.build.json` change
(VWEBT already listed); `make kids` + `make namespaces` still required for the src change.

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
