# D110 Studio

Dark Gruvbox Flutter label editor: text, transparent QR codes and images; drag, rotate and scale; box reflow or per-axis glyph stretching; 10 bundled open fonts; threshold, Bayer/Floyd–Steinberg dithering and Sobel edges. Bluetooth printing, local templates, no accounts or telemetry.

**Printers:** ORICO D110 / Temu-style D110 label printers using the **AiYin/Fichero protocol**. Tested revision: D110, firmware **V1.0.4**, USB **09c5:0200**, 96-dot printhead. Other revisions are unverified; **NIIMBOT-protocol D110 is not supported**.

**Downloads:** [Linux AppImage, Android APK, Windows EXE](https://github.com/l4l4l4l4/d110-studio/releases/latest). Windows installer is unsigned.

**Use:** connect the classic Bluetooth D110 (not `_BLE`), choose your roll's label length, compose and print. Printable width is 12 mm; heat level 3 is maximum. For 30 mm labels with 8 mm gaps, use 30 mm: gap mode positions the next label automatically, without adding the gap to the image. Leave the QR's 4-module quiet zone clear. Templates are stored on the host, not inside the printer; firmware is not modified.

**Build:** Flutter 3.41.9; `make check`, `make run`, `make apk`, `make appimage`, `make windows`. Nix: `nix develop`. Android requires JDK 17 and private `android/key.properties` for release signing; CI uses the `ANDROID_SIGNING` secret.

`make check` covers text/QR payload preservation and text-dialog save, cancel and outside-click dismissal, alongside touch gestures and raster output. Text-entry fields own their controllers until the dialog route is unmounted; completing `showDialog` does not end the outgoing route's lifetime.

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

[MIT license](LICENSE) · Bundled fonts: SIL OFL-1.1 (licenses included in the app). Gothic/Bungee are Latin-only; international fallbacks are broad, not universal. · [Protocol reference](https://github.com/0xMH/fichero-printer/blob/main/docs/PROTOCOL.md)
