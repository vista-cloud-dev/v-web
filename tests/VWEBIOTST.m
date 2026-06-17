VWEBIOTST	; v-web — VWEBIO (engine device/TLS transport adapter) test suite.
	; Proves the transport descriptor STDHTTPD's $$serve consumes, the thin
	; read/write wrappers over STDNET (signature-compatible), the listen/accept
	; socket open, and the loud TLS gap. Single-process loopback over real
	; engine-native sockets (the STDNET idiom) — no fake transport. Run over the
	; driver stack only (m/v waterline):
	;   m test --engine ydb  --docker m-test-engine \
	;     --routines src --routines <m-stdlib>/src --routines <v-stdlib>/src \
	;     tests/VWEBIOTST.m
	;   m test --engine iris --docker m-test-iris  ... (same routines)
	new pass,fail
	do start^STDASSERT(.pass,.fail)
	;
	do tTransportDescriptor(.pass,.fail)
	do tListenAcceptClose(.pass,.fail)
	do tReadWriteRoundtrip(.pass,.fail)
	do tTlsAbsentIsLoud(.pass,.fail)
	;
	do report^STDASSERT(pass,fail)
	quit
	;
tTransportDescriptor(pass,fail)	;@TEST "transport() builds the TR descriptor $$serve consumes (read/write entry-refs)"
	new TR
	do transport^VWEBIO(.TR)
	do eq^STDASSERT(.pass,.fail,$get(TR("read")),"read^VWEBIO","TR(""read"") is read^VWEBIO")
	do eq^STDASSERT(.pass,.fail,$get(TR("write")),"write^VWEBIO","TR(""write"") is write^VWEBIO")
	quit
	;
tListenAcceptClose(pass,fail)	;@TEST "listen()/boundport()/accept()/close() open a socket and accept a connection"
	new srv,cli,conn,port,n
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	set srv=$$listen^VWEBIO(0)
	do true^STDASSERT(.pass,.fail,srv>0,"listener opened on an OS-assigned port")
	set port=$$boundport^VWEBIO(srv)
	do true^STDASSERT(.pass,.fail,+port>0,"boundport() reports the bound port")
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	do true^STDASSERT(.pass,.fail,cli>0,"a client connected to it")
	set conn=$$accept^VWEBIO(srv,5)
	do true^STDASSERT(.pass,.fail,conn>0,"accept() returned a connected handle")
	do true^STDASSERT(.pass,.fail,$$close^VWEBIO(conn),"close() is idempotent-true")
	set n=$$close^STDNET(cli),n=$$close^VWEBIO(srv)
	quit
	;
tReadWriteRoundtrip(pass,fail)	;@TEST "read()/write() wrappers round-trip raw bytes over a real socket (STDNET pass-through)"
	new srv,cli,conn,port,buf,n
	if '$$available^STDNET() do true^STDASSERT(.pass,.fail,1,"sockets not wired here - skipped") quit
	set srv=$$listen^VWEBIO(0),port=$$boundport^VWEBIO(srv)
	set cli=$$connect^STDNET("127.0.0.1",port,5)
	set conn=$$accept^VWEBIO(srv,5)
	do true^STDASSERT(.pass,.fail,$$write^VWEBIO(cli,"ping"),"write() wrote outbound")
	set n=$$read^VWEBIO(conn,99,5,.buf)
	do eq^STDASSERT(.pass,.fail,buf,"ping","read() received the bytes by-reference")
	do true^STDASSERT(.pass,.fail,$$write^VWEBIO(conn,"pong"),"write() echoed")
	set n=$$read^VWEBIO(cli,99,5,.buf)
	do eq^STDASSERT(.pass,.fail,buf,"pong","read() received the reply")
	set n=$$close^VWEBIO(cli),n=$$close^VWEBIO(conn),n=$$close^VWEBIO(srv)
	quit
	;
tTlsAbsentIsLoud(pass,fail)	;@TEST "TLS is a loud, documented gap — listenTls raises U-VWEB-NOTLS, never a silent plaintext fallback"
	do true^STDASSERT(.pass,.fail,'$$tlsAvailable^VWEBIO(),"tlsAvailable()=0 (no engine TLS plugin wired)")
	do raises^STDASSERT(.pass,.fail,"set x=$$listenTls^VWEBIO(443,""FOO"")","U-VWEB-NOTLS","listenTls raises U-VWEB-NOTLS")
	do contains^STDASSERT(.pass,.fail,$$lastError^VWEBIO(),"NOTLS","lastError carries the TLS-gap detail")
	quit
