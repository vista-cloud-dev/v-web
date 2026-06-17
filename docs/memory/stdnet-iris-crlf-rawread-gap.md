---
name: stdnet-iris-crlf-rawread-gap
description: m-stdlib FOLLOW-UP found by M6.3 — $$read^STDNET on IRIS (readIris) does a CR-terminated read that stops at the first CR and strips CRLF, so HTTP framing (\r\n\r\n) is destroyed and $$serve^STDHTTPD returns 400 over an IRIS socket. STDNET's loopback suite used terminator-free payloads so never caught it. The one thing blocking a dual-engine-green VWEB serve vertical. An m-stdlib (STDNET) increment, NOT v-web.
metadata:
  type: project
---

# STDNET IRIS raw-read strips CRLF (HTTP framing breaks) — m-stdlib follow-up

**Found by M6.3 (v-web), 2026-06-17.** The VWEB serve vertical is GREEN on YDB
(30/30) but the **serve-over-socket path fails on IRIS** because the m-stdlib
socket read mangles HTTP request bytes.

## Symptom

On `m-test-iris`, `$$serveConn^VWEBL` returns `n=1` (one request "served") but
the response on the wire is **`HTTP/1.1 400 Bad Request`** — `$$serve^STDHTTPD`
framed a malformed request. VWEBIO/STDNET socket *primitives* are fine
(VWEBIOTST 14/14 on IRIS, including a "ping"/"pong" round-trip); only HTTP
(CRLF-bearing) traffic breaks.

## Root cause (pinned with a direct probe)

`readIris` in `m-stdlib/src/STDNET.m` reads with `use dev read x#maxlen:timeout`.
On the IRIS `|TCP|` device that is a **terminated read**: it stops at the first
**CR** and **strips the CRLF**. Probe (write `"GET /x"_$c(13,10)_"H: y"_$c(13,10)_$c(13,10)`,
16 bytes, then `$$read^STDNET(conn,16384,5,.buf)`):

```
sent=16  got=6  eq=0  gotdump=[71 69 84 32 47 120]   ("GET /x" — first line, CR/LF gone)
```

So `$$serve`'s framing loop accumulates `GET /x` + `H: y` + … with **no CRLFs**,
never finds the `\r\n\r\n` terminator, and on client close returns 400.
STDNET's own `STDNETTST` loopback only ever sent terminator-free payloads
("ping"), so M2.T1 never exercised binary/CRLF data — this is a latent M2.T1
gap, surfaced the first time real HTTP went over an IRIS socket.

## Fix sketch (an m-stdlib STDNET increment — NOT v-web)

`readIris` (and likely `acceptIris`) must read **raw bytes, no terminator**.
Options to evaluate on IRIS:
- read byte-at-a-time with `read *x` up to `maxlen`/timeout (slow but exact), or
- open/parameterize the `|TCP|` device for fixed-length/no-wrap binary reads so
  `read x#n` returns available bytes without treating CR as a terminator, or
- set the device's terminator/translation off for the read.
Add a CRLF round-trip case to `STDNETTST` (the regression that would have caught
this). YDB's `read x#n:t` already returns available bytes raw — no YDB change.

## Why it does NOT block M6.3 shipping

The defect is in **m-stdlib STDNET**, below the waterline; the v-web M6.3 session
must not modify STDNET (one-repo rule + the kickoff scope guard). v-web is
correct — it drives the pinned contract. So M6.3 ships with:
- YDB serve vertical GREEN end-to-end;
- IRIS socket adapter GREEN, IRIS serve tests **soft-skipped loudly** behind a
  `$$rawByteSafe()` probe in `tests/VWEBLTST.m` that **auto-heals** the moment
  STDNET preserves CRLF on IRIS (no v-web change needed then).

Run the STDNET fix as its own m-stdlib increment (re-verify `STDNETTST` 9/9 + the
new CRLF case dual-engine; re-tag MSL), then v-web's IRIS serve tests light up
automatically. See [[m6.3-vweb-listener]].
