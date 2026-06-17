VWEBIO	; v-web — engine device/TLS transport adapter (M6.3, spec §3/§9).
	;
	; The bridge from STDHTTPD's injected-transport contract down to STDNET +
	; the engine socket layer. It owns four jobs, and nothing else (the m/v
	; waterline keeps the codec, framework, and socket primitives in m-stdlib):
	;
	;   1. Build the transport descriptor STDHTTPD's $$serve consumes —
	;      TR("read")/TR("write") entry-refs + the opaque `conn` handle.
	;   2. Provide signature-compatible read/write wrappers over STDNET so the
	;      framework reaches the wire through this seam (and, later, TLS) only.
	;   3. Open / accept / close the listening socket over STDNET (dual-engine
	;      since M2.T1).
	;   4. Bind a NAMED server TLS config (spec §9) — HTTP-first, TLS-gap-loud:
	;      no engine TLS plugin is wired yet (M2.T2 infra-blocked), so the TLS
	;      path raises a clear ,U-VWEB-NOTLS, rather than silently serving
	;      plaintext on the TLS port.
	;
	; Layer: v. Consumes m-stdlib STDNET only (v -> m, one-way).
	;
	; Public:
	;   transport(.TR)              — fill TR with the read/write seam refs
	;   $$read(conn,max,tmo,.buf)   — wrapper over $$read^STDNET (by-ref buf)
	;   $$write(conn,bytes)         — wrapper over $$write^STDNET
	;   $$listen(port)              — open a plaintext listening socket
	;   $$boundport(id)             — the OS-assigned bound port
	;   $$accept(id,tmo)            — accept one connection
	;   $$close(id)                 — close a handle (idempotent)
	;   $$listenTls(port,config)    — TLS listener (raises ,U-VWEB-NOTLS, today)
	;   $$tlsAvailable()            — 1 iff a server TLS socket can be opened
	;   $$lastError()               — detail behind the last raised error
	;
	quit
	;
transport(TR)	; Build the transport descriptor STDHTTPD's $$serve consumes.
	; doc: @param TR  array  by-ref; receives TR("read")/TR("write") entry-refs
	; The refs are invoked by $$serve via full-argument indirection as
	;   $$@TR("read")(conn,max,tmo,.buf) / $$@TR("write")(conn,bytes)
	; so the wrappers below MUST match $$read/$$write^STDNET signatures exactly.
	set TR("read")="read^VWEBIO"
	set TR("write")="write^VWEBIO"
	quit
	;
read(conn,max,timeout,buf)	; Raw-read up to `max` bytes (signature-compatible with $$read^STDNET).
	; doc: @param conn     numeric  a connected handle
	; doc: @param max      numeric  maximum bytes to read
	; doc: @param timeout  numeric  seconds to wait for data
	; doc: @param buf      string   by-ref; receives the bytes read
	; doc: @returns        numeric  bytes read (0 on timeout/EOF)
	quit $$read^STDNET(conn,max,timeout,.buf)
	;
write(conn,bytes)	; Raw-write bytes (signature-compatible with $$write^STDNET).
	; doc: @param conn   numeric  a connected handle
	; doc: @param bytes  string   bytes to write (raw, no delimiter)
	; doc: @returns      bool     1 on success; 0 on failure
	quit $$write^STDNET(conn,bytes)
	;
listen(port)	; Open a plaintext listening socket on `port` (0 = OS-assigned).
	; doc: @param port  numeric  TCP port to bind; 0 lets the OS choose
	; doc: @returns     numeric  a listener handle (>0), or 0 on failure
	quit $$listen^STDNET(port)
	;
boundport(id)	; The OS-assigned bound port of a listener handle.
	; doc: @param id  numeric  a listener handle from $$listen
	; doc: @returns   numeric  the bound TCP port
	quit $$boundport^STDNET(id)
	;
accept(id,timeout)	; Accept one pending connection on a listener handle.
	; doc: @param id       numeric  a listener handle from $$listen
	; doc: @param timeout  numeric  seconds to wait for a connection
	; doc: @returns        numeric  a connected handle (>0), or 0 on timeout
	quit $$accept^STDNET(id,timeout)
	;
close(id)	; Close and free a handle (idempotent).
	; doc: @param id  numeric  a handle from $$listen/$$accept
	; doc: @returns   bool     1
	quit $$close^STDNET(id)
	;
listenTls(port,config)	; Open a TLS listening socket bound to a NAMED server TLS config (§9).
	; doc: @param port    numeric  the TLS port
	; doc: @param config  string   the named server TLS config (from XPAR)
	; doc: @returns       numeric  a listener handle (>0)
	; doc: @raises U-VWEB-NOTLS  no engine TLS plugin / config is wired here
	; HTTP-first, gap-loud: the operator-provisioned engine TLS plugin (IRIS
	; SSL/TLS config or YDB ydb_crypt_config) is not wired yet (M2.T2). Raise
	; loudly rather than serve plaintext on the TLS port; live TLS is an infra
	; follow-up (same posture as VSLIO's $$connectTls).
	do raise("U-VWEB-NOTLS",",U-VWEB-NOTLS, listenTls: TLS config '"_$get(config)_"' (port "_$get(port)_") requested but no engine TLS plugin is wired — HTTP-first (live TLS owed: M2.T2)")
	quit 0
	;
tlsAvailable()	; 1 iff a server TLS socket can be opened here. Always 0 (the gap).
	; doc: @returns bool  0 — no engine TLS plugin wired (a tracked gap, M2.T2)
	quit 0
	;
raise(code,msg)	; (private) stash the detail, then raise the clean ,<code>, $ECODE.
	set ^TMP($job,"vwebio","err")=msg
	set $ecode=","_code_","
	quit
	;
lastError()	; The detail stashed behind the last raised error (or "").
	; doc: @returns string  the last error detail
	quit $get(^TMP($job,"vwebio","err"))
