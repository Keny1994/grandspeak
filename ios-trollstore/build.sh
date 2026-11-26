#!/usr/bin/env bash
# Build GrandSpeak.ipa (ký giả ldid, dùng cho TrollStore). Chạy trên macOS có Xcode hoặc GitHub Actions.
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
  Sources/*.swift \
  -o "$BUNDLE/$APP"

cp Info.plist "$BUNDLE/Info.plist"
printf 'APPL????' > "$BUNDLE/PkgInfo"
for icon in Resources/AppIcon*.png; do
  if [ -f "$icon" ]; then
    cp "$icon" "$BUNDLE/"
  fi
done

if command -v ldid >/dev/null 2>&1; then
  ldid -SEntitlements.plist "$BUNDLE/$APP"
  echo "Đã ký giả (ldid)."
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
