#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
output_app="$repo_root/build/OneDrive.app"
icon_source="$repo_root/contrib/images/onedrive.svg"

if [ ! -x "$repo_root/onedrive" ]; then
	printf '%s\n' "Build the CLI first with: make" >&2
	exit 1
fi
if ! "$repo_root/onedrive" --help 2>&1 | grep -q -- '--gui-browser-auth'; then
	printf '%s\n' "The CLI is stale and cannot perform native browser sign-in. Rebuild it with: make" >&2
	exit 1
fi

developer_dir=$(xcode-select -p 2>/dev/null || true)
if [ -x /usr/bin/xcodebuild ] && [ "$developer_dir" != "/Library/Developer/CommandLineTools" ]; then
	derived_data="$repo_root/build/XcodeDerivedData"
	signing_team=${ONEDRIVE_DEVELOPMENT_TEAM:-}
	if [ -z "$signing_team" ] && command -v security >/dev/null 2>&1; then
		signing_team=$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*\(([A-Z0-9]{10})\)"$/\1/p' | sed -n '1p')
	fi
	if [ -z "$signing_team" ]; then
		printf '%s\n' "Set ONEDRIVE_DEVELOPMENT_TEAM or install an Apple Development signing identity." >&2
		exit 1
	fi
	xcodebuild -project "$script_dir/OneDrive.xcodeproj" -scheme OneDrive -configuration Release -derivedDataPath "$derived_data" -allowProvisioningUpdates DEVELOPMENT_TEAM="$signing_team" build
	built_app="$derived_data/Build/Products/Release/OneDrive.app"
	test -d "$built_app/Contents/PlugIns/OneDriveFileProvider.appex"
	if ! "$built_app/Contents/Resources/onedrive" --help 2>&1 | grep -q -- '--gui-browser-auth'; then
		printf '%s\n' "The built app contains a stale OneDrive runtime without browser sign-in support." >&2
		exit 1
	fi
	codesign --verify --deep --strict "$built_app"
	rm -rf "$output_app"
	ditto "$built_app" "$output_app"
	codesign --verify --deep --strict "$output_app"
	printf '%s\n' "$output_app"
	exit 0
fi

if [ "${ONEDRIVE_HOST_PREVIEW:-0}" != "1" ]; then
	printf '%s\n' "Full Xcode and an App Group-capable signing identity are required to build the Files On-Demand app." >&2
	printf '%s\n' "For UI-only development, run with ONEDRIVE_HOST_PREVIEW=1." >&2
	exit 1
fi

build_work=$(mktemp -d "${TMPDIR:-/tmp}/onedrive-app.XXXXXX")
trap 'rm -rf "$build_work"' EXIT HUP INT TERM
app_dir="$build_work/OneDrive.app"
icon_work="$build_work/icon"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

if ! command -v magick >/dev/null 2>&1; then
	printf '%s\n' "ImageMagick is required to build the macOS app icon." >&2
	exit 1
fi
if ! command -v rsvg-convert >/dev/null 2>&1; then
	printf '%s\n' "librsvg is required to render the macOS app icon." >&2
	exit 1
fi
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$iconset"
rsvg-convert --width 1024 --output "$icon_work/OneDrive.png" "$icon_source"
cp "$icon_work/OneDrive.png" "$app_dir/Contents/Resources/OneDriveLogo.png"

render_icon() {
	name=$1
	size=$2
	cloud_width=$((size * 84 / 100))
	magick -size "${size}x${size}" xc:none \
		\( "$icon_work/OneDrive.png" -resize "${cloud_width}x${cloud_width}" \) \
		-gravity center -compose over -composite "$iconset/$name"
}

render_icon icon_16x16.png 16
render_icon icon_16x16@2x.png 32
render_icon icon_32x32.png 32
render_icon icon_32x32@2x.png 64
render_icon icon_128x128.png 128
render_icon icon_128x128@2x.png 256
render_icon icon_256x256.png 256
render_icon icon_256x256@2x.png 512
render_icon icon_512x512.png 512
render_icon icon_512x512@2x.png 1024
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
magick -background none "$icon_work/OneDrive.png" -resize 14x9 -gravity center -extent 18x18 "$app_dir/Contents/Resources/MenuBarIcon.png"
magick -background none "$icon_work/OneDrive.png" -resize 28x18 -gravity center -extent 36x36 "$app_dir/Contents/Resources/MenuBarIcon@2x.png"

swiftc "$script_dir/OneDriveApp.swift" \
	"$script_dir/FileProvider/ProviderShared.swift" \
	"$script_dir/FileProvider/ProviderCoordinator.swift" \
	-o "$app_dir/Contents/MacOS/OneDrive" \
	-framework AppKit \
	-framework FileProvider \
	-framework Foundation \
	-framework Security \
	-framework ServiceManagement \
	-O

cp "$repo_root/onedrive" "$app_dir/Contents/Resources/onedrive"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleExecutable -string OneDrive "$app_dir/Contents/Info.plist"
plutil -replace OneDriveAppGroupIdentifier -string org.onedrive.cli.macos "$app_dir/Contents/Info.plist"
plutil -replace OneDriveKeychainAccessGroup -string org.onedrive.cli.macos.shared "$app_dir/Contents/Info.plist"
chmod +x "$app_dir/Contents/MacOS/OneDrive" "$app_dir/Contents/Resources/onedrive"

if command -v codesign >/dev/null 2>&1; then
	if command -v xattr >/dev/null 2>&1; then
		xattr -cr "$app_dir"
		xattr -dr com.apple.provenance "$app_dir" 2>/dev/null || true
		xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
		xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
	fi
	codesign --force --deep --sign - "$app_dir" >/dev/null
	# Finder / File Provider metadata can be added back while the bundle is
	# created under a user Documents directory. It is not part of the app and
	# makes strict signature verification fail, so remove it after signing too.
	if command -v xattr >/dev/null 2>&1; then
		xattr -cr "$app_dir"
		xattr -dr com.apple.provenance "$app_dir" 2>/dev/null || true
		xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
		xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
	fi
fi

rm -rf "$output_app"
ditto "$app_dir" "$output_app"
if command -v xattr >/dev/null 2>&1; then
	xattr -cr "$output_app"
	xattr -dr com.apple.provenance "$output_app" 2>/dev/null || true
	xattr -d com.apple.FinderInfo "$output_app" 2>/dev/null || true
	xattr -d 'com.apple.fileprovider.fpfs#P' "$output_app" 2>/dev/null || true
fi

printf '%s\n' "$output_app"
