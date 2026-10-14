#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${VERSION:-1.0.0}"
work="build/appimage"
mkdir -p "$work/tools" "$work/AppDir/usr/bin" dist
# Keep the Flutter executable beside its lib/ and data/ directories.
cp -a build/linux/x64/release/bundle/. "$work/AppDir/usr/bin/"
curl --fail --location --retry 3 'https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage' -o "$work/tools/linuxdeploy.AppImage"
printf '%s  %s\n' c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d "$work/tools/linuxdeploy.AppImage" | sha256sum --check
curl --fail --location --retry 3 'https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh' -o "$work/tools/linuxdeploy-plugin-gtk.sh"
printf '%s  %s\n' b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171 "$work/tools/linuxdeploy-plugin-gtk.sh" | sha256sum --check
chmod +x "$work/tools/"*
export APPIMAGE_EXTRACT_AND_RUN=1 DEPLOY_GTK_VERSION=3 ARCH=x86_64
export OUTPUT="$(pwd)/dist/D110-Studio-${version}-linux-x86_64.AppImage"
"$work/tools/linuxdeploy.AppImage" --appdir "$work/AppDir" \
  --executable "$work/AppDir/usr/bin/d110_studio" \
  --desktop-file packaging/d110-studio.desktop --icon-file packaging/d110-studio.svg \
  --plugin gtk --output appimage
