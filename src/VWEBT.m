VWEBT	; v-web — traffic-tap health/fidelity console (Phase 4 / M3, spec §8/§8.1).
	;
	; The RPC+HL7->S3 tap CAPTURES safely (VSLTAP/VSLRPCTAP), SHIPS faithfully
	; (VSLS3), and PROVES byte-equality by comparison (VSLTAPFC). VWEBT makes that
	; OBSERVABLE: a GET /traffic/health endpoint that reads the live tap
	; instruments and serves them as one Server-Sent-Events snapshot.
	;
	; READER, not a second source of truth. Every value here already exists in the
	; VSL* instruments: $$state/$$healthy/$$enabled/$$disabled/$$size/$$offWindows^
	; VSLTAP, $$writes/$$bytes/$$denied/$$pctl/$$ready^VSLTAPHL, and the consumer
	; flag via $$cfg^VSLTAP. VWEBT adds NO capture or egress logic; the operator
	; tap toggle (arm/off) and the fidelity-run panel are later increments.
	;
	; SSE over the current framework: STDHTTPD serializes one response with
	; Content-Length and closes (no server-side chunking in v0.1), so this emits a
	; correct text/event-stream snapshot PER REQUEST. A browser EventSource
	; auto-reconnects (the `retry:` field paces it), giving a live cadence without a
	; long-lived connection. A true single-connection multi-event push needs an
	; STDHTTPD chunked/streaming response — an m-stdlib (below-the-waterline) gap,
	; out of scope for this v-web phase.
	;
	; Layer: v. Consumes STDHTTPD/STDJSON (m) + VSLTAP/VSLTAPHL (v, v->v). No
	; direct VistA call (no ^XPAR/^DPT/Kernel), so the ICR registry stays empty.
	; Auth: /traffic/health is NOT an open path, so VWEBA's middleware gates it
	; (operator-facing metrics, not anonymous liveness — that stays /healthz).
	;
	; Public:
	;   routes(.SRV)         — register GET /traffic/health -> health^VWEBT
	;   snapshot(.J)         — build the tap-health snapshot (a typed-node object)
	;   health(.REQ,.RSP)    — the GET /traffic/health SSE handler
	;
	quit
	;
routes(SRV)	; Register the console route: GET /traffic/health.
	; doc: @param SRV  array  by-ref route table (STDHTTPD), populated by side-effect
	; Called from routes^VWEBR (which registers the VWEBA auth middleware first, so
	; this route is protected). health stays auth-agnostic (identity is middleware).
	do route^STDHTTPD(.SRV,"GET","/traffic/health","health^VWEBT")
	quit
	;
snapshot(J)	; Build the tap-health snapshot as a typed-node JSON object (spec §8/§8.1).
	; doc: @param J  array  by-ref STDJSON typed-node tree (populated by side-effect)
	; A pure reader: it mirrors the live VSLTAP/VSLTAPHL instruments and runs the
	; (network-free) standby readiness probe. "n:" = JSON number, "s:" = string.
	new tmp
	kill J
	set J="o"
	; --- standby state machine + liveness (§8.1) ---
	set J("state")="s:"_$$state^VSLTAP
	set J("healthy")="n:"_$$healthy^VSLTAP
	set J("ready")="n:"_$$ready^VSLTAPHL
	; --- the capture gate (armed AND not auto-disabled AND (consumer OR alwayson)) ---
	set J("enabled")="n:"_$$enabled^VSLTAP
	set J("consumer")="n:"_(+$$cfg^VSLTAP("consumer",0))
	set J("alwayson")="n:"_(+$$cfg^VSLTAP("alwayson",0))
	; --- auto-failover (reason "" when armed/clean) + the explicit off-window log ---
	set J("disabled")="s:"_$$disabled^VSLTAP
	set J("offwindows")="n:"_$$offWindows^VSLTAP(.tmp)
	; --- the rolling ring / spool depth ---
	set J("ring")="n:"_$$size^VSLTAP
	set J("head")="n:"_$$head^VSLTAP
	set J("tail")="n:"_$$tail^VSLTAP
	; --- throughput counters + the tapped-latency percentiles (the A/B panel) ---
	set J("writes")="n:"_$$writes^VSLTAPHL
	set J("bytes")="n:"_$$bytes^VSLTAPHL
	set J("denied")="n:"_$$denied^VSLTAPHL
	set J("p50")="n:"_$$pctl^VSLTAPHL(50)
	set J("p95")="n:"_$$pctl^VSLTAPHL(95)
	set J("p99")="n:"_$$pctl^VSLTAPHL(99)
	quit
	;
health(REQ,RSP)	; GET /traffic/health -> one SSE-framed snapshot event (text/event-stream).
	; doc: @param REQ  array  by-ref parsed request (unused; the snapshot is global)
	; doc: @param RSP  array  by-ref response: status + raw body + event-stream hdrs
	; Sets RSP("body") directly (not RSP("json")) so the Content-Type stays
	; text/event-stream; STDHTTPD's serializeRsp honours a caller-set Content-Type.
	new J,json,lf
	do snapshot(.J)
	set json=$$encode^STDJSON(.J)
	set lf=$char(10)
	kill RSP
	set RSP("status")=200
	set RSP("hdr","Content-Type")="text/event-stream"
	set RSP("hdr","Cache-Control")="no-cache"
	; one `health` event; `retry` paces the EventSource reconnect (the live cadence)
	set RSP("body")="retry: 5000"_lf_"event: health"_lf_"data: "_json_lf_lf
	quit
