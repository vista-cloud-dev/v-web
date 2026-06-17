# v-web — Claude Project Context

**VistA Web Services**: `VWEB*` M routines — the inbound socket adapter that
drives the m-stdlib `STDHTTPD` server framework over a **real socket**. The
first VistA-coupled milestone (M6.3) of the M6 HTTPS-stack capstone. Defers to
`~/vista-cloud-dev/CLAUDE.md` (org rules: increment protocol, m/v waterline,
in-org memory routing) and `~/.claude/CLAUDE.md` (global).

## Layer — this repo is `v` (above the waterline)

v-web is **VistA-specific** (needs Kernel/TaskMan/^%ZIS/XPAR). The waterline
rule (`docs/background/m-v-waterline-adr.md` in the `docs` repo) is binding:

- **Dependency is one-way: `v → m`.** A `VWEB*` routine MAY call an `STD*`
  routine (and a `VSL*` routine, v→v); an `STD*` routine MUST NOT call a
  `VWEB*`/`VSL*` routine. Never invert it.
- Layer is declared in `repo.meta.json` (`"layer": "v"`) and enforced by
  `m arch check` (G1–G4 + meta-shape).
- VistA vocabulary (KIDS, XPAR, TaskMan, ^%ZIS) lives **here**, never below the
  waterline in m-stdlib.

## What v-web is (and is NOT)

- **IS:** the *thin VistA-binding shell* — how the listener launches (TaskMan
  via `VSLTASK`), how the socket opens/accepts (over `STDNET`), how the
  transport is handed to `STDHTTPD`'s `$$serve`, and how a named server TLS
  config binds (XPAR, gap-loud).
- **IS NOT:** the HTTP codec (`STDHTTPMSG`), the server framework / router /
  middleware / worker loop (`STDHTTPD`), or the socket primitives (`STDNET`) —
  those are consumed from m-stdlib through their pinned seams, **never
  re-implemented**. Routes (M6.4 FHIR `/Patient`) and auth (M6.5) are NOT here.

## The seams v-web consumes (pinned)

- **m-stdlib (MSL v0.12.0):** `$$serve^STDHTTPD` (the injected-transport worker
  loop) + `$$route^STDHTTPD`; `$$listen`/`$$accept`/`$$boundport`/`$$read`/
  `$$write`/`$$close`/`$$available^STDNET` (sockets, dual-engine since M2.T1).
- **v-stdlib:** `$$schedule`/`$$stop`/`$$persist`/`$$running^VSLTASK` (TaskMan),
  `$$get^VSLCFG` (XPAR config), `$$check^VSLENV` (env-check). All VistA access is
  delegated to these resident `VSL*` routines — v-web makes **no direct `^XPAR`/
  `^%ZIS`/Kernel call**, so the ICR registry stays empty/green.

## Conventions

- **Modern style** (pythonic-lower, `.m-cli.toml` `rules = "modern"`) — not
  VistA-compact. New library, modern idiom.
- **TDD — hard rule:** write `tests/VWEB*TST.m` first (`^STDASSERT`, staged from
  m-stdlib), confirm red, implement, confirm green. TDD-red stubs return safe
  defaults, never `$ECODE`.
- **Dual-engine:** YDB + IRIS; keep IRIS-portable (mirror m-stdlib's
  `$ZVERSION["IRIS"` arms where engine syntax diverges). The socket handoff
  (spec D1) is the one engine-sensitive seam, isolated in `VWEBL`.
- **Error idiom:** flag-based `$ETRAP`, **never zgoto** (a zgoto trap aborts the
  resident harness). `$ECODE` format `,U-VWEB-<CODE>,`; detail in
  `^TMP($job,"<routine>","err")`. TLS-absent is **loud** (`,U-VWEB-NOTLS,`),
  never a silent plaintext fallback on the TLS port.
- **HTTP-first, TLS-gap-loud:** the dev/test path is plaintext loopback; the TLS
  code path is bound + loud (live TLS verification is an infra follow-up — M2.T2
  blocked).
- **Gates before commit:** `make check-fast` (fmt/lint/arch + drift gates,
  engine-free) + `make test` (engine-bound). Lint `--error-on=error` zero.

## Engine access — driver stack ONLY

Reach the engines ONLY through the `m` toolchain (`m test --engine ydb|iris
--docker <c>`). Pure socket/accept logic (STDNET loopback) is proven on the bare
test engines (`m-test-engine` YDB, `m-test-iris` IRIS); the VistA-coupled bits
(TaskMan launch, XPAR TLS) verify on YDB-VistA `vehu` + IRIS-VistA `foia*` over
the driver. **NEVER** raw `docker exec`/`iris session`/`mumps -direct` (the
`engine-stack-guard` hook denies it).

## Status

**M6.3** (2026-06-17): the `vweb` listener — `VWEBIO` (device/transport adapter)
+ `VWEBL` (listener launcher + serial accept→serve→close loop) + `VWEBCFG` (XPAR
config) + `VWEBENV` (KIDS env-check). HTTP-first; serial before concurrent (the
jobbed-worker D1 handoff is a separately-tested later layer). Tracker: the
`docs` repo `docs/vsl-msl/vsl-implementation-tracker.md` + the in-repo
`docs/implementation-tracker.md`.
