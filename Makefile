VERSION := $(shell grep 'static let version' Sources/transcribe/main.swift | sed 's/.*"\(.*\)".*/\1/')
PREFIX  ?= $(HOME)
BINDIR  ?= $(PREFIX)/bin

.PHONY: build test install tag release changelog

build:
	swift build -c release

test:
	swift test

# Install the release binary to $(BINDIR) (default: $HOME/bin).
# Override with: make install BINDIR=/usr/local/bin
install: build
	@mkdir -p "$(BINDIR)"
	install -m 0755 .build/release/transcribe "$(BINDIR)/transcribe"
	@echo "Installed transcribe $(VERSION) to $(BINDIR)/transcribe"

# Create annotated git tag from the version in main.swift
tag:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "Error: working tree is not clean"; exit 1; \
	fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "Error: tag v$(VERSION) already exists"; exit 1; \
	fi
	git tag -a "v$(VERSION)" -m "Release $(VERSION)"
	@echo "Tagged v$(VERSION)"

# Build release binary and create tag
release: build tag
	@echo "Release $(VERSION) complete"

# Generate changelog since the previous tag
changelog:
	@PREV=$$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo ""); \
	if [ -z "$$PREV" ]; then \
		echo "# Changelog for v$(VERSION)"; \
		echo ""; \
		git log --oneline --no-decorate; \
	else \
		echo "# Changelog: $$PREV -> v$(VERSION)"; \
		echo ""; \
		git log --oneline --no-decorate "$$PREV..HEAD"; \
	fi
