VWEBT	; v-web — traffic-tap health/fidelity console (Phase 4 / M3, spec §8/§8.1).
	;
	; The RPC+HL7->S3 tap CAPTURES safely (VSLTAP/VSLRPCTAP), SHIPS faithfully
	; (VSLS3), and PROVES byte-equality by comparison (VSLTAPFC). VWEBT makes that
	; OBSERVABLE: a GET /traffic/health endpoint that reads the live tap
	; instruments and serves them as one Server-Sent-Events snapshot.
	;
	; READER + operator toggle. Every metric here already exists in the VSL*
	; instruments: $$state/$$healthy/$$enabled/$$disabled/$$size/$$offWindows^
	; VSLTAP, $$writes/$$bytes/$$denied/$$pctl/$$ready^VSLTAPHL, the consumer flag
	; via $$cfg^VSLTAP, and the last fidelity run via $$lastFidelity^VSLTAPFC. VWEBT
	; adds NO capture or egress logic; the only mutation is the operator tap toggle
	; (POST /traffic/tap -> arm/off/rearm^VSLTAP). A GET /traffic SPA renders it live.
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
	;   routes(.SRV)         — register the /traffic console routes
	;   snapshot(.J)         — build the tap-health snapshot (a typed-node object)
	;   health(.REQ,.RSP)    — the GET /traffic/health SSE handler
	;   tap(.REQ,.RSP)       — the POST /traffic/tap operator toggle (arm/off/rearm)
	;   console(.REQ,.RSP)   — the GET /traffic operator SPA (self-contained HTML)
	;
	quit
	;
