VWEBRTST	; v-web — VWEBR (router + FHIR /Patient/:id handler) suite.
	; M6.4: the first real route on the M6.3 transport. Three layers of proof:
	;   1. the route table itself — $$match resolves GET /Patient/:id -> the
	;      handler and captures :id (and /healthz still routes); pure, both engines.
	;   2. the handler via STDHTTPD's $$dispatch (fake transport, no socket): a
	;      non-numeric id -> 400 runs on a BARE engine (no FileMan touched before
	;      the guard); a known DFN -> 200 FHIR Patient and an unknown DFN -> 404
	;      are FileMan-touching, so they soft-skip on a bare engine ($text(GET1^DIQ))
	;      and run live on vehu/foia.
	;   3. the full socket vertical via $$serveConn^VWEBL — a real GET enters over a
	;      loopback socket and the response is read back: the 400 path proves the
	;      new route is mounted+served over the wire on both bare engines; the 200
	;      path is FileMan-gated (live).
	; Driver stack only (m/v waterline — the ONLY path):
	;   m test --engine ydb  --docker m-test-engine ...   (bare YDB)
	;   m test --engine iris --docker m-test-iris  ...     (bare IRIS)
	;   m test --engine ydb  --docker vehu     --chset m       --routines ... (live YDB-VistA)
	;   m test --engine iris --docker foia-t12 --namespace VISTA --routines ... (live IRIS-VistA)
	; The known-DFN tests are READ-ONLY: they discover an existing #2 record by
	; scanning $$exists^VSLFS (never a direct ^DPT), so nothing is mutated and there
	; is nothing to back out. The 404 test targets a confirmed-free DFN.
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tRoutePatientMatches(.pass,.fail)
	do tRouteCapturesId(.pass,.fail)
	do tHealthStillRouted(.pass,.fail)
	do tSplitName(.pass,.fail)
	do tGenderMapping(.pass,.fail)
	do tBirthDateMapping(.pass,.fail)
	do tBadIdIs400(.pass,.fail)
	do tBadIdOverSocket(.pass,.fail)
	do tUnknownDfnIs404(.pass,.fail)
	do tKnownPatientIs200Fhir(.pass,.fail)
	do tKnownPatientOverSocket(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
hasFileMan()	; 1 iff the FileMan DBS API ($$GET1^DIQ) is present (a live VistA).
	quit $text(GET1^DIQ)'=""
	;
routesNoAuth(SRV)	; The real route table with the auth middleware stripped.
	; M6.5 made routes^VWEBR register VWEBA's auth middleware, so /Patient/:id is
	; now protected. VWEBRTST tests the HANDLER + ROUTING in isolation (auth is
	; VWEBATST's job), so it drives the same table with the middleware chain
	; removed. End-to-end auth on the route is proven in VWEBATST.
	do routes^VWEBR(.SRV)
	kill SRV("mw")
	quit
	;
rawByteSafe()	; 1 iff raw sockets preserve CRLF bytes end-to-end (HTTP framing needs it).
	; Same live regression guard VWEBLTST carries: YDB always; IRIS since MSL
	; v0.12.1 (STDNET readIris CR-termination fix). Auto-skips if a future engine
	; regresses CRLF or sockets are unavailable.
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
existingDfn()	; Discover an existing #2 DFN by scanning $$exists^VSLFS (read-only; no
	; direct ^DPT). Returns the first DFN found in 1..5000, or "" if none.
	new dfn,found
	set found=""
	for dfn=1:1:5000 do  quit:found'=""
	. if $$exists^VSLFS(2,dfn_",") set found=dfn
	quit found
	;
freeDfn()	; A DFN confirmed NOT to exist in file #2 (for the 404 path).
	new dfn,free
	set free=""
	for dfn=9000001:1:9000050 do  quit:free'=""
	. if '$$exists^VSLFS(2,dfn_",") set free=dfn
	quit free
	;
tRoutePatientMatches(pass,fail)	;@TEST "routes() registers GET /Patient/:id -> getPatient^VWEBR"
	new SRV,route,params,st
	do routes^VWEBR(.SRV)
	set st=$$match^STDHTTPD(.SRV,"GET","/Patient/123",.route,.params)
	do eq^STDASSERT(.pass,.fail,st,200,"GET /Patient/123 matches a route")
	do eq^STDASSERT(.pass,.fail,$get(route("handler")),"getPatient^VWEBR","dispatches to getPatient^VWEBR")
	quit
	;
tRouteCapturesId(pass,fail)	;@TEST "the :id path segment is captured into params(""id"")"
	new SRV,route,params,st
	do routes^VWEBR(.SRV)
	set st=$$match^STDHTTPD(.SRV,"GET","/Patient/4567",.route,.params)
	do eq^STDASSERT(.pass,.fail,$get(params("id")),"4567","params(""id"") = the path DFN")
	quit
	;
tHealthStillRouted(pass,fail)	;@TEST "GET /healthz is still routed (the table is no longer health-only but keeps it)"
	new SRV,route,params,st
	do routes^VWEBR(.SRV)
	set st=$$match^STDHTTPD(.SRV,"GET","/healthz",.route,.params)
	do eq^STDASSERT(.pass,.fail,st,200,"GET /healthz still matches")
	do eq^STDASSERT(.pass,.fail,$get(route("handler")),"health^VWEBL","still the VWEBL health handler")
	quit
	;
tSplitName(pass,fail)	;@TEST "splitName maps a VistA #2 NAME (LAST,FIRST MIDDLE) to family + first given [both engines, no FileMan]"
	new family,given
	do splitName^VWEBR("DOE,JOHN A",.family,.given)
	do eq^STDASSERT(.pass,.fail,family,"DOE","family = the piece before the comma")
	do eq^STDASSERT(.pass,.fail,given,"JOHN","given = the first token after the comma")
	do splitName^VWEBR("CHER",.family,.given)
	do eq^STDASSERT(.pass,.fail,family,"CHER","family-only name keeps the family")
	do eq^STDASSERT(.pass,.fail,given,"","family-only name has no given")
	quit
	;
tGenderMapping(pass,fail)	;@TEST "FileMan external SEX maps to a FHIR gender code [both engines, no FileMan]"
	do eq^STDASSERT(.pass,.fail,$$gender^VWEBR("MALE"),"male","MALE -> male")
	do eq^STDASSERT(.pass,.fail,$$gender^VWEBR("FEMALE"),"female","FEMALE -> female")
	do eq^STDASSERT(.pass,.fail,$$gender^VWEBR(""),"","unset SEX -> omitted (empty)")
	do eq^STDASSERT(.pass,.fail,$$gender^VWEBR("UNKNOWN"),"other","any other coded value -> other")
	quit
	;
tBirthDateMapping(pass,fail)	;@TEST "FileMan external dates convert to FHIR YYYY[-MM[-DD]] [both engines, no FileMan]"
	do eq^STDASSERT(.pass,.fail,$$fmToIso^VWEBR("JAN 01, 1950"),"1950-01-01","full date -> YYYY-MM-DD")
	do eq^STDASSERT(.pass,.fail,$$fmToIso^VWEBR("DEC 25, 1999"),"1999-12-25","another full date")
	do eq^STDASSERT(.pass,.fail,$$fmToIso^VWEBR("FEB 1950"),"1950-02","month+year -> YYYY-MM")
	do eq^STDASSERT(.pass,.fail,$$fmToIso^VWEBR("1950"),"1950","year only -> YYYY")
	do eq^STDASSERT(.pass,.fail,$$fmToIso^VWEBR(""),"","unset/unparseable -> omitted (empty)")
	quit
	;
tBadIdIs400(pass,fail)	;@TEST "a non-numeric id -> 400 (FHIR OperationOutcome), no FileMan touched (runs on a bare engine)"
	new SRV,REQ,RSP,st
	do routesNoAuth(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/abc"
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),400,"status 400 for a non-numeric DFN")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","resourceType")),"s:OperationOutcome","a FHIR OperationOutcome body")
	quit
	;
