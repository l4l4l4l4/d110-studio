FLUTTER ?= flutter
DART ?= dart

.PHONY: deps check format run preview linux apk windows appimage

deps:
	$(FLUTTER) pub get

check:
	$(DART) format --output=none --set-exit-if-changed lib test
	$(FLUTTER) analyze
	$(FLUTTER) test

format:
	$(DART) format lib test

run:
	$(FLUTTER) run -d linux

preview:
	$(FLUTTER) run -d web-server --web-port 8877

linux:
	$(FLUTTER) build linux --release

apk:
	$(FLUTTER) build apk --release

windows:
	$(FLUTTER) build windows --release

appimage: linux
	bash packaging/appimage.sh
