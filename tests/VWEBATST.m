VWEBATST	; v-web — VWEBA (auth middleware: bearer/JWT -> DUZ/#200) suite.
	; M6.5: closes the M6.4 route. VWEBA is an STDHTTPD middleware registered
	; ahead of the handlers; it turns an inbound Bearer JWT into a VistA principal
	; (DUZ via #200) and rejects the unauthenticated with 401. /healthz stays open.
	;
	; Three layers of proof, all over the driver stack (m/v waterline — the ONLY path):
	;   m test --engine ydb  --docker m-test-engine --chset m ...       (bare YDB)
	;   m test --engine iris --docker m-test-iris ...                    (bare IRIS)
	;   m test --engine ydb  --docker vehu     --chset m ...             (live YDB-VistA)
	;   m test --engine iris --docker foia-t12 --namespace VISTA ...     (live IRIS-VistA)
	;
	; BARE engines prove the SECURITY GUARANTEES (no VistA needed): /healthz open;
	; no/non-Bearer/bad-signature/expired token -> 401; an unconfigured key fails
	; CLOSED; and the 401 travels over a real socket. The token signature + claim
	; validation is engine-neutral (STDJWT). The token's effective key is injected
	; via the ^VWEB("rtcfg",...) runtime-config cache so the chain is exercised
	; with no XPAR (the bare path) and no KIDS install.
	;
	; LIVE VistA proves the PRINCIPAL BINDING: subject -> #200 IEN -> DUZ (via
	; VSLSEC), the handler runs as that DUZ, and an unprovisioned subject -> 403.
	; The binding ($text(GET1^DIQ)-gated) soft-skips on a bare engine.
	;
	; The ^VWEB("rtcfg",...) fixture is killed after each config-setting test, so
	; nothing persists (clean back-out).
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tIsOpen(.pass,.fail)
	do tBearer(.pass,.fail)
	do tHealthzOpen(.pass,.fail)
	do tNoToken401(.pass,.fail)
	do tNonBearer401(.pass,.fail)
	do tValidTokenReachesHandler(.pass,.fail)
	do tBadSignature401(.pass,.fail)
	do tExpiredToken401(.pass,.fail)
	do tUnconfiguredKeyFailsClosed(.pass,.fail)
	do t401OverSocket(.pass,.fail)
	do tTrafficQueryToken(.pass,.fail)
	do tQueryTokenScopedToTraffic(.pass,.fail)
	do tByIenLive(.pass,.fail)
	do tValidTokenBindsDuzLive(.pass,.fail)
	do tUnprovisioned403Live(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
	; ---------- helpers ----------
	;
hasFileMan()	; 1 iff the FileMan DBS API ($$GET1^DIQ) is present (a live VistA).
	quit $text(GET1^DIQ)'=""
	;
hasCrypto()	; 1 iff STDCRYPTO (HMAC callout) resolves — needed to SIGN test tokens.
	; Bare test engines have it baked in; a live VistA (vehu/foia) may not have the
	; libcrypto callout deployed, so token-signing tests soft-skip there (the
	; signature/claim guarantees are proven on the bare engines; the live value is
	; the principal binding, which $$bind proves without signing).
	quit $$available^STDCRYPTO
	;
rawByteSafe()	; 1 iff raw sockets preserve CRLF end-to-end (HTTP framing needs it).
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
existingIen()	; A #200 IEN that resolves to a real user (read-only), or "".
	; IEN 1 is the postmaster on every system; fall back to a small scan.
	new ien,found
	if $$user^VSLSEC(1)'="" quit 1
	set found=""
	for ien=1:1:200 do  quit:found'=""
	. if $$user^VSLSEC(ien)'="" set found=ien
	quit found
	;
	; ---------- bare-engine: the security guarantees ----------
	;
tIsOpen(pass,fail)	;@TEST "the open-path allow-list lets /healthz through and gates everything else"
	do true^STDASSERT(.pass,.fail,$$isOpen^VWEBA("/healthz"),"/healthz is open (liveness)")
	do eq^STDASSERT(.pass,.fail,$$isOpen^VWEBA("/Patient/1"),0,"/Patient/:id is NOT open")
	do eq^STDASSERT(.pass,.fail,$$isOpen^VWEBA("/"),0,"/ is not open")
	quit
	;
tBearer(pass,fail)	;@TEST "$$bearer extracts the token only from a well-formed 'Bearer <token>' header"
	new REQ
	set REQ("hdr","authorization")="Bearer abc.def.ghi"
	do eq^STDASSERT(.pass,.fail,$$bearer^VWEBA(.REQ),"abc.def.ghi","extracts the bearer token")
	set REQ("hdr","authorization")="bearer lower.case.scheme"
	do eq^STDASSERT(.pass,.fail,$$bearer^VWEBA(.REQ),"lower.case.scheme","the scheme match is case-insensitive")
	set REQ("hdr","authorization")="Basic dXNlcjpwYXNz"
	do eq^STDASSERT(.pass,.fail,$$bearer^VWEBA(.REQ),"","a non-Bearer scheme yields no token")
	kill REQ
	do eq^STDASSERT(.pass,.fail,$$bearer^VWEBA(.REQ),"","an absent Authorization header yields no token")
	quit
	;
tHealthzOpen(pass,fail)	;@TEST "GET /healthz returns 200 with NO token (the middleware skips the open path)"
	new SRV,REQ,RSP,st
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/healthz"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"/healthz is 200 without authentication")
	quit
	;
tNoToken401(pass,fail)	;@TEST "GET /Patient/:id with no token -> 401 (+ WWW-Authenticate + OperationOutcome)"
	new SRV,REQ,RSP,st
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"an unauthenticated protected request is 401")
	do true^STDASSERT(.pass,.fail,$get(RSP("hdr","WWW-Authenticate"))["Bearer","a Bearer WWW-Authenticate challenge is set")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","resourceType")),"s:OperationOutcome","the body is a FHIR OperationOutcome")
	quit
	;
tNonBearer401(pass,fail)	;@TEST "a non-Bearer Authorization header -> 401"
	new SRV,REQ,RSP,st
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc",REQ("hdr","authorization")="Basic dXNlcjpwYXNz"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"Basic auth (not Bearer) is rejected with 401")
	quit
	;
tValidTokenReachesHandler(pass,fail)	;@TEST "a valid, in-date, correctly-signed token reaches the handler (NOT 401)"
	new SRV,REQ,RSP,st
	if $$hasFileMan() do true^STDASSERT(.pass,.fail,1,"bare-engine security guarantee - live behavior covered by the binding tests") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token signing/verify proven where available") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret")
	do routes^VWEBR(.SRV)
	; /Patient/abc -> the handler returns 400 (bad id) BEFORE any FileMan, so this
	; runs on a bare engine: a 400 (not 401) proves auth let the request through.
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set REQ("hdr","authorization")="Bearer "_$$mkjwt("testsecret",1,9999999999)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),400,"a valid token passes auth; the handler runs (400 for the bad id)")
	do clearcfg()
	quit
	;
