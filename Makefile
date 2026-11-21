# Vie build targets. Works with Command Line Tools only (no Xcode); see PLAN.md, "Tooling".
# Build output goes to BUILD_DIR, outside the repo (see scripts/common.sh for why).

CONFIG ?= release
SIGN_ID ?= codexjdub
BUILD_DIR ?= $(HOME)/Library/Caches/Vie-dev
export BUILD_DIR
INSTALL_DIR ?= /Applications
export INSTALL_DIR
APP := $(BUILD_DIR)/Vie.app

# With Command Line Tools, `swift test` doesn't find the Swift Testing macro plugin on its own.
TOOLCHAIN_USR := $(shell dirname $$(dirname $$(xcrun --find swift)))
TESTING_PLUGINS := $(TOOLCHAIN_USR)/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: app install run test bench clean grammars fonts icon

# tree-sitter and the grammar sources, downloaded once at pinned versions (see the script).
grammars:
	scripts/fetch-grammars.sh

# The fonts bundled in the app (JetBrains Mono, Terminus TTF), likewise pinned and kept out of git.
fonts:
	scripts/fetch-fonts.sh

app: grammars fonts
	scripts/make-app.sh $(CONFIG) "$(SIGN_ID)"

# Replaces Vie.app in INSTALL_DIR with this build, quitting a running Vie and reopening it.
install: app
	scripts/install.sh

# make run              opens an empty window
# make run FILE=path    opens a file
run: app
	open "$(APP)" $(if $(FILE),--args "$(abspath $(FILE))")

test: grammars fonts
	swift test --scratch-path "$(BUILD_DIR)/swiftpm" $(TEST_FLAGS)

bench: app
	scripts/bench.sh

# Redraws App/AppIcon.icns from scripts/make-icon.swift (checked in, so `make app` doesn't).
icon:
	mkdir -p "$(BUILD_DIR)"
	swiftc -O scripts/make-icon.swift -o "$(BUILD_DIR)/make-icon"
	"$(BUILD_DIR)/make-icon" App/AppIcon.icns

clean:
	rm -rf "$(BUILD_DIR)" .build
