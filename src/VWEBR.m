VWEBR	; v-web — route table + FHIR /Patient/:id handler (M6.4, spec §3/§6).
	;
	; M6.4 mounts the first real route on the M6.3 transport: a FHIR R4 Patient
	; read from PATIENT (#2). routes() owns the route table (STDHTTPD §6 Q3:
	; caller-owned data) — VWEBL's run/serveConn build SRV from here; getPatient
	; is the STDHTTPD handler (do @ref(.REQ,.RSP)).
	;
	; The route-table STORE (spec D3: a FileMan-file-backed vs code-built table)
	; is OUT of M6.4 scope — the table is code-built here; D3 is owed.
	;
	; Layer: v. Consumes STDHTTPD (m, routing) + STDJSON (m, via the RSP("json")
	; seam — serializeRsp^STDHTTPMSG encodes it and adds Content-Type) + VSLFS
	; (v, FileMan #2 read). No direct ^DPT: v->v through VSLFS, so the no-direct-
	; global / ICR-empty waterline holds.
	;
	; FHIR field mapping (minimal R4 Patient; full conformance out of scope):
	;   id          <- the DFN (the #2 internal entry number)
	;   identifier  <- MRN (type code MR): system urn:vista:dfn, value = DFN. The
	;                  DFN is the defensible single-station MRN — the ICN forbids
	;                  direct access (MPIF) and SSN is PII. (vdocs: ADT PIMS TM
	;                  "DFN = internal entry number in #2"; MPIF "direct access to
	;                  ICNs not allowed".)
	;   name.family/given <- #.01 NAME ("LAST,FIRST MIDDLE" -> family + first given)
	;   gender      <- #.02 SEX (FileMan external MALE/FEMALE -> male/female)
	;   birthDate   <- #.03 DATE OF BIRTH (FileMan external "JAN 01, 1950" ->
	;                  FHIR YYYY-MM-DD; partial dates degrade to YYYY / YYYY-MM)
	; (vdocs: DI User Manual SET-OF-CODES SEX m->MALE/f->FEMALE; DI Dev Guide
	;  D^DIQ external date "JAN 01, 1998"; $$GET1^DIQ default = external values.)
	;
	; Public:
	;   routes(.SRV)          — register GET /healthz + /Patient/:id, and delegate
	;                           the traffic-console routes to routes^VWEBT
	;   getPatient(.REQ,.RSP) — the /Patient/:id handler
	;
	quit
	;
routes(SRV)	; Build the route table: /healthz + /Patient/:id + the traffic console.
	; doc: @param SRV  array  by-ref route table (populated by side-effect)
	; First-registered wins on overlap (STDHTTPD §6); /healthz stays the liveness
	; probe, /Patient/:id is the first FileMan-backed route.
	; Auth (M6.5): register VWEBA's middleware FIRST so it runs ahead of every
	; handler; it gates protected routes and lets the open path (/healthz) through.
	; getPatient stays byte-for-byte auth-agnostic (identity lives in the middleware).
	do register^VWEBA(.SRV)
	do route^STDHTTPD(.SRV,"GET","/healthz","health^VWEBL")
	do route^STDHTTPD(.SRV,"GET","/Patient/:id","getPatient^VWEBR")
	do routes^VWEBT(.SRV)
	quit
	;
getPatient(REQ,RSP)	; GET /Patient/:id -> a minimal FHIR R4 Patient read from #2 via VSLFS.
	; doc: @param REQ  array  by-ref parsed request (REQ("param","id") = the DFN)
	; doc: @param RSP  array  by-ref response: status + the json body (STDHTTPD
	; doc:                    serializes RSP("json") with STDJSON and sets Content-Type)
	; Auth-agnostic (M6.5 adds auth): reads REQ, writes RSP. Non-numeric id -> 400;
	; absent DFN -> 404; otherwise the Patient resource at 200.
	new id,iens,name,family,given,sex,gender,dob,bd
	set id=$get(REQ("param","id"))
	; 400 before any FileMan touch (so this arm runs on a bare engine too)
	if id'?1.N do fail(.RSP,400,"invalid","id must be a numeric DFN") quit
	set iens=id_","
	if '$$exists^VSLFS(2,iens) do fail(.RSP,404,"not-found","no PATIENT (#2) record for DFN "_id) quit
	; read the #2 fields through VSLFS (FileMan DBS, external values)
	set name=$$get^VSLFS(2,iens,".01","")
	set sex=$$get^VSLFS(2,iens,".02","")
	set dob=$$get^VSLFS(2,iens,".03","")
	; --- build the minimal FHIR R4 Patient directly in the RSP("json") tree
	; (STDJSON typed-node convention: "o" object, "a" array, "s:" string) ---
	kill RSP
	set RSP("json")="o"
	set RSP("json","resourceType")="s:Patient"
	set RSP("json","id")="s:"_id
	; identifier: the DFN as an MRN (type MR)
	set RSP("json","identifier")="a"
	set RSP("json","identifier",1)="o"
	set RSP("json","identifier",1,"type")="o"
	set RSP("json","identifier",1,"type","coding")="a"
	set RSP("json","identifier",1,"type","coding",1)="o"
	set RSP("json","identifier",1,"type","coding",1,"system")="s:http://terminology.hl7.org/CodeSystem/v2-0203"
	set RSP("json","identifier",1,"type","coding",1,"code")="s:MR"
	set RSP("json","identifier",1,"system")="s:urn:vista:dfn"
	set RSP("json","identifier",1,"value")="s:"_id
	; name (always emit a HumanName element; family/given only when present)
	do splitName(name,.family,.given)
	set RSP("json","name")="a"
	set RSP("json","name",1)="o"
	if family'="" set RSP("json","name",1,"family")="s:"_family
	if given'="" set RSP("json","name",1,"given")="a",RSP("json","name",1,"given",1)="s:"_given
	; gender / birthDate (omit when unmappable rather than emit an invalid value)
	set gender=$$gender(sex)
	if gender'="" set RSP("json","gender")="s:"_gender
	set bd=$$fmToIso(dob)
	if bd'="" set RSP("json","birthDate")="s:"_bd
	set RSP("status")=200
	quit
	;
	; ---------- internal helpers (pure-M, dual-engine) ----------
	;
fail(RSP,status,code,diag)	; (private) build a FHIR OperationOutcome error response.
	; doc: @internal
	kill RSP
	set RSP("status")=status
	set RSP("json")="o"
	set RSP("json","resourceType")="s:OperationOutcome"
	set RSP("json","issue")="a"
	set RSP("json","issue",1)="o"
	set RSP("json","issue",1,"severity")="s:error"
	set RSP("json","issue",1,"code")="s:"_code
	set RSP("json","issue",1,"diagnostics")="s:"_diag
	quit
	;
splitName(name,family,given)	; (private) split a #2 NAME ("LAST,FIRST MIDDLE") into family + first given.
	; doc: @internal
	set family=$$trim^STDSTR($piece(name,",",1))
	set given=$$trim^STDSTR($piece($piece(name,",",2,999)," ",1))
	quit
	;
gender(sex)	; (private) map FileMan external SEX (MALE/FEMALE) to a FHIR gender code.
	; doc: @internal
	if sex="MALE" quit "male"
	if sex="FEMALE" quit "female"
	if sex="" quit ""
	quit "other"
	;
fmToIso(ext)	; (private) FileMan external date ("JAN 01, 1950") -> FHIR YYYY[-MM[-DD]].
	; doc: @internal  Tokenizes on spaces (commas dropped); finds a 4-digit year,
	; doc: a 3-letter month, and a 1-2 digit day in any order. Returns "" when no
	; doc: year is recoverable (so birthDate is omitted rather than invalid).
	new s,i,tok,yr,mon,day,m
	set s=$translate($get(ext),",",""),yr="",mon="",day=""
	for i=1:1:$length(s," ") do
	. set tok=$piece(s," ",i)
	. if tok="" quit
	. if (tok?4N),yr="" set yr=tok quit
	. if (tok?1.2N),day="" set day=tok quit
	. if mon="" set m=$$monNum(tok) set:m>0 mon=m
	if yr="" quit ""
	if mon="" quit yr
	if day="" quit yr_"-"_$$pad2(mon)
	quit yr_"-"_$$pad2(mon)_"-"_$$pad2(day)
	;
monNum(tok)	; (private) 3-letter month abbreviation -> 1..12, else 0.
	; doc: @internal
	new p
	set p=$find("JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC",tok)
	if 'p quit 0
	if (p-4)#3 quit 0
	quit ((p-4)/3)+1
	;
pad2(n)	; (private) left-pad an integer to 2 digits.
	; doc: @internal
	quit $extract("0"_n,$length("0"_n)-1,$length("0"_n))
