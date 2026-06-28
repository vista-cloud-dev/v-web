---
name: v-web-durable-gotchas
description: Durable engineering gotchas + invariants for the v-web (VWEB*) package, consolidated from the M6.3–M6.6 milestone journals. Each entry is a lesson that survives the next increment (not a per-increment status). Covers M/MUMPS call conventions, bare-engine vs live-VistA portability, the STDHTTPD/STDHTTPMSG/STDJSON seams, auth (VWEBA) security posture, FHIR mapping, byte-mode, and test-harness traps. The per-milestone DONE narratives live in git history + docs/implementation-tracker.md.
metadata:
  type: project
---

# v-web — durable gotchas & invariants

Consolidated 2026-06-28 from the M6.3–M6.6 increment journals (the dated "DONE"
status narratives are in git history + `docs/implementation-tracker.md`; only the
durable lessons are kept here, verbatim). v-web is the **VistA Web Services**
package (`VWEB*`): the inbound socket adapter driving m-stdlib `STDHTTPD` over a
real socket. Layer `v`, consumes m-stdlib (`STDHTTPD`/`STDHTTPMSG`/`STDNET`/
`STDJSON`/`STDJWT`) and v-stdlib (`VSLTASK`/`VSLCFG`/`VSLENV`/`VSLFS`/`VSLSEC`)
upward — one-way `v→m`.

For the two STDNET-on-IRIS socket gaps found by the serve vertical (both fixed in
m-stdlib, the reason the MSL pin is at v0.12.2), see
[[stdnet-iris-crlf-rawread-gap]] — kept separate as IRIS-portability reference.

## Durable invariants (the architecture, do not re-litigate)

