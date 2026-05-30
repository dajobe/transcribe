VERSION := $(shell grep 'static let version' Sources/transcribe/main.swift | sed 's/.*"\(.*\)".*/\1/')
VERSION_COMMIT := $(shell git log -G 'static let version' -n 1 --format=%H -- Sources/transcribe/main.swift)
PREFIX  ?= $(HOME)
BINDIR  ?= $(PREFIX)/bin
TRANSCRIBE_BINARY ?= .build/debug/transcribe
AUDIO_FORMAT_FIXTURE_DIR ?= Tests/transcribeTests/Fixtures/AudioFormats
AUDIO_FORMAT_SMOKE_EXTENSIONS ?= $(shell sed -n 's/.*static let audioFormatExtensions = \[\(.*\)\].*/\1/p' Sources/transcribe/AudioLoader.swift | tr -d '",')
AUDIO_FORMAT_SMOKE_MODEL ?= openai_whisper-base
AUDIO_FORMAT_SMOKE_MODEL_DIR ?= $(HOME)/.cache/transcribe
DIRECTORY_SMOKE_OUTPUT_PREFIX ?= audio-format-dir

.PHONY: build test test-audio-formats test-directory-smoke smoke-audio-formats install tag verify-tag release changelog

build:
	swift build -c release

test:
	swift test

test-audio-formats:
	swift build
	@set -e; \
	for ext in $(AUDIO_FORMAT_SMOKE_EXTENSIONS); do \
		fixture="$(AUDIO_FORMAT_FIXTURE_DIR)/smoke.$$ext"; \
		outdir="$$(mktemp -d "$${TMPDIR:-/tmp}/transcribe-audio-smoke.XXXXXX")"; \
		printf 'Audio format smoke: %s\n' "$$fixture"; \
		"$(TRANSCRIBE_BINARY)" \
			--quiet \
			--model "$(AUDIO_FORMAT_SMOKE_MODEL)" \
			--model-dir "$(AUDIO_FORMAT_SMOKE_MODEL_DIR)" \
			--transcript-only \
			--format txt \
			-o "$$outdir" \
			--stateless \
			--eta-hints off \
			--progress-log off \
			--audio-encoder-compute cpuOnly \
			--text-decoder-compute cpuOnly \
			file "$$fixture" >/dev/null; \
		test -s "$$outdir/smoke.txt"; \
		rm -rf "$$outdir"; \
	done

test-directory-smoke:
	swift build
	@set -e; \
	fixture_dir="$(AUDIO_FORMAT_FIXTURE_DIR)"; \
	outdir="$$(mktemp -d "$${TMPDIR:-/tmp}/transcribe-dir-smoke.XXXXXX")"; \
	log="$$(mktemp "$${TMPDIR:-/tmp}/transcribe-dir-smoke.log.XXXXXX")"; \
	err="$$(mktemp "$${TMPDIR:-/tmp}/transcribe-dir-smoke.err.XXXXXX")"; \
	printf 'Directory smoke: %s\n' "$$fixture_dir"; \
	"$(TRANSCRIBE_BINARY)" \
		--quiet \
		--model "$(AUDIO_FORMAT_SMOKE_MODEL)" \
		--model-dir "$(AUDIO_FORMAT_SMOKE_MODEL_DIR)" \
		--transcript-only \
		--format txt,json \
		--output-prefix "$(DIRECTORY_SMOKE_OUTPUT_PREFIX)" \
		-o "$$outdir" \
		--stateless \
		--eta-hints off \
		--progress-log plain \
		--audio-encoder-compute cpuOnly \
		--text-decoder-compute cpuOnly \
		dir --sort name "$$fixture_dir" >"$$log" 2>"$$err"; \
	if test -s "$$err"; then \
		printf 'Unexpected stderr from directory smoke:\n' >&2; \
		cat "$$err" >&2; \
		exit 1; \
	fi; \
	test -f "$$outdir/$(DIRECTORY_SMOKE_OUTPUT_PREFIX).txt"; \
	test -s "$$outdir/$(DIRECTORY_SMOKE_OUTPUT_PREFIX).json"; \
	grep -F '"audio_files"' "$$outdir/$(DIRECTORY_SMOKE_OUTPUT_PREFIX).json" >/dev/null; \
	grep -F 'event=session_start' "$$log" >/dev/null; \
	grep -F 'source=directory_session' "$$log" >/dev/null; \
	grep -F 'session=1/1' "$$log" >/dev/null; \
	grep -F 'output_basename=$(DIRECTORY_SMOKE_OUTPUT_PREFIX)' "$$log" >/dev/null; \
	grep -F 'outputs="$(DIRECTORY_SMOKE_OUTPUT_PREFIX).txt,$(DIRECTORY_SMOKE_OUTPUT_PREFIX).json"' "$$log" >/dev/null; \
	for ext in $(AUDIO_FORMAT_SMOKE_EXTENSIONS); do \
		grep -F "smoke.$$ext" "$$log" >/dev/null; \
		grep -F "smoke.$$ext" "$$outdir/$(DIRECTORY_SMOKE_OUTPUT_PREFIX).json" >/dev/null; \
	done; \
	grep -F 'event=phase_done' "$$log" | grep -F 'phase=model_loading' >/dev/null; \
	grep -F 'event=phase_done' "$$log" | grep -F 'phase=audio' >/dev/null; \
	grep -F 'event=phase_done' "$$log" | grep -F 'phase=output' >/dev/null; \
	grep -F 'event=session_done' "$$log" >/dev/null; \
	grep -F 'event=run_done' "$$log" >/dev/null; \
	if grep -F 'Total:' "$$log" >/dev/null; then \
		printf 'Plain directory smoke log unexpectedly contained TUI output:\n' >&2; \
		cat "$$log" >&2; \
		exit 1; \
	fi; \
	rm -rf "$$outdir"; \
	rm -f "$$log" "$$err"

smoke-audio-formats: test-audio-formats test-directory-smoke

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