tBadSignature401(pass,fail)	;@TEST "a token signed with the wrong key -> 401"
	new SRV,REQ,RSP,st
	if $$hasFileMan() do true^STDASSERT(.pass,.fail,1,"bare-engine security guarantee - live behavior covered by the binding tests") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token signing/verify proven where available") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret")
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set REQ("hdr","authorization")="Bearer "_$$mkjwt("WRONGsecret",1,9999999999)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"a wrong-key signature is rejected with 401")
	do clearcfg()
	quit
	;
tExpiredToken401(pass,fail)	;@TEST "a correctly-signed but expired token -> 401"
	new SRV,REQ,RSP,st
	if $$hasFileMan() do true^STDASSERT(.pass,.fail,1,"bare-engine security guarantee - live behavior covered by the binding tests") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token signing/verify proven where available") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret")
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set REQ("hdr","authorization")="Bearer "_$$mkjwt("testsecret",1,1)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"an expired token (exp in 1970) is rejected with 401")
	do clearcfg()
	quit
	;
tUnconfiguredKeyFailsClosed(pass,fail)	;@TEST "with NO key configured, even a token request fails CLOSED (401), never open"
	new SRV,REQ,RSP,st
	if $$hasFileMan() do true^STDASSERT(.pass,.fail,1,"bare-engine security guarantee - live behavior covered by the binding tests") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token signing/verify proven where available") quit
	do clearcfg()
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set REQ("hdr","authorization")="Bearer "_$$mkjwt("anything",1,9999999999)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"an unconfigured server rejects all tokens (fail-closed)")
	quit
	;
