VWEBL	; v-web — inbound listener launcher + accept-loop + worker handoff (§4).
	;
	; The process model (spec §4): a TaskMan-startable listener opens the
	; socket (port from XPAR), loops $$accept, and per connection runs the full
	; HTTP exchange via STDHTTPD's $$serve over a VWEBIO transport, then accepts
	; the next. STDHTTPD already owns the read loop, framing, parse, dispatch,
	; serialize, and keep-alive — VWEBL adds ONLY the socket open/accept, the
	; transport handoff, and the TaskMan launch (the m/v waterline).
	;
	; v0.1 is single-process SERIAL (accept -> serve -> close -> accept; no
	; JOB-off): the full vertical proven end-to-end on both engines first. The
	; jobbed-worker concurrency — the spec-D1 socket handoff, the one engine-
	; sensitive seam — is a separately-tested later layer behind a
	; $zversion["IRIS" fork, not a blocker on the vertical.
	;
	; Layer: v. Consumes STDHTTPD/STDNET (m) via VWEBIO + VSLTASK/VWEBCFG (v).
	;
	; Public:
	;   $$launch()                  — TaskMan entry: schedule the listener (VSLTASK)
	;   run()                       — the listener body (the scheduled task)
	;   $$serveConn(.SRV,conn,.opts)— run one connection's exchange, then close it
	;   $$acceptOne(srv,.SRV,.opts,tmo) — accept + serve one connection
	;   healthRoutes(.SRV)          — the M6.3 route table (GET /healthz only)
	;   health(.REQ,.RSP)           — the /healthz handler
	;
	quit
	;
launch()	; TaskMan entry: schedule the persistent listener via VSLTASK. The
	; Kernel startup OPTION points here; VSLTASK queues + marks it persistent.
	; doc: @returns numeric  the queued (persistent) TaskMan task number
	; The live restart observation is infra-gated (the VSLTASK M5 posture); the
	; bind is asserted.
	quit $$schedule^VSLTASK("run^VWEBL","VWEB inbound HTTP(S) listener","@")
	;
run()	; The listener body (runs as the TaskMan task): open the socket on the
	; configured port and enter the serial accept-loop until $$stop^VSLTASK.
	new port,srv,SRV,opts,n
	set port=$$port^VWEBCFG()
	do healthRoutes(.SRV)
	set srv=$$listen^VWEBIO(port)
	if srv'>0 do raise("U-VWEB-LISTEN","run: could not open a listening socket on port "_port) quit
	set opts("idletimeout")=$$idleTimeout^VWEBCFG()
	set opts("maxbody")=$$maxBody^VWEBCFG()
	set n=$$acceptLoop(srv,.SRV,.opts)
	set n=$$close^VWEBIO(srv)
	quit
	;
acceptLoop(srv,SRV,opts)	; Serial accept -> serve -> close loop until cooperative
	; stop. The idle timeout doubles as the accept poll interval so $$stop is
	; rechecked between connections. Live observation infra-gated (VSLTASK M5
	; posture); acceptOne is the asserted unit.
	; doc: @param srv   numeric  the listening handle
	; doc: @param SRV   array    by-ref route table
	; doc: @param opts  array    by-ref STDHTTPD limits
	; doc: @returns     numeric  connections served before stop
	new nconn,tmo
	set nconn=0,tmo=$$idleTimeout^VWEBCFG()
	for  quit:$$stop^VSLTASK()  set nconn=nconn+$$acceptOne(srv,.SRV,.opts,tmo)
	quit nconn
	;
acceptOne(srv,SRV,opts,tmo)	; Accept (<=tmo s) and serve one connection.
	; doc: @param srv   numeric  the listening handle
	; doc: @param SRV   array    by-ref route table
	; doc: @param opts  array    by-ref STDHTTPD limits
	; doc: @param tmo   numeric  accept timeout in seconds (default 30)
	; doc: @returns     numeric  1 if a connection was served, 0 on accept timeout
	new conn,n
	set conn=$$accept^VWEBIO(srv,$get(tmo,30))
	if conn'>0 quit 0
	set n=$$serveConn(.SRV,conn,.opts)
	quit 1
	;
serveConn(SRV,conn,opts)	; Run one connection's full HTTP exchange over a VWEBIO
	; transport via STDHTTPD's worker loop, then close the socket. This is the
	; socket -> STDHTTPD seam (spec D1) in its simplest, single-process form.
	; doc: @param SRV   array    by-ref route table
	; doc: @param conn  numeric  a connected socket handle (from $$accept)
	; doc: @param opts  array    by-ref STDHTTPD limits (optional)
	; doc: @returns     numeric  requests served on this connection (keep-alive)
	new TR,n,ok
	do transport^VWEBIO(.TR)
	set n=$$serve^STDHTTPD(.SRV,.TR,conn,.opts)
	set ok=$$close^VWEBIO(conn)
	quit n
	;
healthRoutes(SRV)	; Register the M6.3 route table: GET /healthz only. FileMan
	; routes are M6.4; auth is M6.5 — the table stays health-only here.
	; doc: @param SRV  array  by-ref route table (populated by side-effect)
	do route^STDHTTPD(.SRV,"GET","/healthz","health^VWEBL")
	quit
	;
health(REQ,RSP)	; GET /healthz handler — a liveness probe (200 "ok").
	; doc: @param REQ  array  by-ref parsed request
	; doc: @param RSP  array  by-ref response (populate status/body)
	set RSP("status")=200
	set RSP("body")="ok"
	quit
	;
raise(code,msg)	; (private) stash the detail, then raise the clean ,<code>, $ECODE.
	set ^TMP($job,"vwebl","err")=msg
	set $ecode=","_code_","
	quit
	;
lastError()	; The detail stashed behind the last raised error (or "").
	; doc: @returns string  the last error detail
	quit $get(^TMP($job,"vwebl","err"))
