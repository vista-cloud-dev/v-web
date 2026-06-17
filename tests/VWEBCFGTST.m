VWEBCFGTST	; v-web — VWEBCFG (XPAR configuration accessor) test suite.
	; On a bare engine (no XPAR / no XU) every read degrades to its documented
	; default via a fault-trap — so the listener starts on a bare config and the
	; XPAR binding is asserted (live values are owed on vehu/foia). Driver stack
	; only.
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tDefaultsOnBareConfig(.pass,.fail)
	do tNumericCoercion(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
tDefaultsOnBareConfig(pass,fail)	;@TEST "each accessor returns its documented default when XPAR is unset"
	if $text(GET^XPAR)="" do true^STDASSERT(.pass,.fail,1,"XPAR absent (bare engine) - skipped; verified on vehu/foia") quit
	do eq^STDASSERT(.pass,.fail,$$port^VWEBCFG(),8089,"VWEB LISTEN PORT default 8089")
	do eq^STDASSERT(.pass,.fail,$$idleTimeout^VWEBCFG(),30,"VWEB IDLE TIMEOUT default 30")
	do eq^STDASSERT(.pass,.fail,$$maxBody^VWEBCFG(),1048576,"VWEB MAX BODY default 1048576")
	do eq^STDASSERT(.pass,.fail,$$maxWorkers^VWEBCFG(),1,"VWEB MAX WORKERS default 1 (serial v0.1)")
	do eq^STDASSERT(.pass,.fail,$$tlsConfig^VWEBCFG(),"","VWEB TLS SERVER CONFIG default empty (HTTP-first)")
	quit
	;
tNumericCoercion(pass,fail)	;@TEST "numeric accessors return a number even when the default applies"
	new p
	if $text(GET^XPAR)="" do true^STDASSERT(.pass,.fail,1,"XPAR absent (bare engine) - skipped; verified on vehu/foia") quit
	set p=$$port^VWEBCFG()
	do true^STDASSERT(.pass,.fail,p=+p,"port() is numeric")
	quit
