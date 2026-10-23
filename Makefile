FLUTTER ?= flutter
DART ?= dart
PREVIEW_PORT ?= 8877
SHORTENER_ORIGIN ?= https://s.lalala.ing

.PHONY: deps check format run preview linux apk apk-debug windows appimage

deps:
	$(FLUTTER) pub get

check:
	$(DART) format --output=none --set-exit-if-changed lib test
	$(FLUTTER) analyze
	$(FLUTTER) test

format:
	$(DART) format lib test

run:
	$(FLUTTER) run -d linux --dart-define="D110_SHORTENER_ORIGIN=$(SHORTENER_ORIGIN)"

preview:
	$(FLUTTER) run -d web-server --web-port "$(PREVIEW_PORT)" --dart-define="D110_SHORTENER_ORIGIN=$(SHORTENER_ORIGIN)"

linux:
	$(FLUTTER) build linux --release --dart-define="D110_SHORTENER_ORIGIN=$(SHORTENER_ORIGIN)"

apk:
	$(FLUTTER) build apk --release --dart-define="D110_SHORTENER_ORIGIN=$(SHORTENER_ORIGIN)"

apk-debug:
	$(FLUTTER) build apk --debug --dart-define="D110_SHORTENER_ORIGIN=$(SHORTENER_ORIGIN)"

windows:
	$(FLUTTER) build windows --release --dart-define="D110_SHORTENER_ORIGIN=$(SHORTENER_ORIGIN)"

appimage: linux
	bash packaging/appimage.sh
