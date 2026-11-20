# Cinnamon panel applet

The optional **OneDrive Status** applet adds a status menu to a Cinnamon panel. It displays the running monitor state, the latest cycle outcome and transfer-failure counts, OneDrive reachability, the linked account name and email when Microsoft provides them, and usage bars for the local filesystem and OneDrive quota when those capacities are available.

The applet consumes the monitor's existing `monitor-status.json` file. It does not start another OneDrive client process to read state, open the synchronisation database, or make Microsoft Graph requests. Cloud quota and account details are therefore snapshots from the running monitor; when the monitor is stopped, those details are unavailable. The applet checks the monitor process before treating a leftover status file as live.

`monitor-status.json` is written with restrictive permissions and includes account identity and the configured sync-directory path for this local presentation. The applet reads it as the same user who runs the monitor. Do not make the status file world-readable.

## Install

The applet requires Cinnamon 6.0 or later and the OneDrive client. From the configured source tree, run:

```text
make install-cinnamon-applet
```

The target installs to `$(datadir)/cinnamon/applets/onedrive-status@abraunegg` (normally `/usr/local/share/cinnamon/applets/onedrive-status@abraunegg`). Override the location if needed:

```text
make install-cinnamon-applet CINNAMON_APPLET_DIR=/usr/share/cinnamon/applets/onedrive-status@abraunegg
```

Then open **System Settings → Applets**, select **OneDrive Status**, and add it to a panel. Start the client in `--monitor` mode using the normal method for your installation.

For a non-default configuration directory, open the applet settings and set **Monitor status file** to the `monitor-status.json` path shown by `onedrive --display-running-config`. Leave the setting empty to use `$XDG_CONFIG_HOME/onedrive/monitor-status.json` (normally `~/.config/onedrive/monitor-status.json`).

## Status semantics

The menu reports whether the monitor is synchronising, idle, or needs attention, plus the outcome and failure counts of the last scheduled cycle. “Synchronising” reports monitor activity; it does not identify an individual file, and the failure counts do not include detailed error messages. **Idle and a successful cycle are operational status, not proof that local and remote contents are currently converged.** Use `onedrive --display-sync-status` for a separate point-in-time convergence assessment.

The cloud usage bar uses the quota's actual `used` and `total` values returned by OneDrive; it does not assume a fixed 1 TB limit. Quota may be unavailable for accounts or drives that do not expose it. Local usage is queried from the filesystem containing `sync_dir`; it is not a recursive size calculation of the files in the folder.

When the `onedrive.service` user unit is installed, the menu offers **Start OneDrive service** while it is stopped and **Stop OneDrive service** while it is running. The applet reports systemd errors in the menu. For a manually started monitor, it instead offers to send `SIGTERM` only to the verified monitor PID so the client can perform its normal shutdown; it cannot start a manually managed monitor. If status publishing is disabled, it can start or stop the systemd-managed service but will not guess which manually started process to terminate. It does not force-kill a process or stop a different OneDrive monitor managed by another unit.

Remove the applet through Cinnamon's Applets settings, or remove its installed files with:

```text
make uninstall-cinnamon-applet
```
