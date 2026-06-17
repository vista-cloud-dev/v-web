VWEBENV	; v-web — KIDS environment check (spec §14). Run by KIDS at load/install.
	;
	; Extends VSLENV's base facts (engine/version/kernel/tls) with VWEB's
	; server-TLS-config presence. Self-contained at check time except for the
	; RESIDENT VSL Required Build (VSLENV + VSLCFG install first, so they are
	; resident when VWEB's check runs). All VistA access is delegated to those
	; VSL* routines (v -> v) — VWEB makes NO direct Kernel/XPAR call, so the ICR
	; registry stays empty and the waterline story is clean.
	;
	; HTTP-first: a missing server TLS config is RECORDED, never a hard abort —
	; the listener serves plaintext until TLS is operator-provisioned (M2.T2).
	; The VSL base check (VSLENV, run as the Required Build's own envCheck) is
	; what aborts the install on a genuine showstopper (Kernel absent); VWEB adds
	; only the TLS-config fact.
	;
	new facts
	set facts=$$check(.facts)
	quit
	;
check(facts)	; Fill `facts` with the VSLENV base facts + the VWEB TLS-config fact.
	; doc: @param   facts  array  (by ref) engine/version/kernel/tls + vweb.tls*
	; doc: @returns        bool   1
	new x
	set x=$$check^VSLENV(.facts)
	set facts("vweb","tlsConfig")=$$get^VSLCFG("VWEB TLS SERVER CONFIG","")
	set facts("vweb","tls")=$select($get(facts("vweb","tlsConfig"))'="":1,1:0)
	if $quit quit 1
	quit
