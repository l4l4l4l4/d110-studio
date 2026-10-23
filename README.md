# D110 Studio

Dark Gruvbox Flutter label editor: text, transparent QR codes, images and freehand ink; drag, rotate and scale; box reflow or per-axis glyph stretching; 10 bundled open fonts; threshold, Bayer/Floyd–Steinberg dithering and Sobel edges. Bluetooth printing, tiled sticker stacks, local templates, no accounts or telemetry.

**Printers:** ORICO D110 / Temu-style D110 label printers using the **AiYin/Fichero protocol**. Tested revision: D110, firmware **V1.0.4**, USB **09c5:0200**, 96-dot printhead. Other revisions are unverified; **NIIMBOT-protocol D110 is not supported**.

**Downloads:** [Linux AppImage, Android APK, Windows EXE](https://github.com/l4l4l4l4/d110-studio/releases/latest). Windows installer is unsigned.

**Use:** connect the classic Bluetooth D110 (not `_BLE`), choose or calibrate the physical roll, compose and print. The printhead is fixed at 96 dots (nominally 12 mm); that is not a measurement of the paper width. Heat level 3 is maximum. For 30 mm labels with 8 mm gaps, use 30 mm: gap mode positions the next label automatically, without adding the gap to the image. Leave the QR's 4-module quiet zone clear. Templates are stored on the host, not inside the printer; firmware is not modified.

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

Named design tabs keep independent artwork, selection, inspector, zoom, pan
and source/print preview states. The active tab and its close button scroll
into view; closing a changed draft requires confirmation. Creating or switching
tabs does not send anything to the printer.

Drafts persist locally and survive reopening. Startup selects the exact last
acknowledged print while retaining newer edits in their own tabs. A damaged
print-history record warns without discarding or blocking valid drafts;
unreadable draft storage is not silently overwritten.

`Стек` splits one full-size design into a 1–8 by 1–8 sticker grid without
rescaling its dots. Canvas seams show the exact crop boundaries. Templates
save the grid and media geometry as version 3. Versions 1 and 2 retain their
artwork and migrate to explicitly unmeasured legacy paper geometry.
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

Android, Linux/BlueZ and Windows monitor adapter changes without polling.
Known power loss updates the foreground connection state without waiting for
resume. Power restoration schedules one saved-printer reconnect after active
I/O settles; interrupted prints are never replayed. Late discovery or handshake
replies cannot override a newer power-loss event.

An inspection failure reports unknown power, not a false Bluetooth-off state,
and preserves a potentially healthy transport. Explicit permission refusal
remains distinct from a missing grant. A successful explicit connection
refreshes permission/power state before showing connected guidance.

The picker excludes BLE-only twins, unrelated device names and devices known
not to expose classic Serial Port Profile. An unverified classic D110 with
unknown cached service metadata remains a candidate until the protocol
handshake; a previously verified classic address may survive renaming or stale
service metadata. Missing cached UUIDs are not proof of incompatibility.
This printer uses classic RFCOMM/SPP, not a BLE GATT print service.

`Рисунок` opens a finger/mouse canvas at the full design's physical dot size,
with a 1–32-dot black brush, undo and recoverable clear. Save adds movable,
resizable ink without erasing underlying objects; cancel leaves the design
unchanged. One-dot taps align to physical pixels. Full-grid ink retains its dot
scale when saved, reopened or moved, including tall compositions. The full
canvas has a shared 16-megapixel limit. Secondary pointers and interrupted
strokes do not commit new ink.

## Physical media calibration

Paper length, width, rounded-corner radius and printhead offsets are separate
from the fixed 96-dot head. Dimensions retain fractional millimetres; offsets
are whole dots at the application's nominal eight dots/mm. Canvas and stack
seams show the physical paper; amber areas outside the head cannot print.
Rendering clips every tile to its rounded paper/head intersection without
rescaling the artwork. Hidden source ink remains available for later editing.

`Калибровка ленты` prints a reference with labelled dot-centre fiducials,
accepts measured geometry, then prints a separate verification pattern.
The reference coordinates remain bound to the pattern actually acknowledged,
even if the draft length changes afterward. The live geometry diagram remains
visible while editing measurements. Saving a measured profile requires both
acknowledged patterns and explicit visual confirmation; a rendered preview or
an offline save cannot mark a roll as calibrated.

The saved roll becomes the default for new designs. Existing designs retain
their embedded geometry until the saved profile is explicitly applied. Repeat
calibration after changing rolls or alignment; invalid edits preserve the
previous profile and show a recoverable error.

**No stock dimensions or corner radius have been empirically established yet.**
The initial 30 × 12 mm square-corner profile is nominal, not a measurement.
Photographs can recover geometry in the printed fiducial coordinate system;
conversion to millimetres still uses nominal dot pitch, not traceable metrology.

## Last printed design

Startup restores the last user design acknowledged by the printer, without
sending another print job. The immutable snapshot is captured before rendering
or transmission; edits made afterward do not change that saved print.
Failed or ambiguous jobs and QR/media diagnostics do not replace it.
For a stack, the first acknowledged tile records the original full design once,
not an isolated tile or an unconfirmed remainder.

History is local to the installation. Corrupt or unwritable storage produces an
explicit warning. A save failure after acknowledgement means printed-but-not-
saved, not a failed print, and never triggers a second transmission.

## Physical QR calibration

With a connected printer, QR calibration offers up to 15 separate stickers
across all three heat levels. Integer pitches are included only when their
modules and four-module quiet zone fit the current media's safe rectangle.
The nominal 30 × 12 mm profile includes short-payload pitches of 1, 2 and
3 dots/module and realistic short-link pitches of 1 and 2. Every sample prints
test metadata. Record the actual roll/media, scan each sample three times
independently and mark 3/3 or failed, then copy the JSON report.

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

## License

Project code is licensed under [ПО ХУЙ LICENSE](LICENSE), version 1.0.
This is an **unapproved custom license**, not an OSI-approved open-source license.
Contribution rules are separate: [POHUY-COVENANT-1.0](COVENANT.md).

The license, covenant and required `pohuy` skill are pinned to
[canonical commit d3686738cf73236b84da93e0981d6e0f61b37747](https://github.com/l4l4l4l4/POHUY-LICENSE/tree/d3686738cf73236b84da93e0981d6e0f61b37747).
`skill.lock` records the canonical skill digest; contribution evidence belongs in
`.pohuy-evidence/<submission-id>/`. The evidence checker verifies bundle structure
and digests, not whether a client honestly captured every event.

Bundled fonts retain SIL OFL-1.1 (licenses included in the app); dependencies retain
their own licenses. Gothic/Bungee are Latin-only; international fallbacks are broad,
not universal. · [Protocol reference](https://github.com/0xMH/fichero-printer/blob/main/docs/PROTOCOL.md)
