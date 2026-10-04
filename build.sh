#!/bin/zsh
# Build DeskPet.app từ dòng lệnh.
#   ./build.sh            → build/DeskPet.app (release)
#   ./build.sh debug      → bản debug
#   ./build.sh run        → build rồi mở app (bản trong build/)
#   ./build.sh install    → build, chép vào /Applications rồi mở bản đó
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
[[ "${1:-}" == "debug" ]] && CONFIG=debug
OPT=(-O); [[ $CONFIG == debug ]] && OPT=(-Onone -g)

APP=build/DeskPet.app
BIN_DIR=.build/direct
mkdir -p "$BIN_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Command Line Tools 16.3 có lỗi để thừa usr/include/swift/module.modulemap (trùng SwiftBridging)
# làm hỏng mọi `import AppKit`. Che file đó bằng VFS overlay thay vì sửa file hệ thống.
EXTRA=()
CLT_INC="$(xcode-select -p)/usr/include/swift"
if [[ -f "$CLT_INC/module.modulemap" && -f "$CLT_INC/bridging.modulemap" ]]; then
  mkdir -p .build/vfs
  : > .build/vfs/empty.modulemap
  cat > .build/vfs/overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false",
  "roots": [ { "type": "file", "name": "$CLT_INC/module.modulemap",
               "external-contents": "$PWD/.build/vfs/empty.modulemap" } ] }
EOF
  EXTRA=(-vfsoverlay .build/vfs/overlay.yaml -Xcc -ivfsoverlay -Xcc .build/vfs/overlay.yaml)
fi

# CLT có thể kèm SDK mới hơn compiler (vd SDK 26.x + Swift 6.1) → "this SDK is not supported by the compiler".
# Khi đó dùng SDK macOS 15 đi kèm, khớp với compiler.
if [[ -z "${SDKROOT:-}" ]]; then
  SWIFT_VER="$(swiftc --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
  SDK_VER="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
  SDK15="$(xcode-select -p)/SDKs/MacOSX15.sdk"
  if [[ "${SDK_VER%%.*}" -ge 26 && "$SWIFT_VER" < "6.2" && -d "$SDK15" ]]; then
    export SDKROOT="$SDK15"
    echo "▸ Swift $SWIFT_VER không hỗ trợ SDK $SDK_VER → dùng $SDKROOT"
  fi
fi

echo "▸ Compile ($CONFIG)"
swiftc -swift-version 5 "${OPT[@]}" -target "$(uname -m)-apple-macosx13.0" \
  "${EXTRA[@]}" -framework Carbon \
  -module-name DeskPet Sources/DeskPet/*.swift -o "$BIN_DIR/DeskPet"

echo "▸ Bundle"
cp "$BIN_DIR/DeskPet" "$APP/Contents/MacOS/DeskPet"
ditto Resources/Characters "$APP/Contents/Resources/Characters"

# Icon app từ ảnh Bé Nón
ICONSET=.build/DeskPet.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -Z $s Resources/Characters/be_non/cam_do.png --padToHeightWidth $s $s --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1 || true
  sips -Z $((s*2)) Resources/Characters/be_non/cam_do.png --padToHeightWidth $((s*2)) $((s*2)) --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "  (bỏ qua icon)"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DeskPet</string>
  <key>CFBundleDisplayName</key><string>DeskPet</string>
  <key>CFBundleIdentifier</key><string>com.deskpet.app</string>
  <key>CFBundleExecutable</key><string>DeskPet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>DeskPet nghe bạn nói khi bạn giữ ⌥ Space để ra lệnh cho trợ lý.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>DeskPet chuyển giọng nói của bạn thành chữ để gửi cho trợ lý.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (bỏ qua codesign)"
echo "✓ $APP"

if [[ "${1:-}" == "run" ]]; then
  pkill -x DeskPet 2>/dev/null || true
  open "$APP"
fi

if [[ "${1:-}" == "install" ]]; then
  pkill -x DeskPet 2>/dev/null || true
  sleep 1
  # ditto chép đè từng file vào bản cài sẵn (không xoá gì), rồi ký lại cho khớp nội dung mới.
  ditto "$APP" /Applications/DeskPet.app
  codesign --force --sign - /Applications/DeskPet.app >/dev/null 2>&1 || true
  # Bỏ cờ quarantine (nếu bản cài cũ có) để Gatekeeper không chặn "Apple could not verify…".
  xattr -dr com.apple.quarantine /Applications/DeskPet.app 2>/dev/null || true
  echo "✓ Đã cài /Applications/DeskPet.app"
  open /Applications/DeskPet.app
fi
