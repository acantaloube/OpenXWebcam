#!/bin/bash
# Build patched OpenXWebcam without Xcode, using swiftc/clang from Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
INC="$PWD/CameraEngine/Sources/CPTPTransport/include"
OUT="$PWD/buildout"
TARGET=arm64-apple-macosx14.0
rm -rf "$OUT"; mkdir -p "$OUT"

[ -f "$INC/module.modulemap" ] || cat > "$INC/module.modulemap" <<'MM'
module CPTPTransport {
    header "PTPUSBTransport.h"
    header "PTPUSBWatcher.h"
    export *
}
MM

echo "[1/4] ObjC USB transport"
for m in CameraEngine/Sources/CPTPTransport/*.m; do
  clang -c -O2 -fobjc-arc -isysroot "$SDK" -target arm64-apple-macos14.0 \
    -I "$INC" "$m" -o "$OUT/$(basename "$m" .m).o"
done

echo "[2/4] CameraEngine"
swiftc -O -emit-module -emit-library -static -module-name CameraEngine \
  -emit-module-path "$OUT/CameraEngine.swiftmodule" -o "$OUT/libCameraEngine.a" \
  -sdk "$SDK" -target "$TARGET" -I "$INC" \
  -Xcc -fmodule-map-file="$INC/module.modulemap" \
  CameraEngine/Sources/CameraEngine/*.swift 2>&1 | grep -E "error:" || true

echo "[3/4] app binary"
swiftc -O -o "$OUT/OpenXWebcam" -sdk "$SDK" -target "$TARGET" \
  -I "$OUT" -I "$INC" -Xcc -fmodule-map-file="$INC/module.modulemap" \
  Apps/OpenXWebcam/App/*.swift \
  "$OUT/libCameraEngine.a" "$OUT"/PTPUSBTransport.o "$OUT"/PTPUSBWatcher.o \
  -framework Foundation -framework AppKit -framework SwiftUI \
  -framework CoreMediaIO -framework CoreMedia -framework CoreVideo \
  -framework ImageIO -framework CoreGraphics -framework IOKit \
  -framework IOUSBHost -framework ServiceManagement -framework SystemExtensions \
  2>&1 | grep -E "error:" || true
[ -f "$OUT/OpenXWebcam" ] || { echo "build failed" >&2; exit 1; }

echo "[4/4] app bundle"
APP="$OUT/OpenXWebcam.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/OpenXWebcam" "$APP/Contents/MacOS/OpenXWebcam"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>OpenXWebcam</string>
	<key>CFBundleIdentifier</key><string>com.openxwebcam.app</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>OpenXWebcam</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0-xt3</string>
	<key>CFBundleVersion</key><string>3</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSCameraUsageDescription</key><string>OpenXWebcam feeds video from your Fujifilm camera into its virtual camera.</string>
</dict>
</plist>
PL
codesign --force --sign - "$APP" 2>/dev/null
echo
echo "Built $APP"
echo "Run with log:  OPENXWEBCAM_LOG=1 $APP/Contents/MacOS/OpenXWebcam"
