VWEBTTST	; v-web — VWEBT (traffic-tap health/fidelity console) suite.
	; Phase 4 / M3: the live health console reads the VSL* tap instruments and
	; serves them as one Server-Sent-Events snapshot. Three layers of proof:
	;   1. snapshot() — a pure reader that mirrors the live VSLTAP/VSLTAPHL state
	;      into a typed-node JSON object tree; deterministic, both bare engines.
	;   2. the handler via STDHTTPD's $$dispatch (fake transport, no socket): a
	;      GET /traffic/health -> 200 text/event-stream with an SSE-framed snapshot
	;      whose data: line is parseable JSON carrying the tap state; bare engines.
	;   3. the full socket vertical via $$serveConn^VWEBL — a real GET enters over a
	;      loopback socket and the event-stream response is read back; bare engines.
	; Plus the waterline guard that the console is auth-protected (VWEBA gates it).
	; Driver stack only (m/v waterline): m test --engine ydb|iris --docker ...
	; READ-ONLY: drives the tap's OWN globals (^VSLTAP / ^XTMP("VSLTAP")), which it
	; resets per test; touches no VistA file, so there is nothing to back out.
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tSnapshotShape(.pass,.fail)
	do tSnapshotReflectsOff(.pass,.fail)
	do tSnapshotDisabledReason(.pass,.fail)
	do tRoutesRegistered(.pass,.fail)
	do tHealthInVwebrTable(.pass,.fail)
	do tHealthIsEventStream(.pass,.fail)
	do tHealthDataParses(.pass,.fail)
	do tHealthIsProtected(.pass,.fail)
	do tHealthOverSocket(.pass,.fail)
	do tTapRegistered(.pass,.fail)
	do tTapRequiresAuth(.pass,.fail)
	do tTapArmsAndOffs(.pass,.fail)
	do tTapViaQueryOnPost(.pass,.fail)
	do tTapRearmCycle(.pass,.fail)
	do tTapRejectsBadAction(.pass,.fail)
	do tSnapshotFidelityPending(.pass,.fail)
	do tSnapshotFidelityPresent(.pass,.fail)
	do tConsoleRegistered(.pass,.fail)
	do tConsoleIsHtml(.pass,.fail)
	do tConsoleProtected(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
reset()	; Reset the tap's own globals to a clean, deterministic baseline.
	kill ^VSLTAP,^XTMP("VSLTAP")
	quit
	;
routesNoAuth(SRV)	; The real route table with the auth middleware stripped.
	; routes^VWEBR registers VWEBA's auth middleware ahead of every handler, so
	; /traffic/health is protected. This suite tests the HANDLER + ROUTING in
	; isolation (auth is VWEBATST's job), so it drives the table without the chain.
	do routes^VWEBR(.SRV)
	kill SRV("mw")
	quit
	;
rawByteSafe()	; 1 iff raw sockets preserve CRLF bytes end-to-end (HTTP framing needs it).
	new srv,cli,conn,port,n,cr,msg,buf,ok
	if '$$available^STDNET() quit 0
	set cr=$char(13,10),msg="a"_cr_"b"_cr_cr,ok=0,buf=""
	set srv=$$listen^STDNET(0),port=$$boundport^STDNET(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,3),n=$$write^STDNET(cli,msg)
	set conn=$$accept^STDNET(srv,3),n=$$read^STDNET(conn,999,3,.buf)
	set ok=(buf=msg)
	set n=$$close^STDNET(cli),n=$$close^STDNET(conn),n=$$close^STDNET(srv)
	quit ok
	;
tSnapshotShape(pass,fail)	;@TEST "snapshot() mirrors the live VSLTAP/VSLTAPHL state into a typed-node object [both engines]"
	new J,tmp
	do reset()
	do off^VSLTAP,arm^VSLTAP,setConsumer^VSLTAP(1)
	do record^VSLTAPHL(1000,50,0)
	do record^VSLTAPHL(2000,30,0)
	do record^VSLTAPHL("",0,1)
	do snapshot^VWEBT(.J)
	do eq^STDASSERT(.pass,.fail,$get(J),"o","the snapshot is a JSON object node")
	do eq^STDASSERT(.pass,.fail,$get(J("enabled")),"n:1","armed + consumer present -> enabled 1")
	do eq^STDASSERT(.pass,.fail,$get(J("consumer")),"n:1","consumer-present flag mirrored")
	do eq^STDASSERT(.pass,.fail,$get(J("writes")),"n:2","writes counter mirrored (2 captures)")
	do eq^STDASSERT(.pass,.fail,$get(J("denied")),"n:1","denied counter mirrored (1 gate denial)")
	do eq^STDASSERT(.pass,.fail,$get(J("bytes")),"n:80","bytes counter mirrored (50+30)")
	do true^STDASSERT(.pass,.fail,$get(J("state"))?1"s:".E,"state is a string node")
	do true^STDASSERT(.pass,.fail,$data(J("ready")),"readiness is reported")
	do true^STDASSERT(.pass,.fail,$data(J("ring")),"ring/spool depth is reported")
	do true^STDASSERT(.pass,.fail,$data(J("offwindows")),"off-window count is reported")
	do true^STDASSERT(.pass,.fail,$data(J("disabled")),"auto-failover reason is reported")
	do true^STDASSERT(.pass,.fail,$data(J("p50"))&$data(J("p95"))&$data(J("p99")),"latency percentiles reported")
	quit
	;
tSnapshotReflectsOff(pass,fail)	;@TEST "snapshot() reports enabled 0 when the operator kill-switch is OFF [both engines]"
	new J
	do reset()
	do off^VSLTAP
	do snapshot^VWEBT(.J)
	do eq^STDASSERT(.pass,.fail,$get(J("enabled")),"n:0","mode OFF -> not enabled")
	quit
	;
tSnapshotDisabledReason(pass,fail)	;@TEST "snapshot() surfaces the auto-failover reason and gates enabled [both engines]"
	new J
	do reset()
	do arm^VSLTAP,setConsumer^VSLTAP(1)
	do disable^VSLTAP("latency")
	do snapshot^VWEBT(.J)
	do eq^STDASSERT(.pass,.fail,$get(J("disabled")),"s:latency","the disable reason is surfaced")
	do eq^STDASSERT(.pass,.fail,$get(J("enabled")),"n:0","auto-disabled -> not enabled")
	quit
	;
tRoutesRegistered(pass,fail)	;@TEST "routes^VWEBT registers GET /traffic/health -> health^VWEBT [both engines]"
	new SRV,route,params,st
	do routes^VWEBT(.SRV)
	set st=$$match^STDHTTPD(.SRV,"GET","/traffic/health",.route,.params)
	do eq^STDASSERT(.pass,.fail,st,200,"GET /traffic/health matches a route")
	do eq^STDASSERT(.pass,.fail,$get(route("handler")),"health^VWEBT","dispatches to health^VWEBT")
	quit
	;
tHealthInVwebrTable(pass,fail)	;@TEST "the real VWEBR route table mounts /traffic/health (and keeps /healthz, /Patient) [both engines]"
	new SRV,route,params,st
	do routes^VWEBR(.SRV)
	set st=$$match^STDHTTPD(.SRV,"GET","/traffic/health",.route,.params)
	do eq^STDASSERT(.pass,.fail,st,200,"the aggregated table mounts /traffic/health")
	set st=$$match^STDHTTPD(.SRV,"GET","/healthz",.route,.params)
	do eq^STDASSERT(.pass,.fail,st,200,"/healthz is still routed")
	quit
	;
tHealthIsEventStream(pass,fail)	;@TEST "GET /traffic/health -> 200 text/event-stream (SSE-framed) [both engines]"
	new SRV,REQ,RSP,st,body,lf
	do reset()
	do arm^VSLTAP,setConsumer^VSLTAP(1)
	do routesNoAuth(.SRV)
	set REQ("method")="GET",REQ("path")="/traffic/health"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"status 200")
	do eq^STDASSERT(.pass,.fail,$get(RSP("hdr","Content-Type")),"text/event-stream","Content-Type is text/event-stream")
	set lf=$char(10),body=$get(RSP("body"))
	do true^STDASSERT(.pass,.fail,body[("event: health"_lf),"the SSE event name is present")
	do true^STDASSERT(.pass,.fail,body[("data: "),"an SSE data line is present")
	quit
	;
tHealthDataParses(pass,fail)	;@TEST "the SSE data: line is JSON that carries the tap state [both engines]"
	new SRV,REQ,RSP,st,body,lf,data,T
	do reset()
	do arm^VSLTAP,setConsumer^VSLTAP(1)
	do routesNoAuth(.SRV)
	set REQ("method")="GET",REQ("path")="/traffic/health"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	set lf=$char(10),body=$get(RSP("body"))
	set data=$piece($piece(body,"data: ",2),lf,1)
	do true^STDASSERT(.pass,.fail,$$parse^STDJSON(data,.T),"the data line parses as JSON")
	do true^STDASSERT(.pass,.fail,$data(T("state")),"the snapshot JSON carries the tap state")
	do eq^STDASSERT(.pass,.fail,$$valueOf^STDJSON($get(T("enabled"))),1,"enabled is a JSON number (1)")
	quit
	;
tHealthIsProtected(pass,fail)	;@TEST "the console is auth-protected: /traffic/health is not an open path; unauthenticated -> 401 [both engines]"
	new SRV,REQ,RSP,st
	do eq^STDASSERT(.pass,.fail,$$isOpen^VWEBA("/traffic/health"),0,"/traffic/health is not in the open allow-list")
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/traffic/health"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"no Bearer credential -> 401")
	quit
	;
tHealthOverSocket(pass,fail)	;@TEST "the /traffic/health route is served over a real socket: 200 text/event-stream on the wire [both bare engines]"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped (regression guard)") quit
	do reset()
	do arm^VSLTAP,setConsumer^VSLTAP(1)
	set cr=$char(13,10)
	set req="GET /traffic/health HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do routesNoAuth(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote GET /traffic/health")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	do eq^STDASSERT(.pass,.fail,n,1,"serveConn served exactly one request")
	set rn=$$read^STDNET(cli,65536,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),200,"status 200 on the wire")
	; parseRsp preserves header-name case, so use the case-insensitive accessor
	do eq^STDASSERT(.pass,.fail,$$hdr^STDHTTPMSG(.R,"content-type"),"text/event-stream","Content-Type text/event-stream on the wire")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
	; ---------- the operator tap toggle (POST /traffic/tap) ----------
	;
tTapRegistered(pass,fail)	;@TEST "routes^VWEBT registers POST /traffic/tap -> tap^VWEBT [both engines]"
	new SRV,route,params,st
	do routes^VWEBT(.SRV)
	set st=$$match^STDHTTPD(.SRV,"POST","/traffic/tap",.route,.params)
	do eq^STDASSERT(.pass,.fail,st,200,"POST /traffic/tap matches a route")
	do eq^STDASSERT(.pass,.fail,$get(route("handler")),"tap^VWEBT","dispatches to tap^VWEBT")
	quit
	;
tTapRequiresAuth(pass,fail)	;@TEST "the operator toggle is auth-protected: unauthenticated POST /traffic/tap -> 401 [both engines]"
	new SRV,REQ,RSP,st
	do eq^STDASSERT(.pass,.fail,$$isOpen^VWEBA("/traffic/tap"),0,"/traffic/tap is not in the open allow-list")
	do routes^VWEBR(.SRV)
	set REQ("method")="POST",REQ("path")="/traffic/tap",REQ("query","action")="arm"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"no Bearer credential -> 401 (the toggle never runs)")
	quit
	;
