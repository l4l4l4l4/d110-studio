# D110 Studio

Local-first Flutter label editor for the ORICO-branded D110 tested with firmware V1.0.4. This revision speaks AiYin/Fichero raster commands, not the NIIMBOT protocol.

## Scope

Android Bluetooth printing; text, QR codes and images; element positioning and rotation; monochrome preview, thresholding, dithering and edge detection. No accounts, network services or firmware modifications.

## Device evidence

The tested device identifies as D110, Bluetooth name D110_B818, USB 09c5:0200. Printing with a 96-dot head and density 2 was physically confirmed over USB. Classic Bluetooth RFCOMM channel 1 answered the same read-only protocol queries. Android printing must be separately verified on the phone.

Protocol reference: https://github.com/0xMH/fichero-printer/blob/main/docs/PROTOCOL.md

Hardware identity, flash readout and onboard sound hardware remain unconfirmed. Do not send firmware update, erase or factory-reset commands.
