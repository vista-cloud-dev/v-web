VWEBLTST	; v-web — VWEBL (inbound listener + accept-loop + worker handoff) suite.
	; The M6.3 vertical: a real "GET /healthz" enters over a loopback socket, is
	; served by STDHTTPD's worker loop over a VWEBIO transport, and the byte-exact
	; 200 is written back — no fake transport, no TaskMan, single process. Plus
	; the serial accept->serve->close unit (acceptOne) and the TaskMan launch bind
	; (live on vehu/foia, soft-skipped on a bare engine). Driver stack only:
	;   m test --engine ydb  --docker m-test-engine ...
	;   m test --engine iris --docker m-test-iris  ...
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tHealthHandler(.pass,.fail)
	do tServeHealthOverSocket(.pass,.fail)
	do tServeKeepAlive(.pass,.fail)
	do tConnectionCloseEndsIt(.pass,.fail)
	do tAcceptOneServes(.pass,.fail)
	do tAcceptOneTimeout(.pass,.fail)
	do tLaunchBindsTaskMan(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
rawByteSafe()	; 1 iff raw sockets preserve CRLF bytes end-to-end — the precondition
	; for HTTP framing (the request/response terminator is CRLFCRLF). YDB: yes.
	; IRIS: yes since MSL v0.12.1 — STDNET's readIris was CR-terminated (stopped at
	; the first CR, stripping CRLF, so the framed request arrived mangled → 400);
	; the fix reads byte-exact (see docs/memory/stdnet-iris-crlf-rawread-gap.md).
	; This probe stays as the live regression guard (auto-skips if a future engine
	; regresses CRLF). Reading a peer-CLOSED socket is also clean on both engines
	; since MSL v0.12.2 (STDNET readIris drains + EOFs vs killing the job), so the
	; on-the-wire read-back test guards on this same probe.
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
tHealthHandler(pass,fail)	;@TEST "the /healthz handler sets a 200 ok response"
	new REQ,RSP
	set REQ("method")="GET",REQ("path")="/healthz"
	do health^VWEBL(.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"status 200")
	do eq^STDASSERT(.pass,.fail,$get(RSP("body")),"ok","body ok")
	quit
	;
tServeHealthOverSocket(pass,fail)	;@TEST "a real GET /healthz over a socket is served by STDHTTPD and the 200 written back (byte-exact)"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"sockets unavailable or raw CRLF not preserved here - serve skipped (regression guard; CRLF fixed on IRIS @ MSL v0.12.1)") quit
	set cr=$char(13,10)
	set req="GET /healthz HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do healthRoutes^VWEBL(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote the request")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	do eq^STDASSERT(.pass,.fail,n,1,"serveConn served exactly one request")
	set rn=$$read^STDNET(cli,16384,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),200,"status 200 on the wire")
	do eq^STDASSERT(.pass,.fail,$get(R("body")),"ok","body ok on the wire")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
tServeKeepAlive(pass,fail)	;@TEST "keep-alive: serveConn loops multiple pipelined requests on one connection"
	new srv,cli,conn,port,SRV,opts,n,cr,req1,req2
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"sockets unavailable or raw CRLF not preserved here - serve skipped (regression guard; CRLF fixed on IRIS @ MSL v0.12.1)") quit
	set cr=$char(13,10)
	set req1="GET /healthz HTTP/1.1"_cr_"Host: x"_cr_cr
	set req2="GET /healthz HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do healthRoutes^VWEBL(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req1_req2),"client pipelined two requests")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	do eq^STDASSERT(.pass,.fail,n,2,"both pipelined requests served on one connection")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
tConnectionCloseEndsIt(pass,fail)	;@TEST "Connection: close ends the connection after one request"
	new srv,cli,conn,port,SRV,opts,n,cr,req
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"sockets unavailable or raw CRLF not preserved here - serve skipped (regression guard; CRLF fixed on IRIS @ MSL v0.12.1)") quit
	set cr=$char(13,10)
	set req="GET /healthz HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do healthRoutes^VWEBL(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	set n=$$write^STDNET(cli,req)
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	do eq^STDASSERT(.pass,.fail,n,1,"exactly one request before close")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
tAcceptOneServes(pass,fail)	;@TEST "acceptOne() accepts a pending connection and serves it (returns 1)"
	new srv,cli,port,SRV,opts,n,cr,req
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"sockets unavailable or raw CRLF not preserved here - serve skipped (regression guard; CRLF fixed on IRIS @ MSL v0.12.1)") quit
	set cr=$char(13,10),req="GET /healthz HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do healthRoutes^VWEBL(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	set n=$$write^STDNET(cli,req)
	set n=$$acceptOne^VWEBL(srv,.SRV,.opts,5)
	do eq^STDASSERT(.pass,.fail,n,1,"acceptOne served one connection")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
tAcceptOneTimeout(pass,fail)	;@TEST "acceptOne() returns 0 when no connection arrives within the timeout"
	new srv,SRV,opts,n
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	do healthRoutes^VWEBL(.SRV)
	set srv=$$listen^VWEBIO(0)
	set n=$$acceptOne^VWEBL(srv,.SRV,.opts,1)
	do eq^STDASSERT(.pass,.fail,n,0,"no pending connection - acceptOne returns 0")
	set n=$$close^VWEBIO(srv)
	quit
	;
tLaunchBindsTaskMan(pass,fail)	;@TEST "the listener launch is wired to TaskMan (VSLTASK) — live on VistA engines, bound on a bare one"
	new ztsk
	if $text(TM^%ZTLOAD)="" do true^STDASSERT(.pass,.fail,1,"TaskMan (%ZTLOAD) absent (bare engine) - launch bind verified on vehu/foia") quit
	if '$$running^VSLTASK() do true^STDASSERT(.pass,.fail,1,"TaskMan scheduler not live here - launch bind verified on vehu/foia") quit
	set ztsk=$$launch^VWEBL()
	do true^STDASSERT(.pass,.fail,+ztsk>0,"launch scheduled a persistent TaskMan listener task")
	quit
