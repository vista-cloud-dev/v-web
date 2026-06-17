# v-web — implementation tracker

The `VWEB*` package: the inbound socket adapter that drives m-stdlib `STDHTTPD`
over a real socket. Part of the multi-session **M6 VWEB capstone** (FHIR
`GET /Patient` over HTTPS, both engines). Shared cross-repo plan + tracker:
the `docs` repo `docs/vsl-msl/vsl-implementation-plan.md` +
`docs/vsl-msl/vsl-implementation-tracker.md`. This file is the v-web-local view.

## M6 decomposition (this repo owns M6.3–M6.6)

| Sub | Deliverable | Status |
|---|---|---|
| M6.1 | `STDHTTPMSG` codec (m-stdlib) | 🟢 DONE (MSL v0.10.0) |
| M6.2 | `STDHTTPD` framework (m-stdlib) | 🟢 DONE (MSL v0.11.0) |
| **M6.3** | **`v-web` skeleton + `VWEBIO`/`VWEBL` listener** | **🟢 DONE 2026-06-17** |
| M6.4 | `VWEBR` router + FHIR `/Patient` handler (VSLFS) | ⬜ next |
| M6.5 | `VWEBA` auth (bearer/introspection → DUZ/#200) | ⬜ |
| M6.6 | the §9 smoke test (full vertical, both engines, KIDS install→back-out) | ⬜ |

## M6.3 — DONE (2026-06-17)

**Branch `m6.3-vweb-listener`.** New repo `v-web` (layer `v`, `VWEB*`). Consumes
MSL **v0.12.0** (`STDHTTPD`/`STDHTTPMSG`/`STDNET`) + v-stdlib
(`VSLTASK`/`VSLCFG`/`VSLENV`).

Shipped: **VWEBIO** (transport descriptor + STDNET pass-throughs + listen/accept
+ gap-loud `$$listenTls`), **VWEBL** (`$$launch` via VSLTASK + serial
accept→serve→close `run`/`acceptLoop`/`acceptOne`/`serveConn` + `GET /healthz`
route), **VWEBCFG** (XPAR config via `$$get^VSLCFG`), **VWEBENV** (KIDS env-check
extending VSLENV). Suites: VWEBIOTST, VWEBLTST, VWEBCFGTST, VWEBENVTST. KIDS
`VWEB*1.0*1` (`kids/vweb.build.json`: 4 routines, 5 XPAR param defs, MSL+VSL
Required Builds, envCheck VWEBENV).

**Verification:**
- YDB bare (m-test-engine): **30/30 GREEN** — full socket→`$$serve`→write vertical.
- IRIS bare (m-test-iris): **26/26 GREEN** — VWEBIO 14/14; serve tests soft-skip
  loudly on the STDNET IRIS CRLF defect (below).
- `make check-fast` exit 0: fmt / lint (0) / `m arch check` (layer v) / 4 drift
  gates (seams 0, icr **0** — zero direct VistA calls, citations 0, namespaces 4)
  / `check-msl-pin` v0.12.0 (5 seams) / `check-engine-access` / `check-kids`.

**Design:** D1 = single-process serial (jobbed concurrency deferred); HTTP-first,
TLS-gap-loud (`,U-VWEB-NOTLS,`); zero direct VistA calls (all via VSL*).

## M6.3 repin — MSL v0.12.0 → v0.12.1 (2026-06-17)

**Branch `repin-msl-v0.12.1`.** Bumped `dist/msl-seam-pin.json` `msl_ref`
`v0.12.0`→`v0.12.1`; `make pin` re-synced — **seams block byte-identical** (the
CRLF fix carries no `@seam STDNET` change). `check-msl-pin` green @ v0.12.1.

Effect: the v0.12.1 CRLF fix made `$$rawByteSafe()` pass on IRIS, so the
**server-side** serve tests (`tServeKeepAlive`, `tConnectionCloseEndsIt`,
`tAcceptOneServes`) now **run GREEN on IRIS** — but the repin **unmasked a SECOND
STDNET IRIS gap**: a `$$read^STDNET` on a **peer-closed** socket KILLS the IRIS
job (uncatchable disconnect), which the client read-BACK in
`tServeHealthOverSocket` triggers. Since that can't be runtime-probed, added a
static `readbackSafe()` gate (`$$rawByteSafe()` AND `'$zversion["IRIS"`) guarding
only that one test. Result: **YDB 30/30, IRIS 27/27** (was 26/26), no more 0/0
abort. See `docs/memory/stdnet-iris-crlf-rawread-gap.md` (GAP 1 ✅ / GAP 2 ⛔).

## Owed / next

- ✅ **`stdnet-iris-crlf-rawread-gap` GAP 1 (CRLF) RESOLVED** — fixed in MSL
  v0.12.1 (PR #18); v-web repinned (above); server-side IRIS serve now green.
- ⛔ **`stdnet-iris-crlf-rawread-gap` GAP 2 (peer-closed read)** — `$$read^STDNET`
  on a peer-closed socket kills the IRIS job (vs drain+EOF). **An m-stdlib STDNET
  increment** (not v-web). When fixed + MSL re-tagged, drop the `'$zversion["IRIS"`
  arm of `readbackSafe()` and bump the pin → IRIS read-back goes green. See
  `docs/memory/stdnet-iris-crlf-rawread-gap.md` for the fix sketch.
- ✅ **Repo + push DONE** — github.com/vista-cloud-dev/v-web is live (public,
  default `main`); `main` + `m6.3-vweb-listener` pushed; `repin-msl-v0.12.1`
  pushed with this increment.
- 🔬 **Live observation** of TaskMan launch / XPAR reads / TLS on vehu/foia
  (bound + asserted; live run owed, the VSLTASK M5 posture).
- ➡️ **M6.4** — FHIR `/Patient` handler on this transport.
