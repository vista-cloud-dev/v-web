VWEBCFG	; v-web — configuration accessor over XPAR (spec §11).
	;
	; All tunables are XPAR parameters under the package (SYS scope). Reads are
	; delegated to $$get^VSLCFG (v -> v) — VWEB makes NO direct ^XPAR call, so
	; the ICR registry stays empty and the no-direct-global gate is trivially
	; green. A missing parameter yields the documented default (VSLCFG's
	; contract). The listener (VWEBL) and the suites run these on a VistA
	; instance, where XPAR is present, and $text-guard the bare-engine path
	; (XPAR absent) above this seam — so VWEBCFG itself stays a clean delegation.
	; Live values are owed on vehu/foia.
	;
	; Public:
	;   $$port()         — VWEB LISTEN PORT      (default 8089)
	;   $$tlsConfig()    — VWEB TLS SERVER CONFIG (default "" — HTTP-first)
	;   $$idleTimeout()  — VWEB IDLE TIMEOUT      (default 30 s)
	;   $$maxBody()      — VWEB MAX BODY          (default 1048576 bytes)
	;   $$maxWorkers()   — VWEB MAX WORKERS       (default 1 — serial v0.1)
	;
	quit
	;
port()	; VWEB LISTEN PORT — the inbound port.
	; doc: @returns numeric  the configured listen port, or 8089
	quit $$getNum("VWEB LISTEN PORT",8089)
	;
tlsConfig()	; VWEB TLS SERVER CONFIG — the named server TLS config (§9).
	; doc: @returns string  the config name, or "" (HTTP-first)
	quit $$get("VWEB TLS SERVER CONFIG","")
	;
idleTimeout()	; VWEB IDLE TIMEOUT — keep-alive idle seconds.
	; doc: @returns numeric  the idle timeout in seconds, or 30
	quit $$getNum("VWEB IDLE TIMEOUT",30)
	;
maxBody()	; VWEB MAX BODY — max inbound body bytes.
	; doc: @returns numeric  the max body size in bytes, or 1048576
	quit $$getNum("VWEB MAX BODY",1048576)
	;
maxWorkers()	; VWEB MAX WORKERS — concurrency cap (1 = serial, the v0.1 default).
	; doc: @returns numeric  the worker cap, or 1
	quit $$getNum("VWEB MAX WORKERS",1)
	;
get(key,default)	; Read parameter `key` at SYS, else `default` — delegated to
	; VSLCFG (v -> v). VWEB makes no direct ^XPAR call (the binding + its ICR
	; live in VSLCFG, below). Runs on a VistA instance where XPAR is present;
	; the bare-engine path is the caller's concern (the listener body and the
	; tests guard with $text before reaching here).
	; doc: @param key      string  the XPAR parameter name
	; doc: @param default  string  value returned when the parameter is unset
	; doc: @returns        string  the SYS-level value, or `default`
	quit $$get^VSLCFG(key,$get(default))
	;
getNum(key,default)	; Numeric variant of $$get.
	; doc: @param key      string   the XPAR parameter name
	; doc: @param default  numeric  value returned when the parameter is unset
	; doc: @returns        numeric  the value as a number, or `default`
	new v
	set v=$$get(key,$get(default))
	quit:v="" +$get(default)
	quit +v
