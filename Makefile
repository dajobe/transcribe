VERSION := $(shell grep 'static let version' Sources/transcribe/main.swift | sed 's/.*"\(.*\)".*/\1/')
VERSION_COMMIT := $(shell git log -G 'static let version' -n 1 --format=%H -- Sources/transcribe/main.swift)
PREFIX  ?= $(HOME)
BINDIR  ?= $(PREFIX)/bin
TRANSCRIBE_BINARY ?= .build/debug/transcribe
AUDIO_FORMAT_FIXTURE_DIR ?= Tests/transcribeTests/Fixtures/AudioFormats
AUDIO_FORMAT_SMOKE_EXTENSIONS ?= wav mp3 m4a flac aiff caf aac
AUDIO_FORMAT_SMOKE_MODEL ?= openai_whisper-base
AUDIO_FORMAT_SMOKE_MODEL_DIR ?= $(HOME)/.cache/transcribe

.PHONY: build test test-audio-formats smoke-audio-formats install tag verify-tag release changelog

build:
	swift build -c release

test:
	swift test

test-audio-formats:
	swift build
	@set -e; \
	for ext in $(AUDIO_FORMAT_SMOKE_EXTENSIONS); do \
		fixture="$(AUDIO_FORMAT_FIXTURE_DIR)/smoke.$$ext"; \
		printf 'Audio format smoke: %s\n' "$$fixture"; \
		"$(TRANSCRIBE_BINARY)" \
			--quiet \
			--model "$(AUDIO_FORMAT_SMOKE_MODEL)" \
			--model-dir "$(AUDIO_FORMAT_SMOKE_MODEL_DIR)" \
			--transcript-only \
			--stdout \
			--format txt \
			--stateless \
			--eta-hints off \
			--progress-log off \
			--audio-encoder-compute cpuOnly \
			--text-decoder-compute cpuOnly \
			file "$$fixture" >/dev/null; \
	done

smoke-audio-formats: test-audio-formats

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
	@if [ "$$(git rev-parse HEAD)" != "$(VERSION_COMMIT)" ]; then \
		echo "Error: version $(VERSION) was last changed at $(VERSION_COMMIT), not HEAD."; \
		echo "       Check out that commit before tagging, or bump the version on HEAD."; \
		exit 1; \
	fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "Error: tag v$(VERSION) already exists"; exit 1; \
	fi
	git tag -a "v$(VERSION)" -m "Release $(VERSION)"
	@echo "Tagged v$(VERSION)"

# Build release binary and create tag
release: build tag
	@echo "Release $(VERSION) complete"

# Fail loudly when the version in main.swift has no matching annotated tag on
# the commit that last changed `static let version`.
# Run before pushing to catch a bumped version that was committed without a
# corresponding `make tag`, or a tag created on the wrong commit.
verify-tag:
	@if ! git rev-parse --verify --quiet "v$(VERSION)" >/dev/null; then \
		echo "Error: version is $(VERSION) but tag v$(VERSION) is missing." >&2; \
		echo "       Run 'make tag' (or 'make release') to create it." >&2; \
		exit 1; \
	fi
	@if [ "$$(git cat-file -t "v$(VERSION)")" != "tag" ]; then \
		echo "Error: v$(VERSION) exists but is not an annotated tag." >&2; \
		echo "       Recreate it with 'git tag -a v$(VERSION) -m \"Release $(VERSION)\" $(VERSION_COMMIT)'." >&2; \
		exit 1; \
	fi
	@if [ "$$(git rev-list -n 1 "v$(VERSION)")" != "$(VERSION_COMMIT)" ]; then \
		echo "Error: v$(VERSION) does not point to the version-bump commit $(VERSION_COMMIT)." >&2; \
		echo "       Tags must land on the same commit that changes static let version." >&2; \
		exit 1; \
	fi
	@echo "OK: v$(VERSION) annotated tag points to $(VERSION_COMMIT)"

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
