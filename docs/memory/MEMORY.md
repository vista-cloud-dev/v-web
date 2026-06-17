# v-web — per-repo memory index

One line per memory file. Content lives in the files, not here. v-web is the
**VistA Web Services** package (`VWEB*`): the inbound socket adapter that drives
the m-stdlib `STDHTTPD` server framework over a real socket. Layer `v`
(VistA-coupled), consumes m-stdlib (`STDHTTPD`/`STDHTTPMSG`/`STDNET`, MSL
v0.12.0) and v-stdlib (`VSLTASK`/`VSLCFG`/`VSLENV`) upward. See the org +
per-repo `CLAUDE.md`.

- [m6.3-vweb-listener](m6.3-vweb-listener.md) — VSL/MSL **M6.3 DONE** (2026-06-17): the new **v-web** repo + **VWEBIO** (transport/device/TLS adapter) + **VWEBL** (listener launcher + serial accept→serve→close loop) + **VWEBCFG** (XPAR config) + **VWEBENV** (KIDS env-check). The socket→`$$serve^STDHTTPD`→write **vertical is GREEN end-to-end on YDB (30/30)**; on IRIS the socket adapter is fully GREEN (VWEBIO 14/14) but the **serve path is loudly soft-skipped on a newly-found STDNET IRIS raw-read defect** (see [[stdnet-iris-crlf-rawread-gap]]). All engine-free gates green (fmt/lint/arch/4 drift gates/msl-pin v0.12.0/check-kids `VWEB*1.0*1`); ICR registry **empty** (v-web makes zero direct VistA calls — all via VSL*). HTTP-first, TLS-gap-loud (`,U-VWEB-NOTLS,`); D1 socket handoff = single-process serial (jobbed-worker concurrency deferred). Branch `m6.3-vweb-listener`; **repo not yet on GitHub** (`gh repo create vista-cloud-dev/v-web` is a user action — push owed).
- [stdnet-iris-crlf-rawread-gap](stdnet-iris-crlf-rawread-gap.md) — **m-stdlib FOLLOW-UP** found by M6.3: `$$read^STDNET` on IRIS (`readIris`) does a **CR-terminated read** — `read x#n:t` stops at the first CR and **strips CRLF** — so HTTP framing (`\r\n\r\n`) is destroyed and `$$serve^STDHTTPD` returns 400 over an IRIS socket. STDNET's loopback suite used terminator-free payloads ("ping") so never caught it. **Repro + fix sketch inside.** This is the one thing standing between M6.3 and a dual-engine-green serve vertical; it is an **m-stdlib (STDNET) increment**, NOT v-web (the v-web session must not touch STDNET).
