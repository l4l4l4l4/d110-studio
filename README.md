# D110 Studio

Dark Gruvbox Flutter label editor: text, transparent QR codes, images and freehand ink; drag, rotate and scale; box reflow or per-axis glyph stretching; 10 bundled open fonts; threshold, Bayer/Floyd–Steinberg dithering and Sobel edges. Bluetooth printing, tiled sticker stacks, local templates, no accounts or telemetry.

**Printers:** ORICO D110 / Temu-style D110 label printers using the **AiYin/Fichero protocol**. Tested revision: D110, firmware **V1.0.4**, USB **09c5:0200**, 96-dot printhead. Other revisions are unverified; **NIIMBOT-protocol D110 is not supported**.

**Downloads:** [Linux AppImage, Android APK, Windows EXE](https://github.com/l4l4l4l4/d110-studio/releases/latest). Windows installer is unsigned.

**Use:** connect the classic Bluetooth D110 (not `_BLE`), choose your roll's label length, compose and print. Printable width is 12 mm; heat level 3 is maximum. For 30 mm labels with 8 mm gaps, use 30 mm: gap mode positions the next label automatically, without adding the gap to the image. Leave the QR's 4-module quiet zone clear. Templates are stored on the host, not inside the printer; firmware is not modified.

**Build:** Flutter 3.41.9; `make check`, `make run`, `make apk`, `make apk-debug`, `make appimage`, `make windows`. Nix: `nix develop`. Android requires an Android SDK and JDK 17; release builds additionally require private `android/key.properties`. CI uses the `ANDROID_SIGNING` secret. Do not uninstall an existing signed app to replace it with a differently signed debug APK: that would delete local templates.

Resize and rotation use distinct nearest touch targets. The gesture surface
extends beyond the label paper, and selection handles stay inside the visible
viewport after resizing, rotation, zoom and pan. `make check` includes four
consecutive text resizes at both zero and nonzero rotation, plus overlapping
handles on a small rotated object.

`Правка` keeps object settings beside the canvas on desktop and below it on
narrow screens. The canvas remains visible and interactive while changing
valid numeric values, text, size, rotation and image processing. For images,
switch between the original color source and the actual monochrome print
result; only the latter is printed. Inspector controls scroll independently
of the canvas.

`Стек` splits one full-size design into a 1–8 by 1–8 sticker grid without
rescaling its dots. Canvas seams show the exact crop boundaries. Templates
save the grid as version 2 and still load version 1 as a single sticker.
Printing proceeds left-to-right, then top-to-bottom: after each printer
acknowledgement, an animated placement guide shows the emitted sticker and
waits for `Наклеено — дальше`. Cancellation settles an in-flight sticker;
an ambiguous failure stops the job without retrying or replaying it.

The last printer address is saved only after a successful D110 handshake.
Native launch/resume makes one passive reconnect attempt without prompting for
missing permissions or replaying prints. Android offers the system Bluetooth
enable request; desktop opens Bluetooth settings and provides return guidance.
First-use connection obtains permission and Bluetooth enable before opening
the picker. Declining leaves the editor usable without an error-only dialog.
Missing adapters, denied permissions, cancelled requests and discovery errors
have distinct recovery states.

`Рисунок` opens a finger/mouse canvas at the full design's physical dot size,
with a 1–32-dot black brush, undo and recoverable clear. Save adds movable,
resizable ink without erasing underlying objects; cancel leaves the design
unchanged. One-dot taps align to physical pixels. Full-grid ink retains its dot
scale when saved, reopened or moved, including a 9600×768-dot composition.
Secondary pointers and interrupted strokes do not commit new ink.

## Physical QR calibration

With a connected printer, the QR calibration action offers up to 15 separate
30 mm test stickers across all three heat levels. Short-payload candidates
use 1, 2 and 3 dots/module; realistic short-link candidates use 1 and 2.
Every sample includes an integer module pitch, a four-module quiet zone and
printed test metadata. Record the actual roll/media, scan each sample three
times independently and mark 3/3 or failed, then copy the JSON report.

**No maximum reliable QR density has been established yet.** A rendered QR
or a successful printer acknowledgment is not a successful physical scan.
Use the smallest consistently readable module pitch measured on the actual
printer, media and heat setting; do not infer a universal default from one
sample. The existing warning below two dots/module is not a calibration result.

## Optional anonymous link shortening

The QR text dialog can explicitly shorten an HTTP(S) URL through
`https://s.lalala.ing`, without signing in. Selecting that option discloses
that the URL is submitted to the public service. The device solves a
URL-bound, expiring SHA-256 proof of work; progress remains cancellable.
Plain text and unchanged URLs remain available without shortening.
Timeouts, cancellation and service errors never insert a fabricated link.
Leaving the dialog aborts active requests, including response bodies. A late
reply cannot dismiss another screen.

The service is maintained in `habibi/services`, independently deployed by the
owner. DNS, public TLS and production acceptance are prerequisites; source
code and a local test server are not evidence of deployment. PoW is an abuse
cost, not a guarantee that a redirect destination is safe.

For an isolated local service, use
`make preview PREVIEW_PORT=8878 SHORTENER_ORIGIN=http://127.0.0.1:18767`.
The same `SHORTENER_ORIGIN` build override is available on native Make targets;
release builds default to HTTPS on `s.lalala.ing`.

`make check` covers dialog payload preservation, repeated touch resizing,
live inspector geometry, stack cropping and print-state transitions, printer
recovery, drawing raster output and QR calibration geometry. These tests do
not establish physical QR readability. Text-entry fields own their controllers
until the dialog route is unmounted, not merely until `showDialog` completes.

[MIT license](LICENSE) · Bundled fonts: SIL OFL-1.1 (licenses included in the app). Gothic/Bungee are Latin-only; international fallbacks are broad, not universal. · [Protocol reference](https://github.com/0xMH/fichero-printer/blob/main/docs/PROTOCOL.md)