tTapArmsAndOffs(pass,fail)	;@TEST "POST /traffic/tap action=arm|off flips the kill-switch and returns the fresh snapshot [both engines]"
	new SRV,REQ,RSP,st
	do reset()
	do off^VSLTAP,heartbeat^VSLTAP
	do routesNoAuth(.SRV)
	; arm
	set REQ("method")="POST",REQ("path")="/traffic/tap",REQ("query","action")="arm"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"arm returns 200")
	do eq^STDASSERT(.pass,.fail,$$cfg^VSLTAP("mode","off"),"armed","arm flips the operator kill-switch on")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","state")),"s:ARMED-IDLE","the fresh snapshot reflects the armed state")
	; off
	kill REQ,RSP
	set REQ("method")="POST",REQ("path")="/traffic/tap",REQ("query","action")="off"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$$state^VSLTAP,"OFF","off returns the tap to OFF")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","state")),"s:OFF","the snapshot shows OFF at once")
	quit
	;
tTapViaQueryOnPost(pass,fail)	;@TEST "POST /traffic/tap reads the action from the query string (?action=off) [both engines]"
	new SRV,REQ,RSP,st
	do reset()
	do arm^VSLTAP,heartbeat^VSLTAP
	do routesNoAuth(.SRV)
	; the SPA POSTs /traffic/tap?action=off — a query param (NOT a JSON body: a
	; single-member JSON object trips an STDJSON-on-IRIS parse bug, so the toggle
	; takes its action from the query string, which is dual-engine clean).
	set REQ("method")="POST",REQ("path")="/traffic/tap",REQ("query","action")="off"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"a query-string action returns 200")
	do eq^STDASSERT(.pass,.fail,$$cfg^VSLTAP("mode","off"),"off","the query-string action turned the tap off")
	quit
	;
