# Domovyk: install from source.
#
#   make install PREFIX=$HOME/.local     # for you only, no sudo
#   sudo make install                    # for everyone, into /usr/local
#   make uninstall PREFIX=...            # removes exactly what install put there
#   make lint                            # shellcheck (safe to run anywhere)
#   make test                            # lint, then unit tests in a throwaway VM
#
# The layout matches the Debian package: $(PREFIX)/bin/domovyk,
# $(PREFIX)/libexec/domovyk/ and $(PREFIX)/share/domovyk/. bin/domovyk finds
# the rest of the tree from its own location, so nothing is configured.

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR := $(DESTDIR)$(PREFIX)/bin
LIBEXECDIR := $(DESTDIR)$(PREFIX)/libexec/domovyk
SHAREDIR := $(DESTDIR)$(PREFIX)/share/domovyk

.PHONY: all install uninstall lint test help

all: help

help:
	@sed -n '2,10s/^# \{0,1\}//p' Makefile

install:
	install -d "$(BINDIR)" "$(LIBEXECDIR)" "$(SHAREDIR)"
	install -m 0755 bin/domovyk "$(BINDIR)/domovyk"
	cp -R libexec/. "$(LIBEXECDIR)/"
	cp -R share/. "$(SHAREDIR)/"
	find "$(LIBEXECDIR)" "$(SHAREDIR)" -name '__pycache__' -prune -exec rm -rf {} +
	@echo "installed: $(BINDIR)/domovyk"
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) echo "note: add $(PREFIX)/bin to your PATH";; esac

uninstall:
	rm -f "$(BINDIR)/domovyk"
	rm -rf "$(LIBEXECDIR)" "$(SHAREDIR)"
	@echo "removed domovyk from $(DESTDIR)$(PREFIX)"

lint:
	shellcheck -x -P SCRIPTDIR bin/domovyk libexec/lib/*.sh libexec/commands/* libexec/hooks/* tools/capture-fixtures

test:
	test/run-all
