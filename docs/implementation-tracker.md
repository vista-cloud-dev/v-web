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
| **M6.4** | **`VWEBR` router + FHIR `/Patient/:id` handler (VSLFS)** | **🟢 DONE 2026-06-17** |
| **M6.5** | **`VWEBA` auth (bearer/introspection → DUZ/#200)** | **🟢 DONE 2026-06-17** |
| **M6.6** | **the §9 smoke test (full vertical, both engines, KIDS lifecycle)** | **🟢 DONE 2026-06-18 — M6 CAPSTONE CLOSED** |

## Phase 4 / M3 — the RPC+HL7→S3 tap operator console (`VWEBT`)

Shared plan: `docs` repo `docs/proposals/rpc-traffic-s3-streaming-implementation-plan.md` §8 (master row 4).

| Stage | Deliverable | Status |
|---|---|---|
| 4.1 (incr 1) | `VWEBT` snapshot + `GET /traffic/health` SSE (read-only) | 🟢 DONE 2026-06-21 |
| 4.3 | operator tap toggle `POST /traffic/tap` (arm/off/rearm, VWEBA-gated) | 🟢 DONE 2026-06-21 |
| 4.2 (fidelity) | `VSLTAPFC persist`/`$$lastFidelity` (v-stdlib leaf) → `snapshot` `fidelity` member | 🟢 DONE 2026-06-21 |
| 4.2 (SPA) | `GET /traffic` self-contained HTML console (4 panels + toggle, EventSource) | 🟢 DONE 2026-06-21 |
| — | SSE-auth: `?access_token=` query fallback scoped to `/traffic/*` (VWEBA) | 🟢 DONE 2026-06-21 |
| **M3 exit gate** | **console shows live A/B-overlap + fidelity + standby; toggle works; dual-engine green** | **🟢 MET 2026-06-21** |

Branch `phase4-traffic-console` (unmerged). Full v-web suite **164/0 dual-engine**;
all engine-free gates green; m-reviewer no blockers. v-stdlib leaf on branch
`phase4-fidelity-persist`. Detail: `docs/memory/phase4-traffic-console.md`. **OWED to
m-stdlib:** the STDJSON-on-IRIS `$ECODE`-poisoning parse bug (worked around in
`fidelity()` via `set $ecode=""`; durable fix is `parse^STDJSON` clearing `$ECODE` at
entry). **Next:** Phase 5 / M4 (GA) — merge branches, KIDS install/back-out, real-S3 +
passive mirror, fleet rollout.

## M6.4 — DONE (2026-06-17)

**Branch `m6.4-fhir-patient`** (off `main`). The first real route mounts on the
M6.3 transport. New **`VWEBR`** + suite **`VWEBRTST`**; `VWEBL` refactored. Still
MSL **v0.12.2**.

Shipped:
- **`routes^VWEBR(.SRV)`** — the route table, now VWEBR-owned (STDHTTPD §6 Q3).
  `GET /healthz` → `health^VWEBL` (kept) + `GET /Patient/:id` → `getPatient^VWEBR`.
  `healthRoutes^VWEBL` **removed**; `VWEBL.run` + VWEBLTST setups call
  `routes^VWEBR`. Route-table *store* (spec **D3**) stays code-built — **D3 owed**.
- **`getPatient^VWEBR(.REQ,.RSP)`** — STDHTTPD handler. DFN from
  `REQ("param","id")`: **non-numeric → 400**, **absent → 404** (both FHIR
  `OperationOutcome`), else **200** + minimal FHIR R4 `Patient`. Auth-agnostic
  (M6.5). #2 read via **VSLFS** (`$$exists`/`$$get` — `.01`/`.02`/`.03`), **no
  direct `^DPT`** → ICR registry stays empty. JSON via the **`RSP("json")`
  STDJSON seam** (serializeRsp encodes + adds Content-Type; handles the M6.1 IRIS
  subscripted-by-ref gotcha). FHIR mapping: id←DFN; identifier←DFN as **MRN**
  (type `MR`, `urn:vista:dfn`); name←#.01; gender←#.02 (MALE/FEMALE→male/female);
  birthDate←#.03 via `$$fmToIso` (FileMan external "JAN 01, 1950" → `YYYY-MM-DD`,
  partial→`YYYY`/`YYYY-MM`). **MRN=DFN** grounded in vdocs (ICN direct-access
  forbidden, SSN=PII).
- **KIDS** `VWEB*1.0*2`: added `VWEBR` (5 routines); `dist/kids/VWEB.kids` +
  `dist/namespace-registry.json` regenerated.

**Verification (driver stack only):**
- bare YDB (m-test-engine, --chset m) + bare IRIS (m-test-iris): **38/38 each**
  (VWEBRTST 26 + VWEBLTST 12) — routing, 400 (dispatch + real socket), and pure
  FHIR-mapping unit tests (splitName/gender/fmToIso) run with no FileMan.