tTapRearmCycle(pass,fail)	;@TEST "POST /traffic/tap action=rearm clears a clean auto-disable (OFF->armed->auto-disable->re-arm) [both engines]"
	new SRV,REQ,RSP,st
	do reset()
	do arm^VSLTAP,setConsumer^VSLTAP(1),heartbeat^VSLTAP
	; simulate an auto-failover trip (the watchdog's job, not the toggle's)
	do disable^VSLTAP("latency")
	do eq^STDASSERT(.pass,.fail,$$disabled^VSLTAP,"latency","precondition: the tap auto-disabled on a latency trip")
	do routesNoAuth(.SRV)
	set REQ("method")="POST",REQ("path")="/traffic/tap",REQ("query","action")="rearm"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"rearm returns 200")
	do eq^STDASSERT(.pass,.fail,$$disabled^VSLTAP,"","rearm clears the auto-failover reason (operator cleared the cool-down)")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","disabled")),"s:","the snapshot shows the reason cleared")
	quit
	;
tTapRejectsBadAction(pass,fail)	;@TEST "POST /traffic/tap with an unknown action -> 400 (no state change) [both engines]"
	new SRV,REQ,RSP,st
	do reset()
	do off^VSLTAP
	do routesNoAuth(.SRV)
	set REQ("method")="POST",REQ("path")="/traffic/tap",REQ("query","action")="bogus"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),400,"an unrecognised action is rejected with 400")
	do eq^STDASSERT(.pass,.fail,$$cfg^VSLTAP("mode","off"),"off","a bad action leaves the kill-switch untouched")
	quit
	;
	; ---------- the fidelity panel data (snapshot reads VSLTAPFC's last run) ----------
	;
tSnapshotFidelityPending(pass,fail)	;@TEST "snapshot: fidelity reports 'pending' when no fidelity run has been persisted [both engines]"
	new J
	do reset()
	do snapshot^VWEBT(.J)
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity")),"o","fidelity is reported as an object")
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity","status")),"s:pending","no persisted run -> last-run pending (honest, no fabricated %)")
	quit
	;
tSnapshotFidelityPresent(pass,fail)	;@TEST "snapshot: fidelity surfaces match %/counts from the persisted VSLTAPFC run [both engines]"
	new J,res
	do reset()
	; persist a clean run (8 matched, 0 problems) via the v-stdlib primitive
	set res("matched")=8,res("mismatch")=0,res("missing")=0,res("extra")=0
	do persist^VSLTAPFC(.res,"65800,43200")
	do snapshot^VWEBT(.J)
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity","status")),"s:ok","a clean run shows ok")
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity","matched")),"n:8","the matched count is surfaced")
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity","pct")),"n:100","8/8 matched -> 100% fidelity")
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity","ts")),"s:65800,43200","the last-run timestamp is surfaced")
	; a drifted run lowers the % and flags a mismatch
	kill J
	set res("matched")=6,res("mismatch")=2,res("missing")=0,res("extra")=0
	do persist^VSLTAPFC(.res,"65800,43201")
	do snapshot^VWEBT(.J)
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity","status")),"s:mismatch","a run with mismatches shows mismatch")
	do eq^STDASSERT(.pass,.fail,$get(J("fidelity","pct")),"n:75","6 of 8 matched -> 75%")
	quit
	;
	; ---------- the operator SPA (GET /traffic -> a self-contained HTML console) ----------
	;
tConsoleRegistered(pass,fail)	;@TEST "routes^VWEBT registers GET /traffic -> console^VWEBT [both engines]"
	new SRV,route,params,st
	do routes^VWEBT(.SRV)
	set st=$$match^STDHTTPD(.SRV,"GET","/traffic",.route,.params)
	do eq^STDASSERT(.pass,.fail,st,200,"GET /traffic matches a route")
	do eq^STDASSERT(.pass,.fail,$get(route("handler")),"console^VWEBT","dispatches to console^VWEBT")
	quit
	;
tConsoleIsHtml(pass,fail)	;@TEST "GET /traffic -> 200 text/html: a self-contained page wiring EventSource + the toggle [both engines]"
	new SRV,REQ,RSP,st,body
	do routesNoAuth(.SRV)
	set REQ("method")="GET",REQ("path")="/traffic"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"status 200")
	do true^STDASSERT(.pass,.fail,$get(RSP("hdr","Content-Type"))["text/html","Content-Type is text/html")
	set body=$get(RSP("body"))
	do true^STDASSERT(.pass,.fail,body["EventSource","the page opens an EventSource (live cadence)")
	do true^STDASSERT(.pass,.fail,body["/traffic/health","the SSE stream is the health endpoint")
	do true^STDASSERT(.pass,.fail,body["/traffic/tap","the page wires the operator toggle")
	do true^STDASSERT(.pass,.fail,body["fidelity","the fidelity panel is present")
	quit
	;
tConsoleProtected(pass,fail)	;@TEST "the console page is auth-protected: unauthenticated GET /traffic -> 401 [both engines]"
	new SRV,REQ,RSP,st
	do eq^STDASSERT(.pass,.fail,$$isOpen^VWEBA("/traffic"),0,"/traffic is not in the open allow-list")
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/traffic"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"no Bearer credential -> 401")
	quit
