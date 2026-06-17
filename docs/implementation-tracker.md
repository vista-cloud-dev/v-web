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

## Owed / next

- ⛔ **`stdnet-iris-crlf-rawread-gap`** — `$$read^STDNET` (IRIS `readIris`) strips
  CRLF → breaks HTTP framing → IRIS serve returns 400. **An m-stdlib STDNET
  increment** (not v-web). When fixed, v-web's `$$rawByteSafe()` probe auto-heals
  the soft-skipped IRIS serve tests. See `docs/memory/stdnet-iris-crlf-rawread-gap.md`.
- 📤 **Repo + push** — `gh repo create vista-cloud-dev/v-web` (user action);
  branch `m6.3-vweb-listener` committed locally, push owed.
- 🔬 **Live observation** of TaskMan launch / XPAR reads / TLS on vehu/foia
  (bound + asserted; live run owed, the VSLTASK M5 posture).
- ➡️ **M6.4** — FHIR `/Patient` handler on this transport.
