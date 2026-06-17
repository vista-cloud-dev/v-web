VWEBENVTST	; v-web — VWEBENV (KIDS environment check) test suite.
	; VWEBENV extends VSLENV's facts (engine/version/kernel/tls) with a VWEB
	; server-TLS-config presence fact. The base VSLENV facts resolve on any
	; engine (internal fault-traps); the Kernel/TLS facts are populated live on
	; vehu/foia. Driver stack only.
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tCheckReturnsBaseFacts(.pass,.fail)
	do tCheckAddsTlsFact(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
tCheckReturnsBaseFacts(pass,fail)	;@TEST "check() pulls the VSLENV base facts (engine identified)"
	new facts
	if $text(VERSION^XPDUTL)="" do true^STDASSERT(.pass,.fail,1,"Kernel (XPDUTL) absent (bare engine) - skipped; verified on vehu/foia") quit
	do check^VWEBENV(.facts)
	do true^STDASSERT(.pass,.fail,$get(facts("engine"))'="","facts(""engine"") is populated from VSLENV")
	do true^STDASSERT(.pass,.fail,$get(facts("version"))'="","facts(""version"") is populated")
	quit
	;
tCheckAddsTlsFact(pass,fail)	;@TEST "check() adds the VWEB server-TLS-config presence fact (0/1)"
	new facts,t
	if $text(VERSION^XPDUTL)="" do true^STDASSERT(.pass,.fail,1,"Kernel (XPDUTL) absent (bare engine) - skipped; verified on vehu/foia") quit
	do check^VWEBENV(.facts)
	set t=$get(facts("vweb","tls"))
	do true^STDASSERT(.pass,.fail,(t=0)!(t=1),"facts(""vweb"",""tls"") is a strict 0/1 flag")
	quit
