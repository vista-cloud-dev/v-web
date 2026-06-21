VWEBE2ETST	; v-web — the M6.6 end-to-end smoke suite: the M6 capstone, everything at once.
	; M6.1-M6.5 each proved a layer (codec / framework / listener / route / auth);
	; M6.6 proves the WHOLE vertical composed over a REAL socket, both engines:
	;   - the open path (/healthz) travels the wire with the middleware in place;
	;   - a protected route with NO token -> 401 on the wire (the M6.5 guarantee,
	;     re-proven through the live registered chain, not $$dispatch);
	;   - THE CAPSTONE: a valid Bearer token -> an AUTHENTICATED 200 FHIR Patient on
	;     the wire (auth middleware + #200 binding + VSLFS #2 read + STDJSON, all at
	;     once). M6.5 proved 401-over-socket; this proves the authenticated 200 over
	;     the wire — the leg that was never tested end-to-end.
	;   - an authenticated-but-unprovisioned subject -> 403 on the wire;
	;   - the §9 TLS smoke (gap-loud): TLS is bound + LOUD (,U-VWEB-NOTLS,), never a
	;     silent plaintext fallback. A real HTTPS round-trip waits on cert +
	;     XU*8.0*787 (M2.T2 infra block); soft-skip loudly, never fake a handshake.
	;
	; This suite is COMPOSITION + VERIFICATION — it adds no production surface; it
	; drives the already-green VWEB*/VSL*/STD* stack through one front door.
	;
	; Driver stack only (the m/v waterline — the ONLY path):
	;   m test --engine ydb  --docker m-test-engine --chset m ...   (bare YDB)
	;   m test --engine iris --docker m-test-iris ...               (bare IRIS)
	;   m test --engine ydb  --docker vehu     --chset m ...        (live YDB-VistA)
	;   m test --engine iris --docker foia-t12 --namespace VISTA ...(live IRIS-VistA)
	;
	; BARE engines prove the wire-level composition that needs no VistA: the table
	; composes, /healthz is open over the socket, and a tokenless protected request
	; is 401 on the wire. LIVE VistA proves the authenticated 200 (binding -> DUZ ->
	; FileMan read) and the 403 unprovisioned path. The TLS gap-loud assertion is
	; engine-neutral. The ^VWEB("rtcfg") fixture is killed after each test (clean
	; back-out; nothing persists).
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tStackComposes(.pass,.fail)
	do tHealthzOpenOverSocket(.pass,.fail)
	do tUnauthenticated401OverSocket(.pass,.fail)
	do tAuthenticatedPatient200OverSocket(.pass,.fail)
	do tUnprovisioned403OverSocket(.pass,.fail)
	do tTlsGapIsLoud(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
	; ---------- helpers (mirrors of VWEBATST/VWEBRTST) ----------
	;
hasFileMan()	; 1 iff the FileMan DBS API ($$GET1^DIQ) is present (a live VistA).
	quit $text(GET1^DIQ)'=""
	;
hasCrypto()	; 1 iff STDCRYPTO (HMAC callout) resolves — needed to SIGN test tokens.
	quit $$available^STDCRYPTO
	;
rawByteSafe()	; 1 iff raw sockets preserve CRLF bytes end-to-end (HTTP framing needs it).
	; The same live regression guard the sibling socket suites carry: YDB always,
	; IRIS since MSL v0.12.1/.2 (the STDNET CRLF + peer-closed-read fixes).
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
mkjwt(key,sub,exp)	; build a test HS256 JWT carrying sub + exp.
	new CL
	set CL="o",CL("sub")="s:"_sub,CL("exp")="n:"_exp
	quit $$sign^STDJWT(.CL,key)
	;
setcfg(name,val)	; set a runtime-config override (the bare/test config seam).
	set ^VWEB("rtcfg",name)=val
	quit
	;
clearcfg()	; back out the runtime-config fixture (clean teardown).
	kill ^VWEB("rtcfg")
	quit
	;
existingDfn()	; The first existing #2 DFN in 1..5000 (read-only via VSLFS), or "".
	new dfn,found
	set found=""
	for dfn=1:1:5000 do  quit:found'=""
	. if $$exists^VSLFS(2,dfn_",") set found=dfn
	quit found
	;
existingIen()	; A #200 IEN that resolves to a real user (read-only), or "".
	; IEN 1 is the postmaster on every system; fall back to a small scan.
	new ien,found
	if $$user^VSLSEC(1)'="" quit 1
	set found=""
	for ien=1:1:200 do  quit:found'=""
	. if $$user^VSLSEC(ien)'="" set found=ien
	quit found
	;
	; ---------- bare-engine: the wire-level composition ----------
	;
tStackComposes(pass,fail)	;@TEST "the capstone wiring composes: auth middleware + /healthz + /Patient/:id + the /traffic console (page + SSE + toggle)"
	new SRV,pats
	do routes^VWEBR(.SRV)
	; STDHTTPD keeps an INDEXED table: SRV("mw")=count, SRV("route")=count,
	; SRV("route",n,"pattern"). Assert the composition by count + pattern presence.
	do true^STDASSERT(.pass,.fail,+$get(SRV("mw"))'<1,"the auth middleware is registered on the table")
	do eq^STDASSERT(.pass,.fail,+$get(SRV("route")),5,"five routes are registered (/healthz + /Patient/:id + the 3 /traffic console routes)")
	set pats=$$routePats(.SRV)
	do true^STDASSERT(.pass,.fail,pats["|/healthz|","GET /healthz is routed (the open liveness probe)")
	do true^STDASSERT(.pass,.fail,pats["|/Patient/:id|","GET /Patient/:id is routed (the protected FHIR route)")
	do true^STDASSERT(.pass,.fail,pats["|/traffic|","GET /traffic is routed (the operator SPA)")
	do true^STDASSERT(.pass,.fail,pats["|/traffic/health|","GET /traffic/health is routed (the SSE snapshot)")
	do true^STDASSERT(.pass,.fail,pats["|/traffic/tap|","POST /traffic/tap is routed (the operator toggle)")
	quit
	;
routePats(SRV)	; (helper) "|"-delimited list of the registered route patterns.
	new n,out
	set out="|",n=$order(SRV("route",""))
	for  quit:n=""  do
	. set out=out_$get(SRV("route",n,"pattern"))_"|"
	. set n=$order(SRV("route",n))
	quit out
	;
tHealthzOpenOverSocket(pass,fail)	;@TEST "GET /healthz over a real socket is 200 with NO token, through the FULL table (middleware skips the open path)"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped") quit
	set cr=$char(13,10)
	set req="GET /healthz HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do routes^VWEBR(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote GET /healthz (no token)")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	set rn=$$read^STDNET(cli,16384,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),200,"the open path is 200 on the wire with the middleware in place")
	do eq^STDASSERT(.pass,.fail,$get(R("body")),"ok","liveness body ok on the wire")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
tUnauthenticated401OverSocket(pass,fail)	;@TEST "a protected route with NO token -> 401 on the wire, through the live registered auth chain"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped") quit
	set cr=$char(13,10)
	set req="GET /Patient/1 HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do routes^VWEBR(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote an unauthenticated GET /Patient/1")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	set rn=$$read^STDNET(cli,16384,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),401,"the protected route is 401 on the wire without a token")
	; parseRsp preserves response header-name case (unlike parseReq) — use the
	; case-insensitive $$hdr lookup for the WWW-Authenticate challenge.
	do true^STDASSERT(.pass,.fail,$$hdr^STDHTTPMSG(.R,"www-authenticate")["Bearer","a Bearer WWW-Authenticate challenge travels the wire")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
	; ---------- live VistA: the authenticated 200 (THE capstone) ----------
	;
tAuthenticatedPatient200OverSocket(pass,fail)	;@TEST "THE capstone: a valid Bearer token -> an authenticated 200 FHIR Patient on the wire [live VistA]"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R,T,dfn,ien,tok
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan absent (bare engine) - authenticated 200 verified on vehu/foia") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token e2e proven where signing is available") quit
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped") quit
	set ien=$$existingIen()
	if ien="" do true^STDASSERT(.pass,.fail,1,"no resolvable #200 entry found - authenticated 200 verified on a populated system") quit
	set dfn=$$existingDfn()
	if dfn="" do true^STDASSERT(.pass,.fail,1,"PATIENT (#2) empty (e.g. a scrubbed FOIA build) - authenticated 200 verified on a populated system (vehu)") quit
	; the M6.5 live config pattern: a signing key + the ien identity map (the
	; subject IS a #200 IEN, the directly-resolvable principal) warmed in rtcfg.
	do setcfg("VWEB AUTH JWT KEY","testsecret"),setcfg("VWEB AUTH IDENTITY MAP","ien")
	set tok=$$mkjwt("testsecret",ien,9999999999)
	set cr=$char(13,10)
	set req="GET /Patient/"_dfn_" HTTP/1.1"_cr_"Host: x"_cr_"Authorization: Bearer "_tok_cr_"Connection: close"_cr_cr
	do routes^VWEBR(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote an authenticated GET /Patient/"_dfn)
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	set rn=$$read^STDNET(cli,65536,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),200,"the authenticated request is 200 on the wire")
	do true^STDASSERT(.pass,.fail,$$parse^STDJSON($get(R("body")),.T),"the response body parses as JSON")
	do eq^STDASSERT(.pass,.fail,$get(T("resourceType")),"s:Patient","body is a FHIR Patient")
	do eq^STDASSERT(.pass,.fail,$get(T("id")),"s:"_dfn,"body id = the requested DFN")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	do clearcfg()
	quit
	;
tUnprovisioned403OverSocket(pass,fail)	;@TEST "an authenticated-but-unprovisioned subject -> 403 on the wire [live VistA]"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R,tok
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan absent (bare engine) - 403 path verified on vehu/foia") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - 403 path proven where signing is available") quit
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret"),setcfg("VWEB AUTH IDENTITY MAP","secid")
	set tok=$$mkjwt("testsecret","ZZNO-SUCH-SECID-99999",9999999999)
	set cr=$char(13,10)
	set req="GET /Patient/1 HTTP/1.1"_cr_"Host: x"_cr_"Authorization: Bearer "_tok_cr_"Connection: close"_cr_cr
	do routes^VWEBR(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote a valid token for an unprovisioned subject")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	set rn=$$read^STDNET(cli,16384,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),403,"a valid token whose subject is not in #200 is 403 on the wire")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	do clearcfg()
	quit
	;
	; ---------- §9 TLS smoke (gap-loud, engine-neutral) ----------
	;
tTlsGapIsLoud(pass,fail)	;@TEST "the §9 TLS leg is bound + LOUD: no cert/XU*8.0*787 -> ,U-VWEB-NOTLS,, never a silent plaintext fallback"
	; HTTP-first, TLS-gap-loud (M2.T2 infra block: no server cert, the YDB/IRIS TLS
	; Kernel patch XU*8.0*787 absent). When the operator provisions a cert and the
	; engine TLS plugin, $$tlsAvailable flips to 1 and a real HTTPS round-trip runs;
	; until then we assert the loud raise and soft-skip the handshake — NEVER fake one.
	if $$tlsAvailable^VWEBIO() do true^STDASSERT(.pass,.fail,1,"engine TLS plugin now wired - the real HTTPS round-trip is the M2.T2 follow-up (do not fake a handshake)") quit
	do eq^STDASSERT(.pass,.fail,$$tlsAvailable^VWEBIO(),0,"tlsAvailable()=0 (no engine TLS plugin wired — the tracked M2.T2 gap)")
	do raises^STDASSERT(.pass,.fail,"set x=$$listenTls^VWEBIO(443,""VWEB TLS SERVER CONFIG"")","U-VWEB-NOTLS","the TLS bind raises U-VWEB-NOTLS, never serves plaintext on the TLS port")
	do contains^STDASSERT(.pass,.fail,$$lastError^VWEBIO(),"NOTLS","lastError carries the TLS-gap detail (operator-actionable)")
	quit