- **Zero direct VistA calls in `VWEB*`** — every XPAR/Kernel/TaskMan/FileMan touch
  is delegated to a resident `VSL*` routine (`$$get^VSLCFG`, `$$check^VSLENV`,
  `$$schedule`/`$$stop^VSLTASK`, VSLFS for #2, VSLSEC for #200). So the **ICR
  registry is empty/green** and the no-direct-global gate is trivially green — the
  cleanest possible waterline. (The few L4 symbols VWEBA `$text`-PROBES — `GET^XPAR`,
  `GET1^DIQ` — carry `@icr` tags 2263 / notional DBS: they record the dependency,
  never invoke.)
- **D1 socket handoff = single-process SERIAL** (accept→serve→close→accept, no
  JOB-off). The vertical is proven end-to-end first; jobbed-worker concurrency (the
  engine-divergent `$zversion["IRIS"` fork) is a separately-tested LATER layer.
- **HTTP-first, TLS-gap-loud** — the dev/test path is plaintext loopback; the TLS
  code path is bound + raises `,U-VWEB-NOTLS,`; live TLS verification is owed
  (M2.T2 infra-blocked, no cert / `XU*8.0*787`). `$$listenTls` never serves
  plaintext on the TLS port; a real HTTPS round-trip soft-skips until provisioned,
  never faked.

## M/MUMPS call conventions & bare-engine traps

1. **`do <value-returning-function>` aborts with `%YDB-E-NOTEXTRINSIC`** — the
   `$quit` gotcha. `close^VWEBIO` ends `quit $$close^STDNET(id)`; calling it as
   `do close^VWEBIO(conn)` (in serveConn/run) faulted *uncatchably* → the suite
   aborted to **0/0** (report never fired). Fix: call it as `$$` (`set ok=$$close^VWEBIO(conn)`).
   This is the same family as STDHTTPD's gotcha-3, but the trap-presence masked
   it: a value-fn fault one frame below a parent `$etrap` *resumes* the parent;
   inline (same frame) it unwinds. Lesson: **call every `$$` wrapper with `$$`,
   never `do`.**
2. **A bare m-test-engine has no Kernel** — `$$GET^XPAR`/`$$VERSION^XPDUTL`/
   `$$TM^%ZTLOAD` are missing, and a *missing-routine fault on these does NOT
   resume* a flag-`$ETRAP` cleanly (unlike a synthetic missing routine — engine
   nuance), so it aborts the suite. **Guard with `$text(GET^XPAR)`/
   `$text(VERSION^XPDUTL)`/`$text(TM^%ZTLOAD)`** before the call (in the TEST,
   which is not ICR-scanned) and soft-skip — never trap it.
3. **The test harness hides assertion messages** (json/text show only counts).
   To debug an engine fault: stash `$zstatus` to a scratch global inside the
   routine's own `$etrap`, then read it back with
   `m vista exec --engine … --transport docker --container … --namespace … 'write …'`
   (driver-compliant; works on bare engines too). This is how the NOTEXTRINSIC
   and the IRIS-CRLF defects were pinned.

## STDHTTPD / STDHTTPMSG / STDJSON seams

- **STDHTTPD route table is INDEXED, not path-keyed.** `routes^VWEBR` builds
  `SRV("route")=count`, `SRV("route",n,"pattern")`, `SRV("mw")=count`,
  `SRV("mw",n)=ref` (see `route`/`use^STDHTTPD`). A first guess of
  `SRV("route","GET","/healthz")` is wrong → scan the indexed nodes.
- **`parseRsp^STDHTTPMSG` preserves response header-name CASE** (unlike
  `parseReq`, which lowercases). A wire `WWW-Authenticate` parses back as
  `RSP("hdr","WWW-Authenticate")`, NOT lowercased — use the case-insensitive
  `$$hdr^STDHTTPMSG(.R,"www-authenticate")` for the challenge, never a raw
  `$get(R("hdr","www-authenticate"))`.
- **JSON via the `RSP("json")` seam, NOT a hand `$$encode^STDJSON` call.** The
  handler builds the STDJSON typed-node tree (`"o"`/`"a"`/`"s:"`) directly in
  `RSP("json")`; `serializeRsp^STDHTTPMSG` does `merge jnode=RSP("json")` (a
  top-level copy — this *is* the M6.1 IRIS "subscripted-by-ref" gotcha handled
  for you) then `$$encode^STDJSON` **and** auto-adds `Content-Type:
  application/json`. So "STDHTTPD adds Content-Type" is literally true only on
  the `RSP("json")` path (raw `RSP("body")` gets none). Same idiom as
  `setError^STDHTTPD`. All FHIR arrays use only contiguous index 1 (no gappy
  array → no `U-STDJSON-ENCODE`).

## Byte mode (YDB)

- **Byte mode is MANDATORY on YDB and the Makefile didn't encode it.** Without
  `--chset m`, **VWEBATST aborts 0/0** (its JWT/HMAC signing emits bytes >127 that
  re-encode under UTF-8). The suites always ran with `--chset m` by hand; the
  Makefile `test`/`coverage`/`check` targets passed no chset, so `make check` was
  not actually green for YDB as written. Fixed: a **`CHSET` Makefile var**
  defaulting to `m` for `ENGINE=ydb` (empty for IRIS), folded into `ENGINE_FLAGS`
  — mirrors m-stdlib's `M_ENGINE_FLAGS` byte-mode default. `make test ENGINE=ydb
  DOCKER=m-test-engine` now byte-mode by default.

## FHIR `/Patient` mapping (VWEBR)

- **MRN = the DFN** (single-station). Grounded in the vdocs gold corpus: the
  **ICN is forbidden for direct access** ("Direct access to ICNs in the PATIENT
  file is not allowed", MPIF) and is registration/MPI-assigned (a DBS-added
  patient has none); **SSN (.09) is PII** and not a record locator; the **DFN is
  the natural local record key** (`^DPT` IEN), always present. getPatient adds NO
  direct VistA call (all via VSLFS), so the ICR registry stays empty/green.
- **FileMan external date → ISO** is done in VWEBR (`$$fmToIso`/`$$monNum`),
  because VSLFS `$$get` returns **external** values only (no flags/internal
  param) — `$$GET1^DIQ` default is external ("JAN 01, 1950", "MALE"/"FEMALE").
  `$$fmToIso` is order-independent (4N→year, 1-2N→day, 3-alpha→month) and
  degrades partial dates to `YYYY`/`YYYY-MM`; the day-before-year bug (day
  dropped when its capture required year-seen-first) was the TDD red→green fix.

## Auth security posture (VWEBA)

- **Config via a runtime cache.** `$$cfg` reads `^VWEB("rtcfg",<param>)` FIRST
  (listener-warmable; **tests set it directly so the whole chain runs with NO
  XPAR and no KIDS install**), then XPAR (VWEBCFG), then a default.
- **FAIL-CLOSED**: an empty/unconfigured signing key rejects ALL tokens (401),
  never silent-open. (`tUnconfiguredKeyFailsClosed`.)
- **DUZ is SET, not killed.** authn sets `DUZ`=bound IEN on every authenticated
  request before the handler runs; a failed auth short-circuits (`CTX("stop")`)
  BEFORE the handler, so a stale keep-alive DUZ never reaches a handler. No
  `kill DUZ` (it would break the bind's own `$$user` context).
- **Binding is $text-gated** (`$$hasVista`=`$text(GET1^DIQ)`): on a bare engine a
  cryptographically-verified request passes through with DUZ unresolved (bare
  handlers touch no FileMan); the #200 binding is a live-VistA operation.

## Test-harness traps (burned here, fixed)

- **Test-separation:** registering the auth middleware in `routes^VWEBR` protected
  `/Patient/:id`, breaking VWEBRTST's open-route tests. Fix: VWEBRTST's handler/
  routing tests use a `routesNoAuth` helper (`do routes^VWEBR(.SRV) kill
  SRV("mw")`) — the real table with the middleware chain stripped. End-to-end
  auth on the route is VWEBATST's job.
- **TWO auth test gotchas burned here:** (1) a suite-local `if $$hasVista()` call
  when no `hasVista` label exists in the suite → undefined-label → silent **0/0
  abort** (the runner swallows $ZSTATUS). Use the label that EXISTS
  (`$$hasFileMan`). (2) the "bare signing" security tests must SKIP on a live
  engine (`if $$hasFileMan() quit`) — else binding kicks in and a sub=1 token
  with the default `secid` map → `bySecid("1")`→403, not the expected 400.
- **STDCRYPTO availability:** token-signing tests guard on `$$available^STDCRYPTO`
  — present on the bare test engines AND on vehu/foia (so the full e2e runs live
  on both); the no-signing binding test (`tByIenLive`) proves the binding even
  without crypto.

## Live-VistA portability / coverage posture

- **foia-t12's PATIENT #2 is EMPTY** — `$order(^DPT(0))=""` (only the file
  header node; FOIA public builds are scrubbed of patient data). So a live
  real-#2-read 200 is impossible there, and **VSLFS `$$set` cannot seed #2**
  (it does single-field adds; #2 has multiple required identifiers). The
  known-DFN tests **discover an existing record read-only** (scan `$$exists^VSLFS`
  1..5000 — never direct `^DPT`; zero mutation, nothing to back out) and
  **soft-skip loudly on an empty #2**. So the 200 real-read is proven on **vehu**
  (populated YDB-VistA); foia proves routing/400/404 + the pure mapping units.
- **Coverage exception (FileMan body live-only).** `make check` does not include
  coverage (separate target; CI engine-free). Bare-engine VWEBR coverage is low
  because `getPatient`'s FileMan body only executes on a live VistA, and the
  coverage monitor does **not** collect over the live docker transport (vehu
  reports 0.0%). So the FileMan read path is a **documented coverage exception**
  (same class as VWEBL's infra-gated `run`/`launch`) — proven by the live vehu
  suite, not bare coverage.

## Known limitation — KIDS back-out orphans XPAR params + the listener option

`v pkg uninstall` is **routine-only** (#9.7/#9.6), so backing out a `VWEB*` patch
**orphans** the `VWEB *` XPAR parameter definitions (#8989.51) + the `VWEB
LISTENER` option (#19) — no automatic back-out path. Until v-pkg's uninstall
covers #8989.51 + #19, the manual cleanup is: after the routine uninstall, delete
the `VWEB *` parameter definitions from #8989.51 and the `VWEB LISTENER` entry
from #19 by hand. The v-pkg enhancement is a separate cross-repo ticket.