tBadIdOverSocket(pass,fail)	;@TEST "the /Patient route is served over a real socket: bad id -> 400 on the wire (both bare engines)"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped (regression guard)") quit
	set cr=$char(13,10)
	set req="GET /Patient/abc HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do routesNoAuth(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,$$write^STDNET(cli,req),"client wrote GET /Patient/abc")
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	do eq^STDASSERT(.pass,.fail,n,1,"serveConn served exactly one request")
	set rn=$$read^STDNET(cli,16384,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),400,"status 400 on the wire for a bad id")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
tUnknownDfnIs404(pass,fail)	;@TEST "an unknown DFN -> 404 (FHIR OperationOutcome) [live VistA only]"
	new SRV,REQ,RSP,st,dfn
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan ($$GET1^DIQ) absent (bare engine) - 404 verified on vehu/foia") quit
	set dfn=$$freeDfn()
	if dfn="" do true^STDASSERT(.pass,.fail,1,"no free DFN found in the probe range - skipped") quit
	do routesNoAuth(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/"_dfn
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),404,"status 404 for an absent DFN")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","resourceType")),"s:OperationOutcome","a FHIR OperationOutcome body")
	quit
	;
tKnownPatientIs200Fhir(pass,fail)	;@TEST "a known DFN -> 200 minimal FHIR R4 Patient (id/name/identifier) [live VistA only]"
	new SRV,REQ,RSP,st,dfn,bd
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan absent (bare engine) - 200 FHIR Patient verified on vehu/foia") quit
	set dfn=$$existingDfn()
	if dfn="" do true^STDASSERT(.pass,.fail,1,"PATIENT (#2) empty/unpopulated in DFN 1..5000 (e.g. a scrubbed FOIA build) - real-read verified on a populated system (vehu)") quit
	do routesNoAuth(.SRV)
	set REQ("method")="GET",REQ("path")="/Patient/"_dfn
	set st=$$dispatch^STDHTTPD(.SRV,.REQ,.RSP)
	do eq^STDASSERT(.pass,.fail,$get(RSP("status")),200,"status 200 for a known DFN")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","resourceType")),"s:Patient","resourceType Patient")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","id")),"s:"_dfn,"resource id = the DFN")
	do true^STDASSERT(.pass,.fail,$data(RSP("json","name",1)),"has a name element")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","identifier",1,"value")),"s:"_dfn,"MRN identifier value = the DFN")
	do eq^STDASSERT(.pass,.fail,$get(RSP("json","identifier",1,"type","coding",1,"code")),"s:MR","identifier type code MR")
	; birthDate, when present, is FHIR YYYY[-MM[-DD]] (not the FileMan external string)
	set bd=$piece($get(RSP("json","birthDate")),"s:",2)
	do:bd'="" true^STDASSERT(.pass,.fail,bd?4N!(bd?4N1"-"2N)!(bd?4N1"-"2N1"-"2N),"birthDate is FHIR date format ("_bd_")")
	quit
	;
