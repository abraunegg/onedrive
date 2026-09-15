#!/bin/sh
set -eu

resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
iconset="$DERIVED_FILE_DIR/AppIcon.iconset"
logo_png="$DERIVED_FILE_DIR/OneDriveLogo.png"
mkdir -p "$resources" "$frameworks" "$iconset"

cp "$SRCROOT/../../onedrive" "$resources/onedrive"
cp "$SRCROOT/../images/onedrive.svg" "$resources/OneDriveLogo.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  printf '%s\n' "rsvg-convert is required to render the OneDrive gradient artwork." >&2
  exit 1
fi
rsvg-convert --width 1024 --output "$logo_png" "$SRCROOT/../images/onedrive.svg"

for spec in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'
do
  set -- $spec
  size=$1
  name=$2
  cloud=$((size * 84 / 100))
  magick -size "${size}x${size}" xc:none \
    \( "$logo_png" -resize "${cloud}x${cloud}" \) \
    -gravity center -compose over -composite "$iconset/$name"
done

iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
magick -background none "$logo_png" -resize 14x9 -gravity center -extent 18x18 "$resources/MenuBarIcon.png"
magick -background none "$logo_png" -resize 28x18 -gravity center -extent 36x36 "$resources/MenuBarIcon@2x.png"

# App Sandbox cannot load Homebrew libraries from /opt/homebrew. Copy every
# non-system dependency into the app and rewrite the Mach-O load commands.
while :; do
  added=0
  for binary in "$resources/onedrive" "$frameworks"/*.dylib; do
    [ -f "$binary" ] || continue
    for dependency in $(otool -L "$binary" | awk 'NR > 1 { print $1 }'); do
      case "$dependency" in
        /opt/homebrew/*)
          name=$(basename "$dependency")
          bundled="$frameworks/$name"
          if [ ! -f "$bundled" ]; then
            cp "$dependency" "$bundled"
            chmod u+w "$bundled"
            install_name_tool -id "@rpath/$name" "$bundled"
            added=1
          fi
          install_name_tool -change "$dependency" "@loader_path/../Frameworks/$name" "$binary"
          ;;
        @loader_path/*|@rpath/*)
          name=$(basename "$dependency")
          [ "$(basename "$binary")" = "$name" ] && continue
          source=$(find -L /opt/homebrew/opt -path "*/lib/$name" -print -quit)
          [ -n "$source" ] || continue
          bundled="$frameworks/$name"
          if [ ! -f "$bundled" ]; then
            cp "$source" "$bundled"
            chmod u+w "$bundled"
            install_name_tool -id "@rpath/$name" "$bundled"
            added=1
          fi
          install_name_tool -change "$dependency" "@loader_path/../Frameworks/$name" "$binary"
          ;;
      esac
    done
  done
  [ "$added" -eq 1 ] || break
done

if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  for library in "$frameworks"/*.dylib; do
    [ -f "$library" ] || continue
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$library"
  done
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$resources/onedrive"
fi
