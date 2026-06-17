---
name: stdnet-iris-crlf-rawread-gap
description: Two STDNET IRIS socket gaps found by the VWEB serve vertical, both now RESOLVED. GAP 1 (CRLF) RESOLVED — readIris did a CR-terminated read that stripped CRLF, breaking HTTP framing; fixed in m-stdlib v0.12.1 (PR #18, byte-at-a-time read *c:t) and v-web repinned. GAP 2 RESOLVED — $$read^STDNET on a PEER-CLOSED socket on IRIS raised an uncatchable <DSCON>-class disconnect that KILLED the job (instead of draining buffered bytes + EOF), so the client read-BACK assertion couldn't run on IRIS; fixed in m-stdlib v0.12.2 (readIris drains-then-EOFs under an ObjectScript try/catch, STDNETTST 22/22 dual-engine), v-web repinned to v0.12.2 and dropped the static gate so tServeHealthOverSocket's read-back runs green on both engines.
metadata:
  type: project
---

# STDNET IRIS socket gaps found by the VWEB serve vertical

Two distinct STDNET-on-IRIS defects surfaced when M6.3's `$$serve^STDHTTPD`
ran over a real IRIS socket. Both are **m-stdlib (STDNET) issues, NOT v-web** —
v-web correctly drives the pinned contract. YDB is clean for both.

---

## GAP 1 — readIris stripped CRLF (HTTP framing) — ✅ RESOLVED (MSL v0.12.1)

**Found by M6.3, 2026-06-17; fixed same day.** `readIris` read with
`use dev read x#maxlen:timeout` — a **CR-terminated read** on the IRIS `|TCP|`
device: it stopped at the first CR and **stripped the CRLF**. So `$$serve`'s
framing loop never saw `\r\n\r\n` and returned **`HTTP/1.1 400 Bad Request`**.
Probe: writing the 16-byte `"GET /x"_$c(13,10)_"H: y"_$c(13,10)_$c(13,10)` and
reading it back returned only `GET /x` (6 bytes, CR/LF gone). STDNET's loopback
suite used terminator-free payloads ("ping"), so M2.T1 never caught it.

**Fix (m-stdlib `stdnet-iris-rawread-crlf`, PR #18, master `e0e6192`, tag
`v0.12.1`):** the IRIS arm of `readIris` now reads **byte-at-a-time** (`read *c:t`,
accumulate to maxlen — byte-exact, preserves CR/LF/NUL); YDB path untouched.
Added the `tCrlfByteExact` regression to `STDNETTST` (now 16/16 dual-engine). No
`@seam STDNET` contract change → a patch release.

**v-web consequence:** repinned MSL `v0.12.0` → **`v0.12.1`** (`dist/msl-seam-pin.json`).
The `$$rawByteSafe()` probe in `tests/VWEBLTST.m` now returns 1 on IRIS, so the
serve tests that only read on an OPEN peer (`tServeKeepAlive`,
`tConnectionCloseEndsIt`, `tAcceptOneServes`) **now RUN GREEN on IRIS**. The probe
stays as a live regression guard (auto-skips if a future engine re-breaks CRLF).

---

## GAP 2 — read on a PEER-CLOSED socket kills the IRIS job — ✅ RESOLVED (MSL v0.12.2)

**Found by M6.3's repin session, 2026-06-17.** Unmasked once GAP 1 was fixed and
the IRIS serve tests started running: the **client read-BACK** in
`tServeHealthOverSocket` (the client reads the response *after* the server did
its `Connection: close`) hits a peer-closed socket.

**Symptom / root cause:** on IRIS, `$$read^STDNET` against a socket whose **peer
has already closed** raises an IRIS `<DSCON>`-class **disconnect that KILLS the
job** — not a catchable M error, so it aborts the whole suite to **0/0** —
instead of draining the buffered bytes and returning EOF (which is what YDB
does, and what HTTP clients need). The **server-side serve path itself is
IRIS-clean** (the other serve tests run green on IRIS); only a *client* read
after the server closed is blocked.

**Why it can't be runtime-probed:** triggering it kills the process, so there's
no safe `$$probe()` that returns 0/1. v-web therefore uses a **static
known-gap gate** — `readbackSafe()` in `tests/VWEBLTST.m`: `$$rawByteSafe()` AND
`'$zversion["IRIS"`. It guards ONLY the read-back test
(`tServeHealthOverSocket`); the other IRIS serve tests are unaffected.

**Fix (m-stdlib `stdnet-iris-peerclosed-read`, master `8574af4`, tag `v0.12.2`):**
`readIris` now **drains-then-EOFs a peer-closed connection** — the read runs under
an ObjectScript `try/catch` arm that traps the `<DSCON>`-class disconnect and
returns the buffered bytes then 0/EOF rather than letting it halt the job. Added a
peer-closed-read regression to `STDNETTST` (now 22/22 dual-engine). No `@seam
STDNET` contract change → a patch release. YDB path untouched.

**v-web consequence (closed 2026-06-17, this branch):** repinned MSL `v0.12.1` →
**`v0.12.2`** (`dist/msl-seam-pin.json`; seams byte-identical, only `msl_ref`
moved) and **deleted the static `readbackSafe()` gate** — `tServeHealthOverSocket`
now guards on `$$rawByteSafe()` like the sibling serve tests. The client read-back
**RUNS GREEN on IRIS** (was a skip): VWEBLTST is 12/12 on **both** engines, suite
total 30/0 dual-engine, no 0/0 abort. Both STDNET IRIS socket gaps are closed.

See [[m6.3-vweb-listener]].
