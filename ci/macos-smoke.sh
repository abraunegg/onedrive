#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
binary=${ONEDRIVE_BIN:-"$repo_root/onedrive"}

if [ "$(uname -s)" != "Darwin" ] || [ ! -x "$binary" ]; then
	printf '%s\n' "macOS smoke test requires a built OneDrive CLI." >&2
	exit 1
fi

brew_prefix=$(brew --prefix)
export PATH="$brew_prefix/opt/ldc/bin:$brew_prefix/opt/curl/bin:$brew_prefix/opt/sqlite/bin:$brew_prefix/bin:$PATH"
export PKG_CONFIG_PATH="$brew_prefix/opt/curl/lib/pkgconfig:$brew_prefix/opt/sqlite/lib/pkgconfig:$brew_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

file_output=$(file "$binary")
printf '%s\n' "$file_output" | grep -q 'Mach-O.*arm64'
link_output=$(otool -L "$binary")
printf '%s\n' "$link_output" | grep -q 'libcurl'
printf '%s\n' "$link_output" | grep -q 'libsqlite3'
"$binary" --version >/dev/null
"$binary" --help 2>&1 | grep -q -- '--gui-browser-auth'

# The native device-code flow only supports Entra ID work/school accounts. It
# must not regress to the generic authority, which can bounce users back to the
# code-entry screen while transferring consumer-account authentication state.
grep -Fq 'tenantId = appConfig.getValueBool("gui_device_auth") ? "organizations" : "common";' "$repo_root/src/onedrive.d"
grep -Fq 'executeCLI(arguments: ["--gui-browser-auth"])' "$repo_root/contrib/macos/OneDriveApp.swift"
grep -Fq 'appConfig.getValueBool("gui_browser_auth") || shouldAttemptLocalBrowserAuth(appConfig)' "$repo_root/src/onedrive.d"
grep -A1 -Fq '<key>com.apple.security.network.server</key>' "$repo_root/contrib/macos/OneDrive.entitlements"
grep -Fq "Authentication complete" "$repo_root/src/localAuth.d"
grep -Fq "Content-Security-Policy: default-src 'none'" "$repo_root/src/localAuth.d"

app_source="$repo_root/contrib/macos/OneDriveApp.swift"
coordinator_source="$repo_root/contrib/macos/FileProvider/ProviderCoordinator.swift"
if grep -Eq 'resetExistingDomain|mode:[[:space:]]*\.removeAll' "$app_source" "$coordinator_source" || \
	grep -F 'NSFileProviderManager.remove' "$app_source" "$coordinator_source" | grep -Fqv 'mode: .preserveDownloadedUserData'; then
	printf '%s\n' "The macOS provider still contains a destructive domain removal path." >&2
	exit 1
fi
if grep -Eq 'azure_tenant_id = "organizations"|lines\[index\] = setting' \
	"$repo_root/contrib/macos/OneDriveApp.swift"; then
	printf '%s\n' "The macOS app still overwrites the configured tenant scope." >&2
	exit 1
fi
grep -Fq 'tenantID: values["azure_tenant_id"].flatMap' "$repo_root/contrib/macos/FileProvider/ProviderCoordinator.swift"
grep -Fq 'case .spaceSaver: return "Online only"' "$repo_root/contrib/macos/OneDriveApp.swift"
grep -Fq 'case .alwaysAvailable: return "Available offline"' "$repo_root/contrib/macos/OneDriveApp.swift"
grep -Fq 'stateTitle = node.providerError == nil' "$repo_root/contrib/macos/OneDriveApp.swift"
grep -Fq 'let itemID = location.id == "__all__" ? primaryRootID : location.id' "$repo_root/contrib/macos/OneDriveApp.swift"
smoke_root=$(mktemp -d "${TMPDIR:-/tmp}/onedrive-macos-smoke.XXXXXX")
mkdir -p "$smoke_root/config" "$smoke_root/sync"
version_import_root="$repo_root"
if [ ! -f "$repo_root/version" ]; then
	version_import_root="$smoke_root/generated"
	mkdir -p "$version_import_root"
	git describe --tags >"$version_import_root/version" 2>/dev/null || printf '%s\n' "v2.5.10" >"$version_import_root/version"
fi
"$binary" --confdir="$smoke_root/config" --syncdir="$smoke_root/sync" --display-config >"$smoke_root/display-config.txt"
grep -q "$smoke_root/sync" "$smoke_root/display-config.txt"

swiftc -typecheck \
	contrib/macos/OneDriveApp.swift \
	contrib/macos/FileProvider/ProviderShared.swift \
	contrib/macos/FileProvider/ProviderCoordinator.swift \
	-framework AppKit -framework FileProvider -framework Foundation -framework Security -framework ServiceManagement

swiftc -typecheck contrib/macos/FileProvider/*.swift \
	-framework Security -framework FileProvider -framework UniformTypeIdentifiers

harness="${TMPDIR:-/tmp}/onedrive-fileprovider-harness"
swiftc \
	contrib/macos/FileProvider/ProviderShared.swift \
	contrib/macos/FileProvider/GraphClient.swift \
	contrib/macos/FileProvider/ProviderState.swift \
	contrib/macos/FileProvider/ProviderItem.swift \
	ci/macos_fileprovider_harness.swift \
	-framework Security -framework FileProvider -framework UniformTypeIdentifiers -o "$harness"
"$harness"

plutil -lint \
	contrib/macos/Info.plist \
	contrib/macos/OneDrive.entitlements \
	contrib/macos/FileProvider/Info.plist \
	contrib/macos/FileProvider/OneDriveFileProvider.entitlements \
	contrib/macos/OneDrive.xcodeproj/project.pbxproj >/dev/null

grep -Fq 'Contents/MacOS/OneDrive"' contrib/macos/build-app.sh
grep -Fq 'CFBundleExecutable -string OneDrive' contrib/macos/build-app.sh

if [ -x /usr/bin/xcodebuild ] && [ "$(xcode-select -p 2>/dev/null)" != "/Library/Developer/CommandLineTools" ]; then
	derived_data="$smoke_root/XcodeDerivedData"
	xcodebuild -project contrib/macos/OneDrive.xcodeproj -scheme OneDrive -configuration Debug -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO build
	app="$derived_data/Build/Products/Debug/OneDrive.app"
	test -d "$app/Contents/PlugIns/OneDriveFileProvider.appex"
else
	printf '%s\n' "File Provider source contracts passed; full Xcode/signing build skipped."
fi

for url in \
	'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration' \
	'https://graph.microsoft.com/v1.0/$metadata' \
	'https://onedrive.live.com/'; do
	code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 10 --max-time 30 "$url")
	case "$code" in
		2??|3??|401|403) ;;
		*) printf '%s\n' "unexpected HTTP status $code from $url" >&2; exit 1 ;;
	esac
done

if pgrep -x onedrive >/dev/null 2>&1; then
	printf '%s\n' "A legacy OneDrive CLI process is running." >&2
	exit 1
fi