- **vehu** (YDB-VistA, --chset m): VWEBRTST **35/35** — a real #2 read → 200 FHIR
  Patient via `$$dispatch` AND over a real socket; plus 404.
- **foia-t12** (IRIS-VistA, --namespace VISTA): VWEBRTST **27/27** — 404 live;
  the 200 + socket-200 soft-skip on its **empty #2** (`$order(^DPT(0))=""`, a
  scrubbed FOIA build); mapping units green.
- `make check` exit 0 (bare YDB): fmt / lint 0 / arch layer-v / 7 drift gates
  (icr **0**, namespaces **5**, msl-pin v0.12.2, check-kids ✓) / suite 56/56.

**Coverage posture:** not in `make check` (separate target; CI engine-free). The
`getPatient` FileMan body is a **documented exception** (live-only; the coverage
monitor doesn't collect over the docker transport — vehu reports 0.0%) — proven
by the live vehu suite, like VWEBL's infra-gated `run`/`launch`.

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

## M6.3 repin — MSL v0.12.1 → v0.12.2 (2026-06-17) — IRIS read-back green

**Branch `repin-msl-v0.12.2`.** GAP 2 is now fixed in m-stdlib (MSL **v0.12.2**:
`readIris` drains-then-EOFs a peer-closed read under an ObjectScript try/catch;
`STDNETTST` 22/22 dual-engine, no `@seam STDNET` change → patch). Bumped
`dist/msl-seam-pin.json` `msl_ref` `v0.12.1`→`v0.12.2`; `make pin` re-synced —
**seams block byte-identical** (only `msl_ref` moved). `check-msl-pin` green @
v0.12.2.

**Deleted the static `readbackSafe()` gate** in `tests/VWEBLTST.m` —
`tServeHealthOverSocket` now guards on `$$rawByteSafe()` like the sibling serve
tests (one fewer indirection); the now-false `'$zversion["IRIS"` skip and its
stale doc/skip message are gone. Effect: the client read-BACK **RUNS on IRIS**
(was a skip) and the 200 is read back byte-exact. Result: **YDB 30/30, IRIS
30/30** (VWEBLTST **12/12 on both engines**), no 0/0 abort. **The M6.3 serve
vertical is now fully dual-engine.** GAP 1 ✅ / GAP 2 ✅.

## Owed / next

- ✅ **`stdnet-iris-crlf-rawread-gap` GAP 1 (CRLF) RESOLVED** — fixed in MSL
  v0.12.1 (PR #18); v-web repinned (above); server-side IRIS serve now green.
- ✅ **`stdnet-iris-crlf-rawread-gap` GAP 2 (peer-closed read) RESOLVED** — fixed
  in MSL **v0.12.2** (`readIris` drains-then-EOFs under an ObjectScript try/catch);
  v-web repinned v0.12.1→v0.12.2 + dropped the static `readbackSafe()` gate; the
  IRIS read-back is green. **Both STDNET IRIS socket gaps are closed.**
- ✅ **Repo + push DONE** — github.com/vista-cloud-dev/v-web is live (public,
  default `main`); `main` + `m6.3-vweb-listener` + `repin-msl-v0.12.1` pushed;
  `repin-msl-v0.12.2` pushed with this increment.
- 🔬 **Live observation** of TaskMan launch / XPAR reads / TLS on vehu/foia
  (bound + asserted; live run owed, the VSLTASK M5 posture).
- ➡️ **M6.4** — FHIR `/Patient` handler on this transport.

---

## M6.4 — FHIR `GET /Patient/:id` (DONE 2026-06-17, branch `m6.4-fhir-patient`)

`VWEBR` router + the minimal FHIR R4 Patient handler reading #2 via VSLFS;
`routes^VWEBR` owns the table. Bare 38/38 both engines, vehu 35/35 (live #2
read), foia 27/27. KIDS `VWEB*1.0*2`. See `docs/memory/m6.4-vweb-fhir-patient.md`.

## M6.5 — VWEBA auth middleware → DUZ/#200 (DONE 2026-06-17, branch `m6.5-auth`)

`VWEBA` closes the M6.4 route: a Bearer JWT → authenticated subject (STDJWT,
`m`) → #200 IEN/DUZ (VSLSEC `$$bySecid`/`ien` map, `v`); **401** unauthenticated
(+`WWW-Authenticate` + FHIR OperationOutcome), **403** unprovisioned, `/healthz`
open. The relying-party half of *validate-a-token-not-the-PIV-card* (grounded in
the vdocs corpus + VA IAM/PIV/SMART research). Registered via `register^VWEBA`
(`use^STDHTTPD`) from `routes^VWEBR`; `getPatient` stays auth-agnostic. Config via
the `^VWEB("rtcfg")` cache → XPAR → default; **fail-closed** on an empty key.
Provider seam (`$$validate`) wires **jwt** now; introspection/SAML are future
providers behind it.

- **Verified:** bare YDB+IRIS **77/77** (security guarantees); **vehu 23+35**,
  **foia 23+27** (full token→DUZ e2e + 403, live both engines). All gates green;
  KIDS **VWEB*1.0*3** (+`VWEBA`, +6 auth XPAR params); icr 2263/DBS for the two
  $text-probed L4 symbols.
- **OWED:** bump the MSL pin → **v0.13.0 + the STDJWT seam** once the user **tags
  MSL v0.13.0** (today the pin stays v0.12.2; STDJWT is consumed-but-unpinned and
  `check-msl-pin` SKIP-greens against the unreachable tag). Merge order: MSL
  v0.13.0 → v-stdlib `m6.5-secid-binding` → v-web `m6.5-auth` (repin + flip).
  ✅ **CLOSED** — the pin is now at **MSL v0.13.0** (6 seams, `check-msl-pin` green)
  on the `m6.5-auth-on-main` base; v-stdlib `$$bySecid^VSLSEC` is committed.
- ➡️ **M6.6** — the §9 TLS smoke test that closes the M6 capstone.

## M6.6 — the §9 end-to-end smoke (DONE 2026-06-18, branch `m6.6-tls-smoke`) — M6 CAPSTONE CLOSED

The capstone close. **Composition + verification, no production surface**: a new
suite **`tests/VWEBE2ETST.m`** (6 tests) drives the whole VWEB*/VSL*/STD* vertical
through one front door over a REAL socket. See `docs/memory/m6.6-vweb-smoke.md`.

Shipped (all in `tests/` — not part of the KIDS build; src routines unchanged):
- **The capstone leg that was never tested e2e:** an **authenticated 200 FHIR
  Patient over a real socket** (`tAuthenticatedPatient200OverSocket`) — auth
  middleware + #200 bind + VSLFS #2 read + STDJSON, all at once on the wire (M6.5
  proved 401-over-socket + authenticated-200-via-`$$dispatch`; M6.4 proved
  200-over-socket auth-stripped — this is the union). Plus open-path 200, tokenless
  **401 through the LIVE registered chain**, **403** unprovisioned, and the **§9
  TLS gap-loud** assertion (`$$listenTls`→`,U-VWEB-NOTLS,`; the real HTTPS
  round-trip soft-skips until cert + `XU*8.0*787`, never faked).
- **Makefile `CHSET` passthrough** — YDB needs byte mode (`--chset m`) or VWEBATST
  aborts 0/0 (JWT/HMAC bytes >127). `CHSET` defaults to `m` for `ENGINE=ydb`
  (empty for IRIS), folded into `ENGINE_FLAGS`, mirroring m-stdlib's byte-mode
  default — so `make check`/`make test` are genuinely green for YDB as written.

**Verification (driver stack only):**
- bare YDB (m-test-engine, `--chset m`): VWEBE2ETST **15/15**; `make check
  ENGINE=ydb DOCKER=m-test-engine` exit 0 — all gates + **92/92 across 7 suites**.
- bare IRIS (m-test-iris): VWEBE2ETST **15/15**; full `make test` **92/92**.
- **vehu** (YDB-VistA): VWEBE2ETST **20/20** — the authenticated 200 over the
  wire + 403, live.
- **foia-t12** (IRIS-VistA, `--namespace VISTA`): VWEBE2ETST **16/16** — 403 live;
  the authenticated 200 soft-skips on the empty/scrubbed #2 (the M6.4 posture).

**Test-side gotchas (fixed):** STDHTTPD's route table is INDEXED
(`SRV("route",n,"pattern")`), not path-keyed; `parseRsp^STDHTTPMSG` preserves
response header-name CASE (use `$$hdr^STDHTTPMSG`, not a raw lowercased lookup).

**Decisions (kickoff Q1/Q2):**
- **Q1:** M6 is closed on the full *authenticated* vertical over plaintext
  loopback (dual-engine + live) + the loud TLS gate. Real TLS stays the M2.T2
  infra follow-up (no server cert / `XU*8.0*787` absent).
- **Q2:** the KIDS install→verify→back-out of `VWEB*1.0*3` is **documented, not
  run live** — a real back-out would orphan the XPAR param defs (#8989.51) + the
  `VWEB LISTENER` option (#19) because v-pkg uninstall is routine-only (#9.7/#9.6).
  Manual cleanup is documented; the **v-pkg uninstall-covers-#8989.51/#19
  enhancement is filed separately** (cross-repo, non-blocking).

**Owed (post-merge / coordinator):**
- Shared docs-repo `vsl-implementation-tracker.md` M6 row rollup (M6.1–M6.6 into
  the capstone summary) — coordinator lane, at the milestone boundary.
- The v-pkg uninstall enhancement (#8989.51 + #19) — separate cross-repo ticket.
- Merge `m6.6-tls-smoke` → `main` (explicit, user-requested — not part of the
  increment protocol).
