VWEBA	; v-web — auth middleware: a Bearer credential -> a VistA principal (DUZ/#200).
	;
	; M6.5 closes the M6.4 route. VWEBA is an STDHTTPD middleware ($$use, run
	; before every handler) that turns an inbound Bearer token into an
	; authenticated subject, binds that subject to a NEW PERSON (#200) IEN (DUZ),
	; and rejects the unauthenticated with 401. /healthz stays open (liveness).
	;
	; THE ARCHITECTURE (validate a TOKEN, not the PIV card). VA authentication is
	; PIV+PIN -> AD -> IAM SSOi/STS -> a signed token (SAML for staff, OAuth/JWT
	; for APIs); the relying party validates the TOKEN and maps it to a local
	; user. VWEBA is that relying party. The split is the m/v waterline:
	;   - token validation is engine-neutral -> STDJWT (m): signature + RFC 7519
	;     exp/nbf/iss/aud. (RS256/ES256 via JWKS + SAML/introspection are staged
	;     follow-on PROVIDERS behind $$validate's dispatch; M6.5 wires "jwt".)
	;   - the subject -> #200 IEN binding is VistA-specific -> VSLSEC (v): SecID
	;     via EN1^XUPSQRY (the SSOi map), mirroring Kernel's own XUSAML/XUESSO2.
	; VWEBA itself makes NO direct VistA call (all via VSL*/STD*), so the ICR
	; registry stays empty and the no-direct-global gate is trivially green.
	;
	; CONFIG ($$cfg) reads a runtime-config cache ^VWEB("rtcfg",<param>) FIRST
	; (the listener can warm it at startup; tests set it directly so the chain
	; runs with no XPAR / no KIDS install), then XPAR via VWEBCFG (the source of
	; truth on a live system), then a default. FAIL-CLOSED: with no signing key
	; configured, every token is rejected (never silently open).
	;
	; DUZ: on a successful authentication VWEBA SETS DUZ to the bound #200 IEN so
	; the handler's VSLFS/FileMan reads run AS the authenticated user. It is set
	; on every authenticated request before the handler runs; a failed auth
	; short-circuits (CTX("stop")) BEFORE the handler, so a stale DUZ from a prior
	; keep-alive request never reaches a handler. The binding is a VistA operation
	; ($text(GET1^DIQ)-gated): on a bare engine a cryptographically-verified
	; request passes through with DUZ unresolved (bare handlers touch no FileMan).
	;
	; Layer: v. Consumes STDHTTPD/STDJSON/STDJWT/STDSTR (m) + VSLSEC/VWEBCFG (v).
	;
	; Public:
	;   register(.SRV)        — register authn^VWEBA as a middleware on SRV
	;   authn(.REQ,.RSP,.CTX) — the middleware (STDHTTPD 3-arg signature)
	;   isOpen(path)          — 1 iff `path` is an open (no-auth) path
	;   bearer(.REQ)          — extract the Bearer token from REQ, or ""
	;   bind(subject,method)  — map an authenticated subject to a #200 IEN, or ""
	;   lastError()           — the last auth-failure reason
	;
	quit
	;
register(SRV)	; Register authn^VWEBA so it runs ahead of every handler.
	; doc: @param SRV  array  by-ref route table / server config (STDHTTPD)
	; Called from routes^VWEBR. Middleware run in registration order, before the
	; route match, for EVERY request (so authn itself skips the open path).
	do use^STDHTTPD(.SRV,"authn^VWEBA")
	quit
	;
authn(REQ,RSP,CTX)	; The auth middleware: authenticate + bind, or short-circuit 401/403.
	; doc: @param REQ  array  by-ref parsed request (reads hdr; stashes REQ("auth",...))
	; doc: @param RSP  array  by-ref response (populated on a 401/403 short-circuit)
	; doc: @param CTX  array  by-ref middleware context; CTX("stop")=1 halts the chain
	; The STDHTTPD middleware contract: do @authn^VWEBA(.REQ,.RSP,.CTX); set
	; CTX("stop")=1 + populate RSP to deny (handler never runs, dispatch returns
	; RSP("status")). A clean return lets the request continue to the handler.
	new tok,subject,duz
	set subject=""
	if $$isOpen($get(REQ("path"))) quit
	set tok=$$bearer(.REQ)
	if tok="" do deny401(.RSP,.CTX,"missing or malformed Bearer credential",0) quit
	if '$$validate(tok,.subject) do deny401(.RSP,.CTX,$$lastError(),1) quit
	set REQ("auth","subject")=subject
	; bind subject -> VistA principal (live VistA only)
	if '$$hasVista() quit
	set duz=$$bind(subject,$$cfg("VWEB AUTH IDENTITY MAP","secid"))
	if duz="" do deny403(.RSP,.CTX,"authenticated subject is not provisioned in NEW PERSON (#200)") quit
	set DUZ=duz,REQ("auth","duz")=duz
	quit
	;
isOpen(path)	; 1 iff `path` is an open (no-authentication) path.
	; doc: @param path  string  the request path
	; doc: @returns     bool    1 for the liveness probe (/healthz), else 0
	; The allow-list is intentionally tiny: liveness must answer without a token.
	quit $get(path)="/healthz"
	;
bearer(REQ)	; Extract the token from an "Authorization: Bearer <token>" header, or "".
	; doc: @param REQ  array  by-ref parsed request (REQ("hdr","authorization"))
	; doc: @returns    string the Bearer token, or "" (absent / non-Bearer scheme)
	; STDHTTPMSG lowercases header NAMES; the scheme match here is case-insensitive.
	new h
	set h=$get(REQ("hdr","authorization"))
	if h="" quit ""
	if $$toLowerASCII^STDSTR($piece(h," ",1))'="bearer" quit ""
	quit $piece(h," ",2,$length(h," "))
	;
bind(subject,method)	; Map an authenticated subject to a #200 IEN (DUZ), or "".
	; doc: @param subject  string  the authenticated subject (a SecID, or a #200 IEN)
	; doc: @param method   string  the identity-map method: "secid" (default) | "ien"
	; doc: @returns        numeric the bound #200 IEN, or "" if not provisioned
	; secid = the SSOi/production map (VSLSEC -> EN1^XUPSQRY); ien = the subject IS
	; a #200 IEN (the dev/direct map). Both go through VSLSEC (v->v; no #200 read here).
	if $get(method)="ien" quit $$byIen(subject)
	quit $$bySecid^VSLSEC(subject)
	;
lastError()	; The last auth-failure reason ("" when none).
	; doc: @returns  string  ^TMP($job,"vweba","err"), or ""
	quit $get(^TMP($job,"vweba","err"))
	;
	; ---------- internals ----------
	;
validate(tok,subject)	; Provider dispatch: validate `tok` -> 1 + the subject by-ref, else 0.
	; doc: @internal
	; The provider seam. M6.5 wires the "jwt" provider (STDJWT, HS256). RFC 7662
	; introspection / SAML are future providers dispatched on VWEB AUTH PROVIDER.
	new key,claims,opts,prov
	set subject="",prov=$$cfg("VWEB AUTH PROVIDER","jwt")
	if prov'="jwt" do seterr("unsupported auth provider '"_prov_"'") quit 0
	set key=$$cfg("VWEB AUTH JWT KEY","")
	if key="" do seterr("server auth is not configured (no signing key)") quit 0
	set opts("iss")=$$cfg("VWEB AUTH ISSUER","")
	set opts("aud")=$$cfg("VWEB AUTH AUDIENCE","")
	if '$$verify^STDJWT(tok,key,.claims,.opts) do seterr($$lastError^STDJWT()) quit 0
	set subject=$$valueOf^STDJSON($get(claims($$cfg("VWEB AUTH SUBJECT CLAIM","sub"))))
	if subject="" do seterr("the token carries no subject claim") quit 0
	quit 1
	;
byIen(subject)	; The "ien" identity map: the subject IS a #200 IEN; validate it resolves.
	; doc: @internal
	if subject'?1.N quit ""
	if $$user^VSLSEC(subject)="" quit ""
	quit subject
	;
cfg(name,default)	; Resolve an auth config param: rtcfg cache -> XPAR (VWEBCFG) -> default.
	; doc: @internal
	; ^VWEB("rtcfg",name) is the runtime cache (listener-warmed / test-set); XPAR
	; (#8989.51 via VWEBCFG) is the source of truth on a live VistA.
	if $data(^VWEB("rtcfg",name)) quit ^VWEB("rtcfg",name)
	if '$$hasXpar() quit default
	quit $$get^VWEBCFG(name,default)
	;
hasXpar()	; 1 iff Kernel XPAR ($$GET^XPAR) is present (a live VistA with XPAR).
	; doc: @internal
	; doc: @icr 2263 @call $$GET^XPAR @status Supported @custodian XU @source XU/krn_8_0_dg_toolkit_ug#getxpar-return-an-instance-of-a-parameter
	; $text-probe only (never invoked here — VWEBCFG/VSLCFG own the call); the @icr
	; records the L4 symbol dependency this runtime gate keys on.
	quit $text(GET^XPAR)'=""
	;
hasVista()	; 1 iff the VistA identity surface (FileMan DBS $$GET1^DIQ) is present.
	; doc: @internal
	; doc: @icr DBS @call $$GET1^DIQ @status Supported @custodian DI @source DI/fm22_2dg#get1diq-data-retriever-single-field
	; $text-probe only (never invoked here — VSLSEC/VSLFS own the call); the @icr
	; (notional DBS — no numeric DBIA in the gold corpus) records the dependency.
	quit $text(GET1^DIQ)'=""
	;
deny401(RSP,CTX,reason,hadtoken)	; Build a 401 (FHIR OperationOutcome + WWW-Authenticate) and stop the chain.
	; doc: @internal
	do oo(.RSP,401,"security",reason)
	set RSP("hdr","WWW-Authenticate")=$select(+$get(hadtoken):"Bearer error=""invalid_token""",1:"Bearer realm=""vista""")
	set CTX("stop")=1
	quit
	;
deny403(RSP,CTX,reason)	; Build a 403 (authenticated but not provisioned) and stop the chain.
	; doc: @internal
	do oo(.RSP,403,"forbidden",reason)
	set CTX("stop")=1
	quit
	;
oo(RSP,status,code,diag)	; Build a FHIR R4 OperationOutcome response (status + json body).
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
seterr(msg)	; Stash the auth-failure reason for $$lastError.
	; doc: @internal
	set ^TMP($job,"vweba","err")=msg
	quit
