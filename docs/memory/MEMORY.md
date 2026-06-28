# v-web — per-repo memory index

One line per memory file. Content lives in the files, not here. v-web is the
**VistA Web Services** package (`VWEB*`): the inbound socket adapter that drives
the m-stdlib `STDHTTPD` server framework over a real socket. Layer `v`
(VistA-coupled), consumes m-stdlib (`STDHTTPD`/`STDHTTPMSG`/`STDNET`/`STDJSON`/
`STDJWT`) and v-stdlib (`VSLTASK`/`VSLCFG`/`VSLENV`/`VSLFS`/`VSLSEC`) upward. See
the org + per-repo `CLAUDE.md`. Per-milestone "DONE" narratives are NOT memory —
they live in git history + `docs/implementation-tracker.md`; memory keeps only
durable lessons (the keep-test).

- [v-web-durable-gotchas](v-web-durable-gotchas.md) — the durable engineering
  gotchas + invariants for `VWEB*`, consolidated from the M6.3–M6.6 milestone
  journals: M/MUMPS call conventions (call `$$` wrappers with `$$` not `do`;
  bare-engine `$text`-guards; harness hides assertion text), the STDHTTPD/
  STDHTTPMSG/STDJSON seams (route table is INDEXED; `parseRsp` preserves header
  CASE — use `$$hdr^STDHTTPMSG`; JSON via the `RSP("json")` seam), byte-mode on
  YDB (`--chset m` / `CHSET` Makefile var), FHIR mapping (MRN=DFN; FileMan
  external date→ISO), auth posture (fail-closed; DUZ set-not-killed; `$text`-gated
  binding; `routesNoAuth` test-separation), live-VistA portability (foia #2 empty;
  coverage exception), and the KIDS back-out orphan limitation (#8989.51/#19).
  Architecture invariant: **zero direct VistA calls in `VWEB*`** (all via VSL* →
  ICR registry empty).
- [stdnet-iris-crlf-rawread-gap](stdnet-iris-crlf-rawread-gap.md) — **TWO STDNET
  IRIS gaps** found by the VWEB serve vertical (both m-stdlib, NOT v-web), **both
  RESOLVED**. **GAP 1 (CRLF)** — `readIris` did a CR-terminated read that stripped
  CRLF (HTTP framing → 400); fixed in **MSL v0.12.1** (byte-at-a-time `read *c:t`).
  **GAP 2 (peer-closed read)** — `$$read^STDNET` on a peer-CLOSED socket on IRIS
  raised an uncatchable `<DSCON>`-class disconnect that KILLED the job; fixed in
  **MSL v0.12.2** (`readIris` drains-then-EOFs under an ObjectScript try/catch).
  v-web repinned to v0.12.2 and dropped the static `readbackSafe()` gate. Durable
  IRIS-portability reference — why the MSL pin is at v0.12.2. Repro + fix inside.
- [phase4-traffic-console](phase4-traffic-console.md) — VSL/MSL **Phase 4 / M3**:
  the **VWEBT** RPC+HL7→S3 tap operator console. `GET /traffic/health` SSE
  snapshot + the operator toggle (`POST /traffic/tap` arm|off|rearm → `*^VSLTAP`,
  VWEBA-gated) + the fidelity panel + the self-contained `GET /traffic` SPA.
  SSE-auth = `?access_token=` query fallback scoped to `/traffic/*` in VWEBA.
  **OWED to m-stdlib:** the STDJSON-on-IRIS `$ECODE`-poisoning parse bug (stale
  `$ECODE` → `parseObject` returns empty tree; worked around with `set $ecode=""`
  in `fidelity()`). Part of the [[rpc-traffic-s3-streaming]] workstream.