tKnownPatientOverSocket(pass,fail)	;@TEST "a known DFN -> 200 FHIR Patient over a real socket [live VistA only]"
	new srv,cli,conn,port,SRV,opts,n,cr,req,resp,rn,R,T,dfn
	if '$$hasFileMan() do true^STDASSERT(.pass,.fail,1,"FileMan absent (bare engine) - socket 200 verified on vehu/foia") quit
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	if '$$rawByteSafe() do true^STDASSERT(.pass,.fail,1,"raw CRLF not preserved here - socket serve skipped") quit
	set dfn=$$existingDfn()
	if dfn="" do true^STDASSERT(.pass,.fail,1,"PATIENT (#2) empty/unpopulated in DFN 1..5000 (e.g. a scrubbed FOIA build) - real-read verified on a populated system (vehu)") quit
	set cr=$char(13,10)
	set req="GET /Patient/"_dfn_" HTTP/1.1"_cr_"Host: x"_cr_"Connection: close"_cr_cr
	do routesNoAuth(.SRV)
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	set n=$$write^STDNET(cli,req)
	set conn=$$accept^VWEBIO(srv,5)
	set n=$$serveConn^VWEBL(.SRV,conn,.opts)
	set rn=$$read^STDNET(cli,65536,5,.resp)
	set n=$$parseRsp^STDHTTPMSG(resp,.R)
	do eq^STDASSERT(.pass,.fail,$get(R("status")),200,"status 200 on the wire")
	do true^STDASSERT(.pass,.fail,$$parse^STDJSON($get(R("body")),.T),"response body parses as JSON")
	do eq^STDASSERT(.pass,.fail,$get(T("resourceType")),"s:Patient","body is a FHIR Patient")
	do eq^STDASSERT(.pass,.fail,$get(T("id")),"s:"_dfn,"body id = the DFN")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
