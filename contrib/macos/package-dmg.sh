#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
app="$repo_root/build/OneDrive.app"
background="$script_dir/Assets/dmg-background.png"
output=""
development=0

usage() {
	printf '%s\n' "Usage: $0 [--app PATH] [--output PATH] [--development]" >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--app)
			[ "$#" -ge 2 ] || usage
			app=$2
			shift 2
			;;
		--output)
			[ "$#" -ge 2 ] || usage
			output=$2
			shift 2
			;;
		--development)
			development=1
			shift
			;;
		-h|--help)
			usage
			;;
		*)
			usage
			;;
	esac
done

[ -d "$app" ] || {
	printf '%s\n' "OneDrive.app was not found at: $app" >&2
	printf '%s\n' "Build it first with contrib/macos/build-app.sh." >&2
	exit 1
}
[ -f "$background" ] || {
	printf '%s\n' "DMG background was not found at: $background" >&2
	exit 1
}

codesign --verify --deep --strict "$app"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
app_executable="$app/Contents/MacOS/$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
runtime="$app/Contents/Resources/onedrive"
file_provider="$app/Contents/PlugIns/OneDriveFileProvider.appex"
[ -x "$runtime" ] || {
	printf '%s\n' "The app is missing its bundled OneDrive runtime." >&2
	exit 1
}
if ! "$runtime" --help 2>&1 | grep -q -- '--gui-browser-auth'; then
	printf '%s\n' "The app contains a stale OneDrive runtime without browser sign-in support." >&2
	exit 1
fi
[ -d "$file_provider" ] || {
	printf '%s\n' "The app is missing its File Provider extension." >&2
	exit 1
}
app_architectures=$(lipo -archs "$app_executable")
runtime_architectures=$(lipo -archs "$runtime")
for architecture in $app_architectures; do
	case " $runtime_architectures " in
		*" $architecture "*) ;;
		*)
			printf '%s\n' "The app supports $architecture but its bundled runtime does not." >&2
			exit 1
			;;
	esac
done
case "$runtime_architectures" in
	"arm64 x86_64"|"x86_64 arm64") architecture_label=universal ;;
	*) architecture_label=$(printf '%s' "$runtime_architectures" | tr ' ' '-') ;;
esac
[ -n "$output" ] || {
	output_suffix=""
	[ "$development" -eq 0 ] || output_suffix="-development"
	output="$repo_root/build/OneDrive-$app_version-macOS-$architecture_label$output_suffix.dmg"
}
mkdir -p "$(dirname -- "$output")"

signing_authority=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*$\)/\1/p' | sed -n '1p')
team_identifier=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | sed -n '1p')
file_provider_team_identifier=$(codesign -dv --verbose=4 "$file_provider" 2>&1 | sed -n 's/^TeamIdentifier=//p' | sed -n '1p')
if [ "$development" -eq 0 ]; then
	[ -n "$signing_authority" ] || {
		printf '%s\n' "Release packaging requires a Developer ID Application-signed app." >&2
		printf '%s\n' "The current app is only suitable for local development." >&2
		exit 1
	}
	[ -n "${ONEDRIVE_NOTARY_PROFILE:-}" ] || {
		printf '%s\n' "Set ONEDRIVE_NOTARY_PROFILE to an xcrun notarytool keychain profile." >&2
		exit 1
	}
else
	[ -n "$team_identifier" ] && [ "$team_identifier" != "not set" ] && [ "$team_identifier" = "$file_provider_team_identifier" ] || {
		printf '%s\n' "Development packaging requires an Apple Development-signed app and File Provider extension from the same team." >&2
		printf '%s\n' "Ad-hoc preview builds cannot install Files On-Demand." >&2
		exit 1
	}
	[ -f "$app/Contents/embedded.provisionprofile" ] && [ -f "$file_provider/Contents/embedded.provisionprofile" ] || {
		printf '%s\n' "The development app or its File Provider extension is missing a provisioning profile." >&2
		exit 1
	}
fi

package_work=$(mktemp -d "${TMPDIR:-/tmp}/onedrive-dmg.XXXXXX")
mount_point=""
cleanup() {
	if [ -n "$mount_point" ] && mount | grep -Fq "on $mount_point "; then
		hdiutil detach "$mount_point" -quiet || hdiutil detach "$mount_point" -force -quiet || true
	fi
	rm -rf "$package_work"
}
trap cleanup EXIT HUP INT TERM

stage="$package_work/stage"
mkdir -p "$stage/.background"
ditto "$app" "$stage/OneDrive.app"
ditto "$background" "$stage/.background/background.png"
ln -s /Applications "$stage/Applications"

volume_name="OneDrive Installer"
read_write_dmg="$package_work/OneDrive-read-write.dmg"
mount_point="$package_work/mount"
rm -f "$output"
hdiutil create \
	-volname "$volume_name" \
	-srcfolder "$stage" \
	-fs HFS+ \
	-format UDRW \
	-ov "$read_write_dmg" >/dev/null
attach_output=$(hdiutil attach -nobrowse -readwrite "$read_write_dmg")
mount_point=$(printf '%s\n' "$attach_output" | sed -n 's#^.*	\(/Volumes/.*\)$#\1#p' | sed -n '1p')
[ -n "$mount_point" ] || {
	printf '%s\n' "Could not locate the mounted DMG volume." >&2
	exit 1
}

osascript \
	-e 'tell application "Finder"' \
	-e 'tell disk "OneDrive Installer"' \
	-e 'open' \
	-e 'set current view of container window to icon view' \
	-e 'set toolbar visible of container window to false' \
	-e 'set statusbar visible of container window to false' \
	-e 'set pathbar visible of container window to false' \
	-e 'set bounds of container window to {100, 100, 760, 589}' \
	-e 'set theViewOptions to icon view options of container window' \
	-e 'set arrangement of theViewOptions to not arranged' \
	-e 'set icon size of theViewOptions to 112' \
	-e 'set text size of theViewOptions to 13' \
	-e 'set background picture of theViewOptions to file ".background:background.png"' \
	-e 'set position of item "OneDrive.app" of container window to {180, 245}' \
	-e 'set position of item "Applications" of container window to {480, 245}' \
	-e 'update without registering applications' \
	-e 'delay 1' \
	-e 'close container window' \
	-e 'end tell' \
	-e 'end tell'

sync
hdiutil detach "$mount_point" -quiet
mount_point=""
hdiutil convert "$read_write_dmg" \
	-format UDZO \
	-imagekey zlib-level=9 \
	-o "$output" >/dev/null
hdiutil verify "$output" >/dev/null

if [ "$development" -eq 1 ]; then
	printf '%s\n' "Created development-only DMG: $output"
	printf '%s\n' "It is not notarized and must not be distributed." >&2
	exit 0
fi

codesign --force --timestamp --sign "$signing_authority" "$output"
xcrun notarytool submit "$output" --keychain-profile "$ONEDRIVE_NOTARY_PROFILE" --wait
xcrun stapler staple "$output"
xcrun stapler validate "$output"
spctl -a -t open --context context:primary-signature "$output"

printf '%s\n' "Created notarized DMG: $output"
