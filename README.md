# D110 Studio

Dark Gruvbox Flutter label editor: text, transparent QR codes, images and freehand ink; drag, rotate and scale; box reflow or per-axis glyph stretching; 10 bundled open fonts; threshold, Bayer/Floyd–Steinberg dithering and Sobel edges. Bluetooth printing, tiled sticker stacks, local templates, no accounts or telemetry.

**Printers:** ORICO D110 / Temu-style D110 label printers using the **AiYin/Fichero protocol**. Tested revision: D110, firmware **V1.0.4**, USB **09c5:0200**, 96-dot printhead. Other revisions are unverified; **NIIMBOT-protocol D110 is not supported**.

**Downloads:** [Linux AppImage, Android APK, Windows EXE](https://github.com/l4l4l4l4/d110-studio/releases/latest). Windows installer is unsigned.

**Use:** connect the classic Bluetooth D110 (not `_BLE`), choose or calibrate the physical roll, compose and print. The printhead is fixed at 96 dots (nominally 12 mm); that is not a measurement of the paper width. Heat level 3 is maximum. For 30 mm labels with 8 mm gaps, use 30 mm: gap mode positions the next label automatically, without adding the gap to the image. Leave the QR's 4-module quiet zone clear. Templates are stored on the host, not inside the printer; firmware is not modified.

**Build:** Flutter 3.41.9; `make check`, `make run`, `make apk`, `make apk-debug`, `make appimage`, `make windows`. Nix: `nix develop` for checks; `nix develop .#android --command make apk-debug` supplies the pinned Android SDK, NDK, CMake and JDK 17 locally. Release builds additionally require private `android/key.properties`. CI uses the `ANDROID_SIGNING` secret. Do not uninstall an existing signed app to replace it with a differently signed debug APK: that would delete local templates.

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

Numeric settings use labeled sliders with exact editable fields and units.
Changes preview while dragging; arrow keys adjust one step. Label length keeps
its 0.125 mm dot precision, and manual entry preserves finer measured values.
Large dimensions use a local slider range fixed during each drag; exact entry
still accepts the full supported range. Width/height sliders replace the old
±10% size buttons.

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
save the grid, media geometry and trim mode as version 4. Versions 1 and 2
retain their artwork and migrate to explicitly unmeasured legacy geometry;
version 3 retains its geometry with trim mode disabled.
Printing proceeds left-to-right, then top-to-bottom: after each printer
acknowledgement, an animated placement guide shows the emitted sticker and
waits for `Наклеено — дальше`. Cancellation settles an in-flight sticker;
an ambiguous failure stops the job without retrying or replaying it.

`Стек без белых швов · обрезать края` uses the measured safe rectangle as each
logical tile. Dots are translated into the physical printable area without
scaling; cut off the indicated paper margins before joining the stickers.
This mode requires measured media. It cannot print into hardware dead zones,
and joined QR readability still requires physical cut/join/scan verification.

The print dialog accepts 1–99 copies. Single-label copies advance only after
each printer acknowledgement; stacks retain the placement pause between tiles
and start a fresh placement guide for each copy. Cancellation never replays
an uncertain print.

The last printer address is saved only after a successful D110 handshake.
While the native app is resumed, launch, return, adapter restoration and idle
transport loss reconnect that saved printer. Transient failures retry without
a count limit, three seconds after the previous attempt finishes. Printer I/O
remains single-flight. Opening a device picker pauses new passive attempts;
discovery waits for active controller I/O. Unrelated editor actions remain
available. `Отключить` pauses recovery until an explicit connection or the next
foreground resume. Backgrounding cancels the timer and lets existing I/O settle.
Missing permissions, disabled/unavailable Bluetooth, unsupported models and
storage failures stop the current retry cycle; passive connection cannot open
a permission prompt, enable Bluetooth or replay a print.

Android offers the system Bluetooth enable request; desktop opens Bluetooth
settings and provides return guidance. First-use connection obtains permission
and Bluetooth enable before opening the picker. Declining leaves the editor
usable without an error-only dialog. Recovery states remain distinct.

Android, Linux/BlueZ and Windows monitor adapter changes without polling.
Known power loss updates the connection state without waiting for resume.
Power restoration resumes saved-printer recovery after active I/O settles;
late discovery or handshake replies cannot override a newer power-loss event.

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

`Калибровка ленты` is a five-step wizard: reference, photograph, contour review,
verification print, and explicit visual confirmation. The short reference is
80 × 96 dots with fixed dot-centre fiducials and ruler phase. Crosses use
13-dot spans and 3-dot strokes. An existing matching reference can be explicitly
reused without printing another label. Back permits another guarded reference
print instead of leaving the wizard stuck.

The embedded rear camera opens immediately after the reference acknowledgement
or explicit reuse. The default live view shows the detector's actual paper/ink
mask, rejection guidance, and measured contour/crosses when detection succeeds;
adjusted grayscale and original views remain available. Brightness and contrast
sliders use the same transform for live frames and the returned captured or
imported photograph. Native camera EV is queried from the device and applied
before capture. The torch control is on/off, not a simulated strength slider;
the tested Redmi Note 10 Pro driver advertises only one torch strength level.
Stream processing is single-flight with a 500 ms frame throttle,
with bounded image dimensions; unsupported streaming explicitly falls back to
the original preview. Live measurements are guidance, not calibration approval:
the still photograph is measured separately. Cancelling preserves the reference
for another attempt. Photograph the whole label on a dark background.
Camera-owned temporary files and Blob URLs are released after reading or a
cancelled shutter; gallery/import sources are never deleted.
Geometry is calculated locally, including rounded corners and signed head/feed
offsets. Ambiguous automatic marks require four ordered manual taps; missing
paper edges or insufficient image quality are rejected, not guessed. The contour
is overlaid on the photograph; optional numeric corrections remain secondary.
Paper segmentation separates flash-lit background highlights from white paper
and gray thermal ink. Measurements use local subpixel paper edges, not the
segmentation brightness threshold. Fiducials are validated by their optical
cores and white quadrants; ruler orientation also uses the asymmetric first
feed stripe, which remains informative when blur erases interior one-dot phase.
Missing crosses, ambiguous orientation and damaged contours still fail rather
than returning nominal dimensions.

Local session state retains the photo, frozen reference coordinates, draft and
pending print outcome across closing or interruption. Reopening never prints
automatically. An uncertain acknowledgement requires inspection and explicit
consent before another print; failed storage cannot cause a print replay.
An uncertain verification disables Back to preserve its pending-print guard;
closing remains safe and another attempt still requires consent. Lifecycle saves
cannot overwrite an in-flight transition with an older session snapshot.
Geometry changes invalidate verification without changing the original reference
scale. A calibrated profile requires an acknowledged or explicitly reused
reference, an acknowledged verification print and explicit visual confirmation.
A photograph, rendered preview or offline save alone cannot calibrate a roll.

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
For a stack, acknowledgement of the final tile of a complete copy records the
original full design, never an isolated tile or an unconfirmed remainder.

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

## Licensing

No project-code license is currently granted. Historical contribution evidence
is retained as history, not as an active submission requirement.

Bundled fonts retain SIL OFL-1.1 (licenses included in the app); dependencies retain
their own licenses. Gothic/Bungee are Latin-only; international fallbacks are broad,
not universal. · [Protocol reference](https://github.com/0xMH/fichero-printer/blob/main/docs/PROTOCOL.md)
