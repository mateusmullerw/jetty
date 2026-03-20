APP       = Jetty.app
BINARY    = Jetty
BUNDLE    = $(APP)/Contents/MacOS
RESOURCES = $(APP)/Contents/Resources
PLIST_SRC = Sources/Jetty/Resources/Info.plist
PLIST_DST = $(APP)/Contents/Info.plist

.PHONY: build run clean

build:
	swift build -c release
	mkdir -p $(BUNDLE) $(RESOURCES)
	cp .build/release/$(BINARY) $(BUNDLE)/$(BINARY)
	cp $(PLIST_SRC) $(PLIST_DST)

run: build
	open $(APP)

clean:
	rm -rf $(APP)
	swift package clean
