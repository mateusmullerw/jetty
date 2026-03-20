export DEVELOPER_DIR = /Applications/Xcode-beta.app/Contents/Developer

APP       = Jetty.app
BINARY    = Jetty
BUNDLE    = $(APP)/Contents/MacOS
RESOURCES = $(APP)/Contents/Resources
PLIST_SRC = Sources/Jetty/Resources/Info.plist
PLIST_DST = $(APP)/Contents/Info.plist
ICON_SRC  = Sources/Jetty/Resources/Jetty.icns
ICON_DST  = $(RESOURCES)/Jetty.icns

.PHONY: build run dmg clean

build:
	swift build -c release
	mkdir -p $(BUNDLE) $(RESOURCES)
	cp .build/release/$(BINARY) $(BUNDLE)/$(BINARY)
	cp $(PLIST_SRC) $(PLIST_DST)
	cp $(ICON_SRC)  $(ICON_DST)
	codesign --force --deep --sign - $(APP)

run: build
	open $(APP)

dmg: build
	hdiutil create -volname Jetty -srcfolder $(APP) -ov -format UDZO Jetty.dmg
	@echo "Built Jetty.dmg — ready to distribute"

clean:
	rm -rf $(APP) Jetty.dmg
	swift package clean
