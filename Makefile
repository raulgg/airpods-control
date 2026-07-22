PREFIX ?= /usr/local
DESTDIR ?=
BUILD_DIR ?= build
DEPLOYMENT_TARGET ?= 12.0
ARCHS ?= arm64 x86_64

SWIFTC ?= swiftc
CLANG ?= clang
LIPO ?= lipo
CODESIGN ?= codesign
INSTALL ?= install

BINARY := $(BUILD_DIR)/airpods
DYLIB := $(BUILD_DIR)/avbypass.dylib
BUILD_STAMP := $(BUILD_DIR)/.built
LIBEXEC_DIR := $(DESTDIR)$(PREFIX)/libexec/airpods-control
BIN_DIR := $(DESTDIR)$(PREFIX)/bin

.PHONY: all _build install uninstall clean

all: $(BUILD_STAMP)
	@if [ ! -f "$(BINARY)" ] || [ ! -f "$(DYLIB)" ]; then \
		$(MAKE) --no-print-directory _build; \
	fi

$(BUILD_STAMP): native/main.swift native/bypass.c Makefile
	@$(MAKE) --no-print-directory _build

_build:
	@set -eu; \
	mkdir -p "$(BUILD_DIR)"; \
	tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/airpods-control.XXXXXX"); \
	trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	host_arch=$$(uname -m); \
	build_arch() { \
		arch="$$1"; \
		"$(CLANG)" -O2 -arch "$$arch" \
			-mmacosx-version-min="$(DEPLOYMENT_TARGET)" -dynamiclib \
			-o "$$tmp/avbypass.$$arch.dylib" native/bypass.c \
			-framework CoreFoundation -framework Security && \
		"$(SWIFTC)" -O -target "$$arch-apple-macosx$(DEPLOYMENT_TARGET)" \
			-o "$$tmp/airpods.$$arch" native/main.swift; \
	}; \
	succeeded=""; failed=""; \
	for arch in $(ARCHS); do \
		if build_arch "$$arch" >"$$tmp/build.$$arch.log" 2>&1; then \
			succeeded="$$succeeded $$arch"; \
		else \
			failed="$$failed $$arch"; \
			echo "warning: $$arch slice failed to build:" >&2; \
			sed 's/^/  /' "$$tmp/build.$$arch.log" | head -5 >&2; \
		fi; \
	done; \
	if [ -n "$$failed" ]; then \
		case " $$succeeded " in \
			*" $$host_arch "*) ;; \
			*) \
				echo "error: host architecture $$host_arch did not build" >&2; \
				exit 1; \
				;; \
		esac; \
		selected="$$host_arch"; \
		echo "warning: falling back to host architecture $$host_arch" >&2; \
	else \
		selected="$$succeeded"; \
	fi; \
	binary_inputs=""; dylib_inputs=""; \
	for arch in $$selected; do \
		binary_inputs="$$binary_inputs $$tmp/airpods.$$arch"; \
		dylib_inputs="$$dylib_inputs $$tmp/avbypass.$$arch.dylib"; \
	done; \
	"$(LIPO)" -create $$binary_inputs -output "$$tmp/airpods"; \
	"$(LIPO)" -create $$dylib_inputs -output "$$tmp/avbypass.dylib"; \
	"$(CODESIGN)" --force --sign - "$$tmp/avbypass.dylib"; \
	"$(CODESIGN)" --force --sign - "$$tmp/airpods"; \
	mv "$$tmp/airpods" "$(BINARY)"; \
	mv "$$tmp/avbypass.dylib" "$(DYLIB)"; \
	touch "$(BUILD_STAMP)"; \
	echo "built: $(BINARY) ($$("$(LIPO)" -archs "$(BINARY)")) + avbypass.dylib"

install: all
	"$(INSTALL)" -d "$(LIBEXEC_DIR)" "$(BIN_DIR)"
	"$(INSTALL)" -m 755 "$(BINARY)" "$(LIBEXEC_DIR)/airpods"
	"$(INSTALL)" -m 755 "$(DYLIB)" "$(LIBEXEC_DIR)/avbypass.dylib"
	ln -sfn ../libexec/airpods-control/airpods "$(BIN_DIR)/airpods"

uninstall:
	rm -f "$(BIN_DIR)/airpods"
	rm -f "$(LIBEXEC_DIR)/airpods" "$(LIBEXEC_DIR)/avbypass.dylib"
	-rmdir "$(LIBEXEC_DIR)"

clean:
	@test -n "$(BUILD_DIR)" && test "$(BUILD_DIR)" != "/"
	rm -rf "$(BUILD_DIR)"
