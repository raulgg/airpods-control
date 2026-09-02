PREFIX ?= /usr/local
DESTDIR ?=
BUILD_DIR ?= build
DEPLOYMENT_TARGET ?= 12.0
ARCHS ?= arm64 x86_64

SWIFTC ?= swiftc
SWIFT_TOOLCHAIN_DRIVER := $(shell xcrun --find swift)
SWIFT ?= $(SWIFT_TOOLCHAIN_DRIVER)
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
SWIFT_PACKAGE_SCRATCH := $(BUILD_DIR)/swiftpm
SWIFT_PACKAGE_CACHE := $(BUILD_DIR)/swiftpm-cache
SWIFT_PACKAGE_CONFIG := $(BUILD_DIR)/swiftpm-config
SWIFT_PACKAGE_SECURITY := $(BUILD_DIR)/swiftpm-security
SWIFT_PACKAGE_MODULE_CACHE := $(abspath $(SWIFT_PACKAGE_SCRATCH)/module-cache)
SWIFT_DEVELOPER_DIR := $(patsubst %/usr/bin/swift,%,$(SWIFT_TOOLCHAIN_DRIVER))
SWIFT_TESTING_FRAMEWORKS := $(SWIFT_DEVELOPER_DIR)/Library/Developer/Frameworks
SWIFT_TESTING_INTEROP := $(SWIFT_DEVELOPER_DIR)/Library/Developer/usr/lib
# CLT installations need these fallback paths. SwiftPM supplies Xcode's paths.
SWIFT_TESTING_FLAGS :=
ifneq ($(shell test -d "$(SWIFT_TESTING_FRAMEWORKS)" && echo yes),)
SWIFT_TESTING_FLAGS += \
	-Xswiftc -F -Xswiftc "$(SWIFT_TESTING_FRAMEWORKS)" \
	-Xlinker -rpath -Xlinker "$(SWIFT_TESTING_FRAMEWORKS)"
endif
ifneq ($(shell test -d "$(SWIFT_TESTING_INTEROP)" && echo yes),)
SWIFT_TESTING_FLAGS += -Xlinker -rpath -Xlinker "$(SWIFT_TESTING_INTEROP)"
endif
SWIFT_PACKAGE_EXTRA_FLAGS ?=
SIGNAL_MONITOR_RACE_TEST_BINARY := $(BUILD_DIR)/signal-monitor-race-tests
SWIFT_MODULE_CACHE := $(abspath $(BUILD_DIR)/module-cache)
LIBEXEC_DIR := $(DESTDIR)$(PREFIX)/libexec/airpods-control
BIN_DIR := $(DESTDIR)$(PREFIX)/bin
MAN_DIR := $(DESTDIR)$(PREFIX)/share/man/man1

.PHONY: all _build test verify-catalog verify-runtime install uninstall clean

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
	./Tests/ReleasePleaseTests/release-pr-body.sh
	./Tests/ResolvePrefixTests/resolve-prefix.sh
	./Tests/InstallFromSourceTests/install-from-source.sh
	./Tests/CLIContractTests/cli.sh
	"$(CLANG)" -O2 -pthread -DAIRPODS_CONTROL_SIGNAL_MONITOR_TESTING \
		-I"$(SIGNAL_MONITOR_INCLUDE_DIR)" \
		-o "$(SIGNAL_MONITOR_RACE_TEST_BINARY)" \
		"$(SIGNAL_MONITOR_SOURCE)" "$(SIGNAL_MONITOR_RACE_TEST_SOURCE)"
	"$(SIGNAL_MONITOR_RACE_TEST_BINARY)"
	CLANG_MODULE_CACHE_PATH="$(SWIFT_PACKAGE_MODULE_CACHE)" \
	SWIFTPM_MODULECACHE_OVERRIDE="$(SWIFT_PACKAGE_MODULE_CACHE)" \
	"$(SWIFT)" test --scratch-path "$(SWIFT_PACKAGE_SCRATCH)" \
		--cache-path "$(SWIFT_PACKAGE_CACHE)" \
		--config-path "$(SWIFT_PACKAGE_CONFIG)" \
		--security-path "$(SWIFT_PACKAGE_SECURITY)" \
		$(SWIFT_PACKAGE_EXTRA_FLAGS) \
		--enable-swift-testing --no-parallel $(SWIFT_TESTING_FLAGS)

# Deliberately outside `test`: the result depends on the macOS version of
# whoever runs it, so a stale system would fail the suite for no fault of the
# code. Run it when adding hardware or after a major system upgrade.
verify-catalog:
	./scripts/verify-catalog.sh

# Deliberately outside `test`: the check launches the CLI and requires the
# interpose to report active, so a future macOS change would fail the suite
# for no fault of the code under edit.
verify-runtime: all
	./Tests/VerifyRuntimeTests/verify-runtime.sh \
		"$(abspath $(BINARY))" "$(abspath $(DYLIB))"

install: all
	@set -eu; \
	command_path="$(BIN_DIR)/airpods-control"; \
	expected_target=../libexec/airpods-control/airpods-control; \
	if [ -e "$$command_path" ] || [ -L "$$command_path" ]; then \
		if [ ! -L "$$command_path" ] || \
			[ "$$(readlink "$$command_path")" != "$$expected_target" ]; then \
			echo "error: refusing to replace command not owned by this package: $$command_path" >&2; \
			exit 1; \
		fi; \
	fi
	"$(INSTALL)" -d "$(LIBEXEC_DIR)" "$(BIN_DIR)" "$(MAN_DIR)"
	"$(INSTALL)" -m 755 "$(BINARY)" "$(LIBEXEC_DIR)/airpods-control"
	"$(INSTALL)" -m 755 "$(DYLIB)" "$(LIBEXEC_DIR)/avbypass.dylib"
	"$(INSTALL)" -m 644 "$(MANPAGE)" "$(MAN_DIR)/airpods-control.1"
	@if [ ! -L "$(BIN_DIR)/airpods-control" ]; then \
		ln -s ../libexec/airpods-control/airpods-control \
			"$(BIN_DIR)/airpods-control"; \
	fi

uninstall:
	@set -eu; \
	command_path="$(BIN_DIR)/airpods-control"; \
	expected_target=../libexec/airpods-control/airpods-control; \
	if [ -e "$$command_path" ] || [ -L "$$command_path" ]; then \
		if [ ! -L "$$command_path" ] || \
			[ "$$(readlink "$$command_path")" != "$$expected_target" ]; then \
			echo "error: refusing to remove command not owned by this package: $$command_path" >&2; \
			exit 1; \
		fi; \
		rm -f "$$command_path"; \
	fi
	rm -f "$(LIBEXEC_DIR)/airpods-control" "$(LIBEXEC_DIR)/avbypass.dylib"
	rm -f "$(MAN_DIR)/airpods-control.1"
	-rmdir "$(LIBEXEC_DIR)"

clean:
	@test -n "$(BUILD_DIR)" && test "$(BUILD_DIR)" != "/"
	rm -rf "$(BUILD_DIR)"
