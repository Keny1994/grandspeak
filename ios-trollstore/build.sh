#!/usr/bin/env bash
# Build GrandSpeak.ipa Độc lập 100% (Nhúng sẵn toàn bộ Web + Native Micro/TTS, ký giả ldid cho TrollStore).
set -euo pipefail
cd "$(dirname "$0")"

APP="GrandSpeak"
OUT="build"
BUNDLE="$OUT/$APP.app"

rm -rf "$OUT"
mkdir -p "$BUNDLE"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"

swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios14.5 \
  -module-name GrandSpeak \
  -O \
  -framework UIKit \
  -framework WebKit \
  -framework AVFoundation \
  -framework Speech \
  Sources/*.swift \
  -o "$BUNDLE/$APP"

cp Info.plist "$BUNDLE/Info.plist"
printf 'APPL????' > "$BUNDLE/PkgInfo"
for icon in Resources/AppIcon*.png; do
  if [ -f "$icon" ]; then
    cp "$icon" "$BUNDLE/"
  fi
done

if [ -d "Web" ]; then
  cp -R "Web" "$BUNDLE/Web"
  echo "Đã nhúng trọn bộ dữ liệu Web vào trong GrandSpeak.app/Web"
else
  echo "LỖI: Chưa có thư mục Web để nhúng vào IPA!" >&2
  exit 1
fi

if command -v ldid >/dev/null 2>&1; then
  ldid -SEntitlements.plist "$BUNDLE/$APP"
  echo "Đã ký giả (ldid) chuẩn TrollStore."
else
  echo "Không có ldid: TrollStore sẽ tự ký giả khi cài."
fi

mkdir -p "$OUT/Payload"
cp -R "$BUNDLE" "$OUT/Payload/"
if [ -f "Resources/iTunesArtwork" ]; then
  cp "Resources/iTunesArtwork" "$OUT/iTunesArtwork"
  (cd "$OUT" && zip -qry GrandSpeak.ipa Payload iTunesArtwork)
else
  (cd "$OUT" && zip -qry GrandSpeak.ipa Payload)
fi

lipo -info "$BUNDLE/$APP" || true
ls -lh "$OUT/GrandSpeak.ipa"
echo "XONG: $OUT/GrandSpeak.ipa"