t401OverSocket(pass,fail)	;@TEST "the 401 travels over a real socket: no token on /Patient -> 401 on the wire"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped") quit
	set cr=$char(13,10)
	set req="GET /Patient/abc HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do routes^VWEBR(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote an unauthenticated GET /Patient/abc")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	set rn=$$read^STDNET(cli,16384,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),401,"the unauthenticated request is 401 on the wire")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
	; ---------- bare-engine: the SSE query-token fallback (the browser EventSource) ----------
	;
tTrafficQueryToken(pass,fail)	;@TEST "an EventSource on /traffic/health authenticates via ?access_token (no Authorization header)"
	new SRV,REQ,RSP,st
	if $$hasFileMan() do true^STDASSERT(.pass,.fail,1,"bare-engine security guarantee - live behavior covered by the binding tests") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token signing/verify proven where available") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret")
	do routes^VWEBR(.SRV)
	; the browser EventSource cannot set Authorization, so the SPA passes the token
	; in the query string; VWEBA honours it ONLY for the /traffic/* console paths.
	; (health^VWEBT returns 200 regardless of tap state, so a 200 proves auth passed.)
	set REQ("method")="GET",REQ("path")="/traffic/health"
	set REQ("query","access_token")=$$mkjwt("testsecret",1,9999999999)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"a valid query-string token authenticates the console (200, not 401)")
	do clearcfg()
	quit
	;
tQueryTokenScopedToTraffic(pass,fail)	;@TEST "the ?access_token fallback is scoped to /traffic/* — it does NOT authenticate other routes"
	new SRV,REQ,RSP,st
	if $$hasFileMan() do true^STDASSERT(.pass,.fail,1,"bare-engine security guarantee - live behavior covered by the binding tests") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token signing/verify proven where available") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret")
	do routes^VWEBR(.SRV)
	; same valid token, but on a non-console route: the query fallback must be ignored
	; (token-in-URL is logged/cached; we accept that risk ONLY for the console paths).
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set REQ("query","access_token")=$$mkjwt("testsecret",1,9999999999)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),401,"a query token on a non-/traffic route is ignored -> 401")
	do clearcfg()
	quit
	;
	; ---------- live VistA: the principal binding ----------
	;
tByIenLive(pass,fail)	;@TEST "$$bind (ien map) resolves an existing #200 IEN and rejects a bogus one [live VistA]"
	new ien
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan absent (bare engine) - #200 binding verified on vehu/foia") quit
	set ien=$$existingIen()
	if ien="" do true^STDASSERT(.pass,.fail,1,"no resolvable #200 entry found - skipped") quit
	do eq^STDASSERT(.pass,.fail,$$bind^VWEBA(ien,"ien"),ien,"the ien map binds an existing #200 IEN to itself")
	do eq^STDASSERT(.pass,.fail,$$bind^VWEBA(8999999,"ien"),"","a non-existent #200 IEN binds to nothing")
	quit
	;
tValidTokenBindsDuzLive(pass,fail)	;@TEST "a valid token binds DUZ to the subject's #200 IEN; the handler runs as that user [live VistA]"
	new SRV,REQ,RSP,st,ien
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan absent (bare engine) - DUZ binding verified on vehu/foia") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - token e2e proven where available (binding proven by tByIenLive)") quit
	set ien=$$existingIen()
	if ien="" do true^STDASSERT(.pass,.fail,1,"no resolvable #200 entry - skipped") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret"),setcfg("VWEB AUTH IDENTITY MAP","ien")
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set REQ("hdr","authorization")="Bearer "_$$mkjwt("testsecret",ien,9999999999)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),400,"auth + binding pass; the handler runs (400 for the bad id)")
	do eq^STDASSERT(.pass,.fail,$get(REQ("auth","duz")),ien,"DUZ was bound to the subject's #200 IEN")
	do clearcfg()
	quit
	;
tUnprovisioned403Live(pass,fail)	;@TEST "an authenticated subject with no #200 mapping -> 403 [live VistA]"
	new SRV,REQ,RSP,st
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan absent (bare engine) - 403 path verified on vehu/foia") quit
	if '$$hasCrypto() do true^STDASSERT(.pass,.fail,1,"STDCRYPTO callout absent here - 403 path proven where token signing is available") quit
	do setcfg("VWEB AUTH JWT KEY","testsecret"),setcfg("VWEB AUTH IDENTITY MAP","secid")
	do routes^VWEBR(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set REQ("hdr","authorization")="Bearer "_$$mkjwt("testsecret","ZZNO-SUCH-SECID-99999",9999999999)
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),403,"a valid token whose subject is not provisioned in #200 is 403")
	do clearcfg()
	quit
