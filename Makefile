# uml4termux -- Makefile
#
# Requirements: GNU make + bash. Tested with GNU make 4.4.1 on
# aarch64-unknown-linux-android (Termux). No root, no GNU coreutils extras --
# only mkdir/cp/rm/tar/gzip/sed/tr, all present in a stock Termux install.
#
# The default goal is `help`.
#
# NOTE ON SCOPE: no target in this Makefile boots User-Mode Linux or starts a
# container. Booting is verified on an Android/Termux device and reported as
# evidence (see .github/workflows/device-evidence.yml); CI only ever packages,
# lints and unit-tests. See SECURITY.md for the threat model.

SHELL := $(shell command -v bash 2>/dev/null)
ifeq ($(SHELL),)
$(error bash is required: run 'pkg install bash')
endif
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
VERSION := $(shell tr -d ' \t\r\n' < "$(ROOT)/VERSION" 2>/dev/null)
ifeq ($(VERSION),)
VERSION := 0.0.0-unknown
endif
PKG := uml4termux-$(VERSION)

# PREFIX is imported from the environment when set. On Termux, `pkg`/`bash`
# already export PREFIX=/data/data/com.termux/files/usr, which is what we want;
# everywhere else it defaults to the usual /usr/local.
PREFIX ?= /usr/local
DESTDIR ?=

LIBDIR  := $(DESTDIR)$(PREFIX)/lib/uml4termux
BINDIR  := $(DESTDIR)$(PREFIX)/bin
CLI     := bin/uml4termux
DIST_DIR ?= dist

# Source trees copied into the installed libdir (only those that exist).
INSTALL_DIRS := bin lib scripts ci packaging docs tests
INSTALL_FILES := VERSION CHANGELOG.md CONTRIBUTING.md SECURITY.md Makefile README.md

.PHONY: help version ci self-test test dist clean install uninstall evidence \
        evidence-check yaml-check lint print-version

# ---------------------------------------------------------------------------
help: ## Show this help, the version and the exact commands CI runs
	@printf 'uml4termux %s\n' '$(VERSION)'
	@printf '  repo:    %s\n' '$(ROOT)'
	@printf '  host:    %s (%s)\n' "$$(uname -s)" "$$(uname -m)"
	@printf '  prefix:  %s\n' '$(PREFIX)'
	@printf '\nTargets:\n'
	@printf '  %-16s %s\n' 'help'            'this message (default goal)'
	@printf '  %-16s %s\n' 'version'         'print VERSION, git describe and the kernel target'
	@printf '  %-16s %s\n' 'ci'              'run ci/local-ci.sh (every check this device can run)'
	@printf '  %-16s %s\n' 'self-test'       'run tests/ci-checks.sh (repo metadata + helper tests)'
	@printf '  %-16s %s\n' 'dist'            'build dist/$(PKG).tar.gz + dist/SHA256SUMS'
	@printf '  %-16s %s\n' 'evidence'        'validate every record in evidence/ against the schema'
	@printf '  %-16s %s\n' 'evidence-check'  'alias for evidence'
	@printf '  %-16s %s\n' 'yaml-check'      'parse .github/workflows/*.yml'
	@printf '  %-16s %s\n' 'lint'            'bash -n + shellcheck (when installed) on all shell files'
	@printf '  %-16s %s\n' 'install'         'install into $(PREFIX) (honours DESTDIR)'
	@printf '  %-16s %s\n' 'uninstall'       'remove what install created'
	@printf '  %-16s %s\n' 'clean'           'remove dist/, build/, tmp/ and __pycache__/'
	@printf '\nExit codes used by the CI scripts: 0 pass, 1 fail, 77 skip.\n'
	@printf 'No target here boots UML: GitHub runners and this Makefile never do.\n'

# ---------------------------------------------------------------------------
version: ## Print the version and the kernel target
	@printf 'uml4termux %s\n' '$(VERSION)'
	@printf 'kernel target: linux-um arm64 (SUBARCH=arm64, downstream userspace port)\n'
	@printf 'no root, no KVM, no tap device; networking via gvproxy + UML BESS\n'
	@if command -v git >/dev/null 2>&1 && [ -d "$(ROOT)/.git" ]; then \
		printf 'git describe: %s\n' "$$(git -C '$(ROOT)' describe --tags --dirty --always 2>/dev/null || echo '(no tags)')"; \
		printf 'git commit:   %s\n' "$$(git -C '$(ROOT)' rev-parse --short HEAD 2>/dev/null || echo '(none)')"; \
	else \
		printf 'git: not a repository (VERSION file only)\n'; \
	fi

print-version:
	@printf '%s\n' '$(VERSION)'

# ---------------------------------------------------------------------------
ci: ## Run every CI check that is possible on this device
	@bash "$(ROOT)/ci/local-ci.sh"

