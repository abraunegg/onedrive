# OneDrive for macOS

The native app is a standalone Finder Files On-Demand client. Microsoft's OneDrive app is not required.

## Install

The end-user release is a notarized DMG:

1. Open `OneDrive-<version>-macOS.dmg`.
2. Drag **OneDrive** onto the **Applications** shortcut.
3. Eject the disk image and open OneDrive from Applications.
4. Continue with Microsoft, choose the folders and libraries to expose, then start Files On-Demand.

The first launch may ask macOS to allow the OneDrive File Provider extension. If Finder does not show OneDrive after setup, enable it in **System Settings → General → Login Items & Extensions → File Providers**, then reopen OneDrive. Do not run this app and Microsoft's OneDrive client against the same account and folders at the same time.

After Files On-Demand is configured, OneDrive registers itself to start when you log in. macOS exposes that registration in **System Settings → General → Login Items & Extensions**.

The current release supports macOS 13 or later on Apple silicon. Intel distribution requires a separately built x86_64 runtime or a universal runtime; the packager rejects an app whose architectures do not match its bundled runtime.

## Storage behavior

- Selected locations appear immediately as placeholders; listing folders does not download file bodies.
- Opening an online-only file asks Microsoft Graph for that file and materializes it through macOS File Provider.
- Folder metadata is kept available locally so the Finder hierarchy and the folder picker can reopen without rebuilding the tree from scratch. File bodies still follow the selected cache policy.
- The app offers three storage policies. **Online only** keeps metadata visible and downloads file contents on open. **Smart cache** downloads on open and lets macOS manage local space. **Available offline** downloads everything in the selected folder and keeps it available offline.
- The global default applies to all selected locations. Each folder can override it independently, or inherit the global default. Changing a policy does not delete remote files or silently remove an existing local mirror.
- The app never runs the legacy CLI `--sync` or `--monitor` path after provider setup.
- An existing `~/OneDrive` mirror is preserved and disclosed in the dashboard. Removing it is a separate manual decision.

## Repairing Finder

If Finder shows a stale, duplicated, or incomplete OneDrive location, choose **OneDrive → Repair Finder layout** from the menu bar. The repair re-registers the app's File Provider domain while preserving downloaded user data. It is safe to run after reinstalling or moving the app into `/Applications`.

The repair is guarded against concurrent provider changes and validates the current account and configuration before changing Finder. If registration fails, the previous provider domain and configuration are restored and the app reports that the existing files were kept. It does not delete remote OneDrive data.

For local diagnostics, the same action can be requested with:

```text
/Applications/OneDrive.app/Contents/MacOS/OneDrive --repair-finder-layout
```

The command requires an authenticated setup with at least one saved location.

## Build requirements

The source contract harness runs with Apple Command Line Tools:

```sh
./ci/macos-smoke.sh
```

Installing the Finder extension requires full Xcode, an Apple signing identity, and these capabilities on both targets:

- App Group: `group.org.onedrive.cli.macos`
- Keychain group: `$(AppIdentifierPrefix)org.onedrive.cli.macos.shared`
- App Sandbox and outbound network access

The app-icon build also requires ImageMagick and librsvg (`brew install imagemagick librsvg`). librsvg preserves the gradients in the bundled OneDrive SVG when producing the macOS icon set.

Open `contrib/macos/OneDrive.xcodeproj`, select a development team for both targets, build the `OneDrive` scheme, and launch the host app once to register the domain.

`contrib/macos/build-app.sh` automatically uses `ONEDRIVE_DEVELOPMENT_TEAM`, or the first local Apple signing identity when the variable is unset. This produces a local development build, not an end-user release.

## Release DMG

Distribution outside the Mac App Store requires Apple Developer Program membership, Developer ID Application signing, provisioning profiles for both bundle identifiers and their App Group/Keychain capabilities, hardened runtime, and Apple notarization. A development-signed or ad-hoc app will be rejected on another Mac.

After exporting a Developer ID-signed `OneDrive.app` from Xcode, store notarization credentials once:

```sh
xcrun notarytool store-credentials onedrive-notary
```

Then package, notarize, and staple the drag-to-Applications DMG:

```sh
ONEDRIVE_NOTARY_PROFILE=onedrive-notary \
  contrib/macos/package-dmg.sh --app /path/to/export/OneDrive.app
```

For a local installer test only, without notarization:

```sh
contrib/macos/package-dmg.sh --development
```

The release packager refuses to create a distributable DMG unless the app has a Developer ID signature and a notarization profile is supplied.

## First-install checks

Before publishing, test on a Mac account that has never run this app:

- Gatekeeper opens the app without using **Open Anyway**.
- Microsoft sign-in succeeds for the advertised account type. The bundled device-code flow currently supports work/school accounts; personal Microsoft accounts require a Microsoft-approved application registration.
- macOS activates the File Provider and OneDrive appears once in Finder.
- Folder metadata appears before file bodies download.
- Opening an online-only file downloads it; creating, editing, renaming, moving, and deleting a disposable file reaches Microsoft Graph.
- Keep offline and cache-policy changes survive an app restart.
- Relaunching the app does not create a second File Provider domain.
- Removing the app does not silently delete remote files or the preserved legacy mirror.

## Safety gate

Before enabling the provider for irreplaceable production content, verify create, edit, rename, move, delete, conflict, cancellation, placeholder hydration, and Keep offline behavior in a disposable Microsoft 365 folder. Provider setup does not delete or evict any existing local data.