routes(SRV)	; Register the console routes: the SSE health snapshot + the operator toggle.
	; doc: @param SRV  array  by-ref route table (STDHTTPD), populated by side-effect
	; Called from routes^VWEBR (which registers the VWEBA auth middleware first, so
	; these routes are protected). The handlers stay auth-agnostic (identity is the
	; middleware's job). POST /traffic/tap is the operator kill-switch (arm/off/rearm).
	do route^STDHTTPD(.SRV,"GET","/traffic","console^VWEBT")
	do route^STDHTTPD(.SRV,"GET","/traffic/health","health^VWEBT")
	do route^STDHTTPD(.SRV,"POST","/traffic/tap","tap^VWEBT")
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
	; --- the D-7 latency bound (the A/B "within-noise" threshold the SPA shows) ---
	set J("latbound")="n:"_$$cfg^VSLTAP("latbound",250)
	; --- the last fidelity run (VSLTAPFC persists it; "pending" until one runs) ---
	do fidelity(.J)
	quit
	;
fidelity(J)	; (private) read VSLTAPFC's last persisted fidelity run into J("fidelity",...).
	; doc: @internal  $$lastFidelity^VSLTAPFC returns the _fidelity manifest line (or "");
	; doc: "" -> status pending (honest, no fabricated %). A real run -> match %, the
	; doc: matched/mismatch/missing/extra counts, status (ok|mismatch), and the timestamp.
	new line,t,matched,mismatch,missing,total
	set line=$$lastFidelity^VSLTAPFC()
	set J("fidelity")="o"
	if line="" set J("fidelity","status")="s:pending" quit
	; Clear any stale $ECODE before parsing: a non-empty $ECODE on entry makes
	; STDJSON's IRIS parseObject loop (`quit:done!($ecode'="")`) bail after the
	; opening brace, returning an EMPTY tree on a perfectly valid manifest. This is
	; an m-stdlib STDJSON-on-IRIS fragility (the snapshot path runs in a fresh frame,
	; so clearing here is safe — no real error is pending). See v-web memory.
	set $ecode=""
	if '$$parse^STDJSON(line,.t) set J("fidelity","status")="s:pending" quit
	set matched=+$$valueOf^STDJSON($get(t("matched")))
	set mismatch=+$$valueOf^STDJSON($get(t("mismatch")))
	set missing=+$$valueOf^STDJSON($get(t("missing")))
	set total=matched+mismatch+missing
	set J("fidelity","status")=$select($$type^STDJSON($get(t("ok")))="true":"s:ok",1:"s:mismatch")
	set J("fidelity","matched")="n:"_matched
	set J("fidelity","mismatch")="n:"_mismatch
	set J("fidelity","missing")="n:"_missing
	set J("fidelity","extra")="n:"_(+$$valueOf^STDJSON($get(t("extra"))))
	set J("fidelity","pct")="n:"_$select(total:(matched*100)\total,1:0)
	set J("fidelity","ts")="s:"_$$valueOf^STDJSON($get(t("ts")))
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
	;
tap(REQ,RSP)	; POST /traffic/tap?action=arm|off|rearm -> apply, then return the fresh snapshot.
	; doc: @param REQ  array  by-ref request: the action in the query string (?action=)
	; doc: @param RSP  array  by-ref response: the post-action snapshot (RSP("json")) or 400
	; READER + toggle only: the only mutation is arm/off/rearm^VSLTAP — all safety,
	; capture and egress logic stays in VSLTAP. Operator action, so VWEBA gates it
	; (/traffic/tap is not an open path). Returns the fresh snapshot so the UI reflects
	; the new state at once. rearm clears a clean auto-failover cool-down (spec D-4).
	new action,J
	set action=$$action(.REQ)
	if '$$apply(action) do fail(.RSP,400,"action must be one of: arm, off, rearm") quit
	do snapshot(.J)
	kill RSP
	merge RSP("json")=J
	set RSP("status")=200
	quit
	;
apply(action)	; (private) apply one operator action to the tap; 1 iff recognised.
	; doc: @internal  The toggle calls ONLY these three VSLTAP controls — nothing more.
	if action="arm" do arm^VSLTAP quit 1
	if action="off" do off^VSLTAP quit 1
	if action="rearm" do rearm^VSLTAP quit 1
	quit 0
	;
action(REQ)	; (private) resolve the requested action from the ?action= query parameter.
	; doc: @internal  Query string only: the SPA POSTs /traffic/tap?action=off. A JSON
	; doc: body is deliberately NOT parsed — a single-member object trips an
	; doc: STDJSON-on-IRIS parse bug, and the toggle's payload is always single-member.
	quit $get(REQ("query","action"))
	;
fail(RSP,status,diag)	; (private) a minimal JSON error response (status + {"error":diag}).
	; doc: @internal
	kill RSP
	set RSP("status")=status
	set RSP("json")="o"
	set RSP("json","error")="s:"_diag
	quit
	;
console(REQ,RSP)	; GET /traffic -> the self-contained operator SPA (text/html).
	; doc: @param REQ  array  by-ref request (unused; the page is static)
	; doc: @param RSP  array  by-ref response: 200 text/html, the whole console in one page
	; A thin route over a hand-rolled page (the one place hand-written HTML/JS is OK —
	; it serves INSIDE VistA, so it is dependency-free: no CDN, no build). The page
	; opens an EventSource on /traffic/health (the live cadence; EventSource auto-
	; reconnects per the snapshot's retry: field) and POSTs /traffic/tap for the toggle.
	; SSE-auth: the browser EventSource cannot set Authorization, so the page forwards
	; its own ?access_token (VWEBA accepts it for /traffic/* only — see VWEBA traffic()).
	kill RSP
	set RSP("status")=200
	set RSP("hdr","Content-Type")="text/html; charset=utf-8"
	set RSP("body")=$$page()
	quit
	;
page()	; (private) build the whole operator console as one HTML document.
	; doc: @internal  Single-quoted HTML/JS throughout (no embedded double quotes), so
	; doc: the M string literals need no escaping; the page is assembled deterministically.
	new h,nl
	set nl=$char(10)
	set h="<!doctype html>"_nl
	set h=h_"<html lang='en'><head><meta charset='utf-8'>"_nl
	set h=h_"<meta name='viewport' content='width=device-width,initial-scale=1'>"_nl
	set h=h_"<title>VistA RPC+HL7 traffic tap</title>"_nl
	set h=h_"<style>"
	set h=h_"body{font-family:system-ui,sans-serif;margin:1.2rem;background:#0b1020;color:#e6e9ef}"
	set h=h_"h1{font-size:1.1rem}h2{font-size:.8rem;margin:0 0 .5rem;color:#9fb3ff;text-transform:uppercase;letter-spacing:.04em}"
	set h=h_".panel{display:inline-block;vertical-align:top;border:1px solid #2a3550;border-radius:8px;padding:1rem;margin:.4rem;min-width:13rem}"
	set h=h_".v{font-size:1.2rem;font-weight:600}.ok{color:#5ad17a}.bad{color:#ff6b6b}.warn{color:#ffcc66}.muted{color:#8a93a6;font-size:.85rem}"
	set h=h_"button{margin:.2rem;padding:.45rem .9rem;border-radius:6px;color:#e6e9ef;cursor:pointer;background:#18213d;border:1px solid #34406a}"
	set h=h_"button:hover{background:#222d52}"
	set h=h_"</style></head><body>"_nl
	set h=h_"<h1>VistA RPC+HL7 traffic tap - operator console</h1>"_nl
	set h=h_"<div id='conn' class='muted'>connecting...</div>"_nl
	set h=h_"<div><button id='arm'>Arm</button><button id='off'>Off</button><button id='rearm'>Re-arm</button></div>"_nl
	set h=h_"<div>"_nl
	set h=h_$$panelStandby()_$$panelAb()_$$panelFidelity()_$$panelSpool()
	set h=h_"</div>"_nl
	set h=h_"<script>"_nl_$$js()_nl_"</script>"_nl
	set h=h_"</body></html>"_nl
	quit h
	;
panelStandby()	; (private) the standby-readiness panel markup.
	new p
	set p="<div class='panel'><h2>Standby readiness</h2>"
	set p=p_"<div>state <span id='state' class='v'>-</span></div>"
	set p=p_"<div class='muted'>healthy <span id='healthy'>-</span> | ready <span id='ready'>-</span> | capture <span id='enabled'>-</span></div></div>"
	quit p
	;
panelAb()	; (private) the A/B-latency panel markup.
	new p
	set p="<div class='panel'><h2>A/B latency</h2>"
	set p=p_"<div class='muted'>p50 <span id='p50'>-</span> | p95 <span id='p95'>-</span> | p99 <span id='p99'>-</span> us</div>"
	set p=p_"<div>verdict <span id='ab' class='v'>-</span></div></div>"
	quit p
	;
panelFidelity()	; (private) the fidelity-proof panel markup.
	new p
	set p="<div class='panel'><h2>Fidelity</h2>"
	set p=p_"<div><span id='fid' class='v'>-</span></div>"
	set p=p_"<div id='fidc' class='muted'>-</div></div>"
	quit p
	;
panelSpool()	; (private) the spool / off-window panel markup.
	new p
	set p="<div class='panel'><h2>Spool</h2>"
	set p=p_"<div class='muted'>ring <span id='ring'>-</span> | writes <span id='writes'>-</span> | denied <span id='denied'>-</span></div>"
	set p=p_"<div class='muted'>off-windows <span id='offwindows'>-</span> | auto-failover <span id='disabled'>-</span></div></div>"
	quit p
	;
js()	; (private) the page script: EventSource render loop + the toggle (single-quoted).
	new s,nl
	set nl=$char(10)
	set s="var P=new URLSearchParams(location.search),tok=P.get('access_token')||'';"_nl
	set s=s_"var Q=tok?('?access_token='+encodeURIComponent(tok)):'';"_nl
	set s=s_"function g(i){return document.getElementById(i)}"_nl
	set s=s_"function S(i,v,c){var e=g(i);if(!e)return;e.textContent=v;if(c)e.className=c}"_nl
	set s=s_"function C(t){var e=g('conn');if(e)e.textContent=t}"_nl
	set s=s_"function render(d){var st=d.state;"_nl
	set s=s_"S('state',st,st=='OFF'?'v warn':((st=='AUTO-DISABLED'||st=='UNHEALTHY')?'v bad':'v ok'));"_nl
	set s=s_"S('healthy',d.healthy?'yes':'no');S('ready',d.ready?'yes':'no');S('enabled',d.enabled?'capturing':'idle');"_nl
	set s=s_"S('p50',d.p50);S('p95',d.p95);S('p99',d.p99);"_nl
	set s=s_"var trip=(d.disabled=='latency');"_nl
	set s=s_"S('ab',trip?('LATENCY TRIP (>'+d.latbound+' us)'):'within noise',trip?'v bad':'v ok');"_nl
	set s=s_"S('ring',d.ring);S('writes',d.writes);S('denied',d.denied);S('offwindows',d.offwindows);S('disabled',d.disabled||'(clean)');"_nl
	set s=s_"var f=d.fidelity||{};"_nl
	set s=s_"if(f.status=='pending'){S('fid','last-run pending','v warn');S('fidc','no comparison run yet')}"_nl
	set s=s_"else{var ok=(f.status=='ok');S('fid',f.pct+'% fidelity ('+f.status+')',ok?'v ok':'v bad');"_nl
	set s=s_"S('fidc',f.matched+' matched / '+f.mismatch+' diff / '+f.missing+' missing / '+f.extra+' extra @ '+f.ts)}}"_nl
	set s=s_"function openStream(){var es=new EventSource('/traffic/health'+Q);"_nl
	set s=s_"es.addEventListener('health',function(ev){C('live');render(JSON.parse(ev.data))});"_nl
	set s=s_"es.onerror=function(){C('reconnecting...')}}"_nl
	set s=s_"function tap(a){var u='/traffic/tap?action='+a+(tok?('&access_token='+encodeURIComponent(tok)):'');"_nl
	set s=s_"fetch(u,{method:'POST'}).then(function(r){return r.json()}).then(render).catch(function(){C('toggle failed')})}"_nl
	set s=s_"g('arm').addEventListener('click',function(){tap('arm')});"_nl
	set s=s_"g('off').addEventListener('click',function(){tap('off')});"_nl
	set s=s_"g('rearm').addEventListener('click',function(){tap('rearm')});"_nl
	set s=s_"openStream();"
	quit s