self-test test: ## Repo metadata consistency + helper unit tests
	@bash "$(ROOT)/tests/ci-checks.sh"

# ---------------------------------------------------------------------------
dist: ## Build the release tarball and SHA256SUMS
	@bash "$(ROOT)/ci/make-dist.sh" --outdir "$(ROOT)/$(DIST_DIR)"
	@printf 'dist ready: %s/%s.tar.gz + %s/SHA256SUMS\n' '$(DIST_DIR)' '$(PKG)' '$(DIST_DIR)'

clean: ## Remove build outputs
	@rm -rf "$(ROOT)/$(DIST_DIR)" "$(ROOT)/build" "$(ROOT)/tmp" "$(ROOT)/.uml"
	@find "$(ROOT)" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	@find "$(ROOT)" -type f -name '*.pyc' -delete 2>/dev/null || true
	@printf 'clean: removed dist/ build/ tmp/ .uml/ __pycache__/\n'

# ---------------------------------------------------------------------------
evidence evidence-check: ## Validate evidence/ records against evidence/schema.json
	@bash -c 'set +e; \
		python3 "$${PYTHON_CMD:-python3}" "$(ROOT)/ci/check-evidence.py" --schema "$(ROOT)/evidence/schema.json" "$$@"; \
		rc=$$?; \
		case "$$rc" in \
			0)  echo "evidence: PASS";; \
			77) echo "evidence: SKIP (no records in evidence/ yet -- see evidence/README.md)";; \
			*)  echo "evidence: FAIL (exit $$rc)";; \
		esac; \
		exit $$rc' _ 
	@if [ -x "$(ROOT)/$(CLI)" ]; then \
		printf '\nTo record a new device run:\n  %s evidence --output evidence/$(VERSION)-$$(date -u +%%Y%%m%%dT%%H%%M%%SZ).json\n' "$(CLI)"; \
	else \
		printf '\nbin/uml4termux is not present yet; write evidence/<run-id>.json by hand\nand validate it with: make evidence-check\n'; \
	fi

yaml-check: ## Parse every workflow file
	@set -e; \
	files=$$(find "$(ROOT)/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort); \
	if [ -z "$$files" ]; then echo "yaml-check: SKIP no workflow files"; exit 77; fi; \
	env -u LD_LIBRARY_PATH python3 "$(ROOT)/ci/yamlcheck.py" --mode auto --workflow $$files

lint: ## bash -n + shellcheck on every shell file
	@set -e; \
	files=$$(bash "$(ROOT)/ci/list-shell-files.sh" "$(ROOT)"); \
	if [ -z "$$files" ]; then echo "lint: SKIP no shell files"; exit 0; fi; \
	for f in $$files; do bash -n "$$f"; done; \
	echo "bash -n: OK ($$(printf '%s\n' "$$files" | wc -l | tr -d ' ') files)"; \
	if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck --shell=bash --severity=warning \
			--exclude=SC1090,SC1091,SC2016,SC2034,SC2154,SC2317,SC2329 $$files; \
		echo "shellcheck: OK"; \
	else \
		echo "lint: SKIP shellcheck is not installed (bash -n only)"; \
	fi

# ---------------------------------------------------------------------------
install: ## Install into $(PREFIX); honours DESTDIR
	@if [ ! -e "$(ROOT)/$(CLI)" ]; then \
		printf 'install: FAIL -- %s does not exist yet.\n' '$(CLI)' >&2; \
		printf 'Nothing to install: the CLI is owned by another workstream of this repo.\n' >&2; \
		exit 1; \
	fi
	@printf 'install: %s -> %s\n' '$(LIBDIR)' '$(VERSION)'
	@mkdir -p "$(LIBDIR)" "$(BINDIR)"
	@tar -chf - \
		$(foreach d,$(INSTALL_DIRS),$(if $(wildcard $(ROOT)/$(d)),-C "$(ROOT)" $(d),)) \
		$(foreach f,$(INSTALL_FILES),$(if $(wildcard $(ROOT)/$(f)),-C "$(ROOT)" $(f),)) \
		| tar -xf - -C "$(LIBDIR)"
	@ln -sf "$(LIBDIR)/$(CLI)" "$(BINDIR)/uml4termux"
	@chmod +x "$(LIBDIR)/$(CLI)" 2>/dev/null || true
	@printf 'install: linked %s/uml4termux\n' '$(BINDIR)'
	@printf 'install: done. Run: uml4termux --help\n'
	@if [ -x "$(BINDIR)/uml4termux" ]; then "$(BINDIR)/uml4termux" --version 2>/dev/null || true; fi

uninstall: ## Remove what install created
	@rm -f "$(BINDIR)/uml4termux"
	@rm -rf "$(LIBDIR)"
	@printf 'uninstall: removed %s and %s/uml4termux\n' '$(LIBDIR)' '$(BINDIR)'