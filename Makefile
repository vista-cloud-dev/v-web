# v-web — VistA Web Services (VWEB* routines). Layer: v (VistA-specific;
# consumes the engine-neutral STD* HTTP/socket base and the VSL* VistA base
# upward, per the m/v waterline).
#
# The `m` toolchain binary is built in the sibling m-cli repo; override M if
# your checkout lives elsewhere or `m` is on PATH (M=m).
M       ?= $(HOME)/vista-cloud-dev/m-cli/dist/m
SRC     := src
TESTS   := tests
# m-stdlib — STDHTTPD/STDHTTPMSG/STDNET (the portable HTTP/socket base) plus
# STDASSERT/STDHARN for engine-bound tests. Pinned at MSL v0.12.0 (STDNET-IRIS).
MSTDLIB ?= $(HOME)/vista-cloud-dev/m-stdlib
# v-stdlib — VSLTASK (TaskMan listener seam) + VSLCFG (XPAR config) + VSLENV
# (env-check) that VWEB* binds. Staged alongside src/ for test resolution.
VSTDLIB ?= $(HOME)/vista-cloud-dev/v-stdlib
# v-pkg — the host tool that builds the VWEB KIDS distribution from
# kids/vweb.build.json. Defaults to the sibling checkout's standalone binary;
# override with `make kids VPKG=/path/to/v-pkg`.
VPKG ?= $(HOME)/vista-cloud-dev/v-pkg/dist/v-pkg

# Engine selection for the engine-bound targets (test/coverage):
#   make test ENGINE=ydb  DOCKER=m-test-engine
#   make test ENGINE=iris DOCKER=m-test-iris
# CHSET — the engine character set. YottaDB MUST run in byte (M) mode: VWEBA's
# JWT/HMAC signing (STDCRYPTO) and the STDHTTPMSG byte framing are byte-oriented,
# so under UTF-8 the auth suite aborts. Default to byte mode for YDB; IRIS ignores
# it (always byte-safe). Mirrors m-stdlib's M_ENGINE_FLAGS byte-mode default.
#   make test ENGINE=ydb  DOCKER=m-test-engine            (CHSET defaults to m)
#   make test ENGINE=iris DOCKER=m-test-iris  CHSET=      (IRIS: no chset flag)
ENGINE ?=
DOCKER ?=
CHSET  ?= $(if $(filter ydb,$(ENGINE)),m)
ENGINE_FLAGS := $(if $(ENGINE),--engine $(ENGINE)) $(if $(DOCKER),--docker $(DOCKER)) $(if $(CHSET),--chset $(CHSET))

.PHONY: all check check-fast fmt fmt-check lint arch test coverage clean \
        seams check-seams icr check-icr check-citations namespaces check-namespaces \
        pin check-msl-pin check-engine-access kids check-kids gates

all: check

# fmt style is driven by .m-cli.toml ([fmt] rules = "pythonic-lower").
fmt:
	$(M) fmt --write $(SRC) $(TESTS)

fmt-check:
	$(M) fmt --check $(SRC) $(TESTS)

lint:
	$(M) lint --check $(SRC) $(TESTS)

# m/v waterline gates. v-web is layer v (root repo.meta.json); it passes
# G1/G2 trivially (v -> m, and VistA above the line, are allowed) but must
# declare its layer so the gates run everywhere with no exception.
arch:
	$(M) arch check .

# Engine-bound: stage the m-stdlib base (STDHTTPD/STDHTTPMSG/STDNET + STDASSERT)
# and the v-stdlib base (VSLTASK/VSLCFG/VSLENV) so VWEB*TST suites resolve their
# seams. Pass --engine ydb|iris and --docker <container>.
test:
	$(M) test $(ENGINE_FLAGS) --routines $(SRC) --routines $(MSTDLIB)/src --routines $(VSTDLIB)/src $(TESTS)

coverage:
	$(M) coverage $(ENGINE_FLAGS) --routines $(MSTDLIB)/src --routines $(VSTDLIB)/src --min-percent=85 $(SRC) $(TESTS)

# ── The four registry-driven drift gates (source-tag -> generate -> registry
# -> red-gate), the same discipline m-stdlib and v-stdlib carry:
#   seams      — @seam → dist/seam-snapshot.json + git-HEAD bump-forcer
#   icr        — @icr  → dist/icr-registry.json + DBIA/no-direct-global gate
#   citations  — @source cited doc_keys vs the vdocs gold corpus (SKIP if absent)
#   namespaces — repo.meta.json prefixes vs discovered VWEB* routines/globals
seams:
	python3 tools/seam_contract.py --write

check-seams:
	@python3 tools/seam_contract.py --check

icr:
	python3 tools/gen-icr.py --write

check-icr:
	@python3 tools/gen-icr.py --check

check-citations:
	@python3 tools/check_citations.py --check

namespaces:
	python3 tools/gen_namespace_registry.py --write

check-namespaces:
	@python3 tools/gen_namespace_registry.py --check

# ── The cross-repo MSL seam-contract pin (v -> m). v-web pins the frozen MSL
# seam contract it built against (a git tag in m-stdlib) and asserts no drift.
pin:
	python3 tools/msl_seam_pin.py --write

check-msl-pin:
	@python3 tools/msl_seam_pin.py --check

# Transport-monopoly gate: no committed test/script/Makefile may hand-roll engine
# access. All engine work goes through the m-driver-sdk -> m-ydb/m-iris stack.
check-engine-access:
	@python3 tools/check_engine_access.py --check

# ── The VWEB KIDS build (drift-gated artifact). kids/vweb.build.json declares
# the VWEB* routines + XPAR param defs + the startup option, and the MSL + VSL
# base builds as KIDS Required Builds (never bundled). `make kids` builds the
# deterministic .KID via v-pkg; `make check-kids` re-gates it (a fresh rebuild
# must be byte-identical AND match the committed dist/kids/VWEB.kids). Engine-
# free — needs only v-pkg. SKIP-green when v-pkg is absent (CI without it stays
# green).
kids:
	$(VPKG) build kids/vweb.build.json --src $(SRC) --out dist/kids/VWEB.kids

check-kids:
	@if [ ! -x "$(VPKG)" ]; then \
	  echo "check-kids: v-pkg not found at $(VPKG) — SKIP (build it in v-pkg or set VPKG=…)"; \
	  exit 0; \
	fi
	@tmp=$$(mktemp); \
	$(VPKG) build kids/vweb.build.json --src $(SRC) --out $$tmp >/dev/null; \
	if diff -q $$tmp dist/kids/VWEB.kids >/dev/null 2>&1; then \
	  echo "check-kids: dist/kids/VWEB.kids matches a fresh deterministic build ✓"; \
	  rm -f $$tmp; \
	else \
	  echo "ERROR: dist/kids/VWEB.kids drifted from kids/vweb.build.json + src/ — run 'make kids' and commit" >&2; \
	  rm -f $$tmp; exit 1; \
	fi

# Aggregate of the engine-free drift gates.
gates: check-seams check-icr check-citations check-namespaces check-msl-pin check-engine-access check-kids

# Engine-free gates (fmt/lint/arch + drift gates) + the engine-bound suite. CI
# runs the full set; `make check-fast` needs no engine.
check: fmt-check lint arch gates test

check-fast: fmt-check lint arch gates

clean:
	rm -f test-results.tap *.lcov coverage.out
