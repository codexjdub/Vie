# Vie build targets. Works with Command Line Tools only (no Xcode); see PLAN.md, "Tooling".
# Build output goes to BUILD_DIR, outside the repo (see scripts/common.sh for why).

CONFIG ?= release
SIGN_ID ?= codexjdub
BUILD_DIR ?= $(HOME)/Library/Caches/Vie-dev
export BUILD_DIR
APP := $(BUILD_DIR)/Vie.app

# With Command Line Tools, `swift test` doesn't find the Swift Testing macro plugin on its own.
TOOLCHAIN_USR := $(shell dirname $$(dirname $$(xcrun --find swift)))
TESTING_PLUGINS := $(TOOLCHAIN_USR)/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: app run test bench clean

app:
	scripts/make-app.sh $(CONFIG) "$(SIGN_ID)"

# make run              opens an empty window
# make run FILE=path    opens a file
run: app
	open "$(APP)" $(if $(FILE),--args "$(abspath $(FILE))")

test:
	swift test --scratch-path "$(BUILD_DIR)/swiftpm" $(TEST_FLAGS)

bench: app
	scripts/bench.sh

clean:
	rm -rf "$(BUILD_DIR)" .build
