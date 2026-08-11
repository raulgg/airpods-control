PREFIX ?= /usr/local
DESTDIR ?=
BUILD_DIR ?= build
DIST_DIR ?= dist
DEPLOYMENT_TARGET ?= 12.0
ARCHS ?= arm64 x86_64

SWIFTC ?= swiftc
CLANG ?= clang
LIPO ?= lipo
CODESIGN ?= codesign
INSTALL ?= install

BINARY := $(BUILD_DIR)/airpods-control
DYLIB := $(BUILD_DIR)/avbypass.dylib
MANPAGE := docs/man/airpods-control.1
BUILD_STAMP := $(BUILD_DIR)/.built
VERSION_FILE := version.txt
VERSION_SOURCE := $(BUILD_DIR)/Version.swift
SWIFT_SOURCES := $(sort $(wildcard Sources/AirPodsControl/*.swift))
SWIFT_BUILD_SOURCES := $(SWIFT_SOURCES) $(VERSION_SOURCE)
SWIFT_LIBRARY_SOURCES := $(filter-out Sources/AirPodsControl/main.swift,$(SWIFT_SOURCES))
SWIFT_TEST_SOURCES := $(sort $(wildcard Tests/AirPodsControlTests/*.swift))
AV_BYPASS_SOURCE := Sources/AVBypass/bypass.c
SIGNAL_MONITOR_SOURCE := Sources/SignalMonitor/signal_monitor.c
SIGNAL_MONITOR_INCLUDE_DIR := Sources/SignalMonitor/include
SIGNAL_MONITOR_HEADER := $(SIGNAL_MONITOR_INCLUDE_DIR)/SignalMonitor.h
SIGNAL_MONITOR_MODULE_MAP := $(SIGNAL_MONITOR_INCLUDE_DIR)/module.modulemap
BYPASS_PROBE_SOURCE := Sources/BypassProbe/bypass_probe.c
BYPASS_PROBE_INCLUDE_DIR := Sources/BypassProbe/include
BYPASS_PROBE_HEADER := $(BYPASS_PROBE_INCLUDE_DIR)/BypassProbe.h
BYPASS_PROBE_MODULE_MAP := $(BYPASS_PROBE_INCLUDE_DIR)/module.modulemap
SIGNAL_MONITOR_RACE_TEST_SOURCE := Tests/SignalMonitorTests/signal_monitor_race_test.c
SOURCE_DIRS := Sources/AirPodsControl Sources/AVBypass Sources/BypassProbe Sources/SignalMonitor
SWIFT_TEST_BINARY := $(BUILD_DIR)/swift-tests
SIGNAL_MONITOR_TEST_OBJECT := $(BUILD_DIR)/signal-monitor-tests.o
SIGNAL_MONITOR_RACE_TEST_BINARY := $(BUILD_DIR)/signal-monitor-race-tests
SWIFT_MODULE_CACHE := $(abspath $(BUILD_DIR)/module-cache)
LIBEXEC_DIR := $(DESTDIR)$(PREFIX)/libexec/airpods-control
BIN_DIR := $(DESTDIR)$(PREFIX)/bin
MAN_DIR := $(DESTDIR)$(PREFIX)/share/man/man1

.PHONY: all _build test verify-catalog package install uninstall clean

all: $(BUILD_STAMP)
	@if [ ! -f "$(BINARY)" ] || [ ! -f "$(DYLIB)" ]; then \
		$(MAKE) --no-print-directory _build; \
	fi

$(BUILD_STAMP): $(SOURCE_DIRS) $(SWIFT_SOURCES) $(VERSION_SOURCE) $(AV_BYPASS_SOURCE) \
	$(SIGNAL_MONITOR_SOURCE) $(SIGNAL_MONITOR_HEADER) \
	$(SIGNAL_MONITOR_MODULE_MAP) $(BYPASS_PROBE_SOURCE) \
	$(BYPASS_PROBE_HEADER) $(BYPASS_PROBE_MODULE_MAP) Makefile
	@$(MAKE) --no-print-directory _build

$(VERSION_SOURCE): $(VERSION_FILE) Makefile
	@set -eu; \
	version=$$(cat "$(VERSION_FILE)"); \
	printf '%s\n' "$$version" | grep -Eq \
		'^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$$' || { \
			echo "error: $(VERSION_FILE) must contain one semantic version" >&2; \
			exit 1; \
		}; \
	mkdir -p "$(BUILD_DIR)"; \
	printf 'let VERSION = "%s"\n' "$$version" >"$(VERSION_SOURCE)"

_build: $(VERSION_SOURCE)
	@set -eu; \
	mkdir -p "$(BUILD_DIR)" "$(SWIFT_MODULE_CACHE)"; \
	tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/airpods-control.XXXXXX"); \
	trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	host_arch=$$(uname -m); \
	build_arch() { \
		arch="$$1"; \
		"$(CLANG)" -O2 -arch "$$arch" \
			-mmacosx-version-min="$(DEPLOYMENT_TARGET)" -dynamiclib \
			-o "$$tmp/avbypass.$$arch.dylib" "$(AV_BYPASS_SOURCE)" \
			-framework CoreFoundation -framework Security && \
		"$(CLANG)" -O2 -arch "$$arch" \
			-mmacosx-version-min="$(DEPLOYMENT_TARGET)" -c \
			-I"$(SIGNAL_MONITOR_INCLUDE_DIR)" \
			-o "$$tmp/signal-monitor.$$arch.o" "$(SIGNAL_MONITOR_SOURCE)" && \
		"$(CLANG)" -O2 -arch "$$arch" \
			-mmacosx-version-min="$(DEPLOYMENT_TARGET)" -c \
			-I"$(BYPASS_PROBE_INCLUDE_DIR)" \
			-o "$$tmp/bypass-probe.$$arch.o" "$(BYPASS_PROBE_SOURCE)" && \
		"$(SWIFTC)" -O -target "$$arch-apple-macosx$(DEPLOYMENT_TARGET)" \
			-I"$(SIGNAL_MONITOR_INCLUDE_DIR)" -I"$(BYPASS_PROBE_INCLUDE_DIR)" \
			-module-cache-path "$(SWIFT_MODULE_CACHE)" \
			-o "$$tmp/airpods-control.$$arch" $(SWIFT_BUILD_SOURCES) \
			"$$tmp/signal-monitor.$$arch.o" "$$tmp/bypass-probe.$$arch.o" \
			-Xlinker -framework -Xlinker Security; \
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
		binary_inputs="$$binary_inputs $$tmp/airpods-control.$$arch"; \
		dylib_inputs="$$dylib_inputs $$tmp/avbypass.$$arch.dylib"; \
	done; \
	"$(LIPO)" -create $$binary_inputs -output "$$tmp/airpods-control"; \
	"$(LIPO)" -create $$dylib_inputs -output "$$tmp/avbypass.dylib"; \
	"$(CODESIGN)" --force --sign - "$$tmp/avbypass.dylib"; \
	"$(CODESIGN)" --force --sign - "$$tmp/airpods-control"; \
	mv "$$tmp/airpods-control" "$(BINARY)"; \
	mv "$$tmp/avbypass.dylib" "$(DYLIB)"; \
	touch "$(BUILD_STAMP)"; \
	echo "built: $(BINARY) ($$("$(LIPO)" -archs "$(BINARY)")) + avbypass.dylib"

test: all
	./Tests/CLIContractTests/cli.sh
	"$(CLANG)" -O2 -pthread -DAIRPODS_CONTROL_SIGNAL_MONITOR_TESTING \
		-I"$(SIGNAL_MONITOR_INCLUDE_DIR)" \
		-o "$(SIGNAL_MONITOR_RACE_TEST_BINARY)" \
		"$(SIGNAL_MONITOR_SOURCE)" "$(SIGNAL_MONITOR_RACE_TEST_SOURCE)"
	"$(SIGNAL_MONITOR_RACE_TEST_BINARY)"
	"$(CLANG)" -O0 -c \
		-I"$(SIGNAL_MONITOR_INCLUDE_DIR)" \
		-o "$(SIGNAL_MONITOR_TEST_OBJECT)" "$(SIGNAL_MONITOR_SOURCE)"
	"$(SWIFTC)" -Onone -parse-as-library \
		-I"$(SIGNAL_MONITOR_INCLUDE_DIR)" \
		-module-cache-path "$(SWIFT_MODULE_CACHE)" \
		-o "$(SWIFT_TEST_BINARY)" \
		$(SWIFT_LIBRARY_SOURCES) $(VERSION_SOURCE) $(SWIFT_TEST_SOURCES) \
		"$(SIGNAL_MONITOR_TEST_OBJECT)"
	"$(SWIFT_TEST_BINARY)"

# Deliberately outside `test`: the result depends on the macOS version of
# whoever runs it, so a stale system would fail the suite for no fault of the
# code. Run it when adding hardware or after a major system upgrade.
verify-catalog:
	./scripts/verify-catalog.sh

package: all
	BUILD_DIR="$(abspath $(BUILD_DIR))" \
		DIST_DIR="$(abspath $(DIST_DIR))" \
		VERSION_FILE="$(abspath $(VERSION_FILE))" \
		MAKE="$(MAKE)" \
		./scripts/package-binary.sh

install: all
	"$(INSTALL)" -d "$(LIBEXEC_DIR)" "$(BIN_DIR)" "$(MAN_DIR)"
	"$(INSTALL)" -m 755 "$(BINARY)" "$(LIBEXEC_DIR)/airpods-control"
	"$(INSTALL)" -m 755 "$(DYLIB)" "$(LIBEXEC_DIR)/avbypass.dylib"
	"$(INSTALL)" -m 644 "$(MANPAGE)" "$(MAN_DIR)/airpods-control.1"
	ln -sfn ../libexec/airpods-control/airpods-control "$(BIN_DIR)/airpods-control"

uninstall:
	rm -f "$(BIN_DIR)/airpods-control"
	rm -f "$(LIBEXEC_DIR)/airpods-control" "$(LIBEXEC_DIR)/avbypass.dylib"
	rm -f "$(MAN_DIR)/airpods-control.1"
	-rmdir "$(LIBEXEC_DIR)"

clean:
	@test -n "$(BUILD_DIR)" && test "$(BUILD_DIR)" != "/"
	rm -rf "$(BUILD_DIR)"
