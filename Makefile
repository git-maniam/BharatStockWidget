# BharatStock Widget
#
# `make help` lists everything. The short version:
#   make test       run the core test suite (no Xcode project needed)
#   make build      compile every target
#   make dry-run    exercise a full refresh offline, against fixtures
#   make install    build, sign, and install into /Applications
#
# There is no `install-agent` / `uninstall-agent`: this build has no LaunchAgent. The widget
# schedules itself. See docs/decisions.md §2.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT     := BharatStockWidget.xcodeproj
SCHEME      := BharatStockApp
CORE        := Packages/BharatStockCore
APP_NAME    := BharatStock Widget
CONFIGURATION ?= Debug
BUILD_DIR   := build
APP_GROUP_SUFFIX := group.com.ravisubramaniam.bharatstockwidget
FRIENDLY_CONFIG  := $(HOME)/Library/Application Support/BharatStockWidget

.PHONY: help
help:
	@echo "BharatStock Widget"
	@echo ""
	@echo "  make build           Compile all targets (Debug; no signing required)"
	@echo "  make release         Compile all targets (Release)"
	@echo "  make test            Run the BharatStockCore test suite"
	@echo "  make dry-run         Full refresh cycle against fixtures; spends no API budget"
	@echo "  make dry-run-json    Same, JSON only, for piping into jq"
	@echo "  make install         Build signed and copy to /Applications, then register the widget"
	@echo "  make uninstall       Remove the app, the App Group container, and the config symlink"
	@echo "  make project         Regenerate the Xcode project from project.yml"
	@echo "  make open            Open the project in Xcode"
	@echo "  make logs            Tail the plaintext log"
	@echo "  make console         Stream os_log output for the widget and the app"
	@echo "  make clean           Remove build products"
	@echo "  make check           project + test + build + dry-run (what CI would do)"
	@echo ""
	@echo "  CONFIGURATION=Release make build   override the build configuration"

# ---------------------------------------------------------------------------------------------
# Project generation

$(PROJECT): project.yml Config/Signing.xcconfig
	@command -v xcodegen >/dev/null || { echo "xcodegen not found. brew install xcodegen"; exit 1; }
	xcodegen generate

.PHONY: project
project:
	@command -v xcodegen >/dev/null || { echo "xcodegen not found. brew install xcodegen"; exit 1; }
	xcodegen generate

.PHONY: open
open: $(PROJECT)
	open $(PROJECT)

# ---------------------------------------------------------------------------------------------
# Build and test

.PHONY: build
build: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

.PHONY: release
release:
	$(MAKE) build CONFIGURATION=Release

.PHONY: test
test:
	cd $(CORE) && swift test

.PHONY: dry-run
dry-run:
	cd $(CORE) && swift run bharatstock-dryrun $(ARGS)

.PHONY: dry-run-json
dry-run-json:
	@cd $(CORE) && swift run bharatstock-dryrun --json 2>/dev/null

.PHONY: check
check: project test build dry-run
	@echo ""
	@echo "All checks passed."

# ---------------------------------------------------------------------------------------------
# Install

.PHONY: install
install: $(PROJECT)
	@team=$$(sed -n 's/^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' Config/Signing.xcconfig | tr -d '[:space:]'); \
	if [ -z "$$team" ]; then \
		echo "DEVELOPMENT_TEAM is not set in Config/Signing.xcconfig."; \
		echo ""; \
		echo "macOS requires the App Group identifier to be prefixed with your Team ID, and the"; \
		echo "App Group is the only channel between the widget and the app. Without it the widget"; \
		echo "installs but shows nothing."; \
		echo ""; \
		echo "Find your Team ID with:  security find-identity -v -p codesigning"; \
		echo "It is the value in parentheses, e.g. \"Apple Development: you@example.com (ABCDE12345)\"."; \
		exit 1; \
	fi
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(BUILD_DIR) build
	@rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app" /Applications/
	@echo ""
	@echo "Installed /Applications/$(APP_NAME).app"
	@echo ""
	@echo "Next:"
	@echo "  1. Open it once. That creates the config, the README beside it, and the symlink at"
	@echo "     $(FRIENDLY_CONFIG)/config.json"
	@echo "  2. Paste your API key into the setup screen."
	@echo "  3. Right-click the desktop (or open Notification Centre) -> Edit Widgets -> BharatStock."

.PHONY: uninstall
uninstall:
	@echo "Removing the app..."
	@rm -rf "/Applications/$(APP_NAME).app"
	@echo "Removing the App Group container (this deletes your config and watchlist)..."
	@for dir in "$(HOME)/Library/Group Containers/"*$(APP_GROUP_SUFFIX); do \
		if [ -d "$$dir" ]; then echo "  $$dir"; rm -rf "$$dir"; fi; \
	done
	@echo "Removing the config symlink..."
	@rm -f "$(FRIENDLY_CONFIG)/config.json"
	@rmdir "$(FRIENDLY_CONFIG)" 2>/dev/null || true
	@echo "Removing logs..."
	@rm -rf "$(HOME)/Library/Logs/BharatStockWidget"
	@echo ""
	@echo "Done. Nothing is left behind: there is no LaunchAgent and no login item to remove."
	@echo "If the widget lingers in the gallery, run: killall chronod ; killall WidgetKit-Simulator 2>/dev/null || true"

# ---------------------------------------------------------------------------------------------
# Diagnostics

.PHONY: logs
logs:
	@f="$(HOME)/Library/Logs/BharatStockWidget/helper.log"; \
	if [ -f "$$f" ]; then tail -f "$$f"; else echo "No log yet at $$f"; fi

.PHONY: console
console:
	log stream --predicate 'subsystem == "com.ravisubramaniam.bharatstockwidget"' --level debug --style compact

.PHONY: where
where:
	@echo "Config (friendly)  : $(FRIENDLY_CONFIG)/config.json"
	@echo "Config (real)      :"; ls -d "$(HOME)/Library/Group Containers/"*$(APP_GROUP_SUFFIX) 2>/dev/null || echo "  (no App Group container yet — is DEVELOPMENT_TEAM set?)"
	@echo "Log                : $(HOME)/Library/Logs/BharatStockWidget/helper.log"

# ---------------------------------------------------------------------------------------------
# Clean

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	cd $(CORE) && swift package clean
	@echo "Cleaned. (The Xcode project itself is generated; `make project` recreates it.)"

.PHONY: distclean
distclean: clean
	rm -rf $(PROJECT)
