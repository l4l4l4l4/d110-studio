# D110 Studio

> [!WARNING]
> **SLOP** — mostly AI-generated code. It works on my phone and my printer; use at your own risk.

Local-first Flutter label editor for the **AiYin/Fichero-protocol ORICO D110** thermal printer (classic Bluetooth SPP, 96-dot head). Text, QR codes, images, freehand drawing, tiled sticker stacks, camera media calibration, battery monitor, local templates. No accounts or telemetry.

- **Tested hardware:** ORICO / Temu-style D110 (firmware `V1.0.4`, USB `09c5:0200`). **NIIMBOT-protocol D110 is not supported.**
- **Downloads:** [Latest release](https://github.com/l4l4l4l4/d110-studio/releases/latest) (Linux AppImage, Android APK, Windows EXE — Windows installer is unsigned).
- **Build:** Flutter 3.41.9 (`nix develop` / `nix develop .#android`), `make check`, `make run`, `make apk`, `make appimage`, `make windows`.
- **Protocol:** [fichero-printer PROTOCOL.md](https://github.com/0xMH/fichero-printer/blob/main/docs/PROTOCOL.md)
- **Licensing:** No project-code license is currently granted. Bundled fonts are SIL OFL-1.1.
