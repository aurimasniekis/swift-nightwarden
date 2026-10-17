APP_NAME    := Nightwarden
BUNDLE_ID   := lt.niekis.nightwarden
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_APP := $(HOME)/Applications/$(APP_NAME).app
AGENT       := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
SUPPORT     := $(HOME)/Library/Application Support/$(APP_NAME)
USER_ID     := $(shell id -u)
DOMAIN      := gui/$(USER_ID)
ICON        := Resources/AppIcon.icns
ICONSET     := $(BUILD_DIR)/AppIcon.iconset
VERSION     ?= $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ZIP         := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip

.DEFAULT_GOAL := app
.PHONY: build test app dist icon run install uninstall purge clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	cp $(ICON) "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force -s - --identifier $(BUNDLE_ID) "$(APP)"

# Zipped app + checksum for a release: make dist VERSION=1.2.3
dist: app
	rm -f "$(ZIP)" "$(ZIP).sha256"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	cd "$(BUILD_DIR)" && shasum -a 256 "$(notdir $(ZIP))" > "$(notdir $(ZIP)).sha256"
	@echo "$(ZIP)"

# Re-render Resources/AppIcon.icns from Resources/AppIcon.swift (the .icns is checked in).
icon:
	rm -rf "$(ICONSET)" && mkdir -p "$(ICONSET)"
	swift Resources/AppIcon.swift "$(BUILD_DIR)/AppIcon-1024.png"
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s "$(BUILD_DIR)/AppIcon-1024.png" --out "$(ICONSET)/icon_$${s}x$${s}.png" >/dev/null; \
		sips -z $$((s * 2)) $$((s * 2)) "$(BUILD_DIR)/AppIcon-1024.png" --out "$(ICONSET)/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	iconutil -c icns -o $(ICON) "$(ICONSET)"

run: app
	open "$(APP)"

install: app
	-launchctl bootout $(DOMAIN)/$(BUNDLE_ID) 2>/dev/null
	mkdir -p "$(dir $(INSTALL_APP))" "$(dir $(AGENT))"
	rm -rf "$(INSTALL_APP)"
	ditto "$(APP)" "$(INSTALL_APP)"
	sed "s|__EXECUTABLE__|$(INSTALL_APP)/Contents/MacOS/$(APP_NAME)|g" Resources/$(BUNDLE_ID).plist > "$(AGENT)"
	launchctl bootstrap $(DOMAIN) "$(AGENT)"
	@echo
	@echo "Installed $(INSTALL_APP) and started it via launchd ($(BUNDLE_ID))."
	@echo "Reminder: System Settings → Notifications → Nightwarden → choose the \"Alerts\" style"
	@echo "so stuck warnings stay on screen until you act on them."

uninstall:
	-launchctl bootout $(DOMAIN)/$(BUNDLE_ID) 2>/dev/null
	rm -f "$(AGENT)"
	rm -rf "$(INSTALL_APP)"
	@echo "Uninstalled. Settings and metrics kept in $(SUPPORT) (make purge removes them)."

purge: uninstall
	rm -rf "$(SUPPORT)"

clean:
	rm -rf $(BUILD_DIR) .build
