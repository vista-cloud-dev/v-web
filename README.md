# v-web — VistA Web Services

`VWEB*` M routines: the **inbound socket adapter** that drives the m-stdlib
[`STDHTTPD`](https://github.com/vista-cloud-dev/m-stdlib) server framework over a
**real socket**, on both YottaDB and IRIS — zero non-M components. v-web is the
first VistA-coupled milestone (M6.3) of the M6 HTTPS-stack capstone: a request
enters over a live socket, is served by the portable framework, and the
byte-exact response is written back.

- **Layer:** `v` (VistA-specific) — needs Kernel/TaskMan/^%ZIS/XPAR. Declared in
  [`repo.meta.json`](repo.meta.json); enforced by `m arch check` (the waterline
  G1 dependency-direction gate — `v → m` only).
- **Dual-engine:** YottaDB + IRIS.
- **Consumes:** `m-stdlib` (`STDHTTPD`/`STDHTTPMSG`/`STDNET`, pinned MSL
  v0.12.0) and `v-stdlib` (`VSLTASK`/`VSLCFG`/`VSLENV`) upward; never the
  reverse.

## Modules

| Routine  | Role |
|----------|------|
| `VWEBIO` | Engine device/TLS transport adapter: builds the transport descriptor `STDHTTPD`'s `$$serve` consumes (`TR("read")`/`TR("write")`), opens/accepts the listening socket over `STDNET`, binds a named server TLS config (gap-loud). |
| `VWEBL`  | Listener launcher + accept-loop + worker handoff: a TaskMan-startable entry (`VSLTASK`) that loops `$$accept` and, per connection, runs `do serve^STDHTTPD` over a `VWEBIO` transport, then accepts the next. v0.1 is single-process serial; jobbed-worker concurrency (spec D1) is a separately-tested later layer. |
| `VWEBCFG`| Configuration accessor over XPAR (port, TLS config, idle timeout, max body) — delegated to `$$get^VSLCFG`, fault-tolerant defaults. |
| `VWEBENV`| KIDS environment check — extends `VSLENV` (engine + Kernel + TLS-config presence). |

## Scope (M6.3)

The route table is **health-only** (`GET /healthz`). FileMan routes (FHIR
`/Patient`) are M6.4; auth (DUZ/#200 bind) is M6.5; the §9 TLS smoke test is
M6.6. **HTTP-first, TLS-gap-loud** — the TLS path is bound and raises a loud
`,U-VWEB-NOTLS,` rather than silently serving plaintext on the TLS port; live
TLS verification is an infra follow-up (M2.T2 blocked).

See the VSL/MSL effort tracker in
[`docs/vsl-msl/vsl-implementation-tracker.md`](https://github.com/vista-cloud-dev/docs/blob/main/vsl-msl/vsl-implementation-tracker.md)
and the HTTPS-stack spec `docs/vsl-msl/https-stack-spec.md`.
