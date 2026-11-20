const Applet = imports.ui.applet;
const PopupMenu = imports.ui.popupMenu;
const Settings = imports.ui.settings;
const ByteArray = imports.byteArray;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const St = imports.gi.St;

function formatBytes(bytes) {
    let value = Number(bytes);
    if (!Number.isFinite(value) || value < 0) {
        return "Unavailable";
    }

    const units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit++;
    }
    return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function localTime(isoTimestamp) {
    if (!isoTimestamp) {
        return "Not available";
    }
    const dateTime = GLib.DateTime.new_from_iso8601(isoTimestamp, null);
    return dateTime ? dateTime.to_local().format("%x %X") : "Not available";
}

class OneDriveStatusApplet extends Applet.IconApplet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);
        this.uuid = metadata.uuid;
        this._statusFile = "";
        this._actionMessage = "";
        this._serviceActionInProgress = false;
        this._serviceQueryInProgress = false;
        this._serviceLoadState = "unknown";
        this._serviceActiveState = "unknown";
        this._serviceMainPid = 0;
        this._serviceError = "";
        this._removed = false;

        this.set_applet_icon_name("onedrive-notifications");
        this.set_applet_tooltip("OneDrive synchronisation status");

        this._menu = new Applet.AppletPopupMenu(this, orientation);
        this._menuManager = new PopupMenu.PopupMenuManager(this);
        this._menuManager.addMenu(this._menu);

        this.settings = new Settings.AppletSettings(this, this.uuid, instanceId);
        this.settings.bind("status-file", "_statusFile", this._refresh.bind(this), null);

        this._refresh();
        this._refreshTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            this._refresh();
            this._queryServiceState();
            return GLib.SOURCE_CONTINUE;
        });
        this._queryServiceState();
    }

    on_applet_clicked() {
        this._refresh();
        this._menu.toggle();
    }

    on_applet_removed_from_panel() {
        this._removed = true;
        if (this._refreshTimer !== null) {
            GLib.source_remove(this._refreshTimer);
            this._refreshTimer = null;
        }
        this.settings.finalize();
    }

    _statusPath() {
        let path = this._statusFile.trim();
        if (path === "") {
            return GLib.build_filenamev([
                GLib.get_user_config_dir(),
                "onedrive",
                "monitor-status.json"
            ]);
        }
        if (path === "~") {
            return GLib.get_home_dir();
        }
        if (path.startsWith("~/")) {
            return GLib.build_filenamev([GLib.get_home_dir(), path.substring(2)]);
        }
        return path;
    }

    _readStatus() {
        const path = this._statusPath();
        if (!GLib.file_test(path, GLib.FileTest.EXISTS)) {
            return null;
        }
        const [success, contents] = GLib.file_get_contents(path);
        if (!success) {
            throw new Error("status file could not be read");
        }
        return JSON.parse(ByteArray.toString(contents));
    }

    _monitorProcessState(status) {
        const pid = Number(status.pid);
        if (!Number.isInteger(pid) || pid <= 0) {
            return "unavailable";
        }

        try {
            const [success, contents] = GLib.file_get_contents(`/proc/${pid}/cmdline`);
            if (!success) {
                return "stopped";
            }
            const argumentsList = [];
            let argumentStart = 0;
            for (let index = 0; index <= contents.length; index++) {
                if (index === contents.length || contents[index] === 0) {
                    if (index > argumentStart) {
                        // ByteArray.toString truncates at NUL, so decode each /proc argument separately.
                        argumentsList.push(ByteArray.toString(contents.slice(argumentStart, index)));
                    }
                    argumentStart = index + 1;
                }
            }
            const executable = argumentsList.length > 0
                ? argumentsList[0].split("/").pop()
                : "";
            const running = executable.endsWith("onedrive") &&
                argumentsList.slice(1).some(argument => argument === "--monitor" || argument === "-m");
            return running ? "running" : "stopped";
        } catch (error) {
            return `error: ${error.message}`;
        }
    }

    _queryServiceState() {
        if (this._removed || this._serviceQueryInProgress) {
            return;
        }
        this._serviceQueryInProgress = true;

        let queryProcess;
        try {
            queryProcess = Gio.Subprocess.new(
                ["systemctl", "--user", "show", "onedrive.service",
                    "--property=LoadState", "--property=ActiveState", "--property=MainPID"],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
        } catch (error) {
            this._serviceQueryInProgress = false;
            this._serviceError = `Unable to run systemctl: ${error.message}`;
            this._refresh();
            return;
        }

        queryProcess.communicate_utf8_async(null, null, (process, result) => {
            this._serviceQueryInProgress = false;
            if (this._removed) {
                return;
            }
            try {
                const [, stdout, stderr] = process.communicate_utf8_finish(result);
                if (!process.get_successful()) {
                    throw new Error(stderr.trim() || "systemctl query failed");
                }

                const properties = new Map(stdout.trim().split("\n").map(line => {
                    const separator = line.indexOf("=");
                    return separator < 0
                        ? [line.trim(), ""]
                        : [line.slice(0, separator).trim(), line.slice(separator + 1).trim()];
                }));
                if (!properties.has("LoadState") || !properties.has("ActiveState") ||
                    !properties.has("MainPID")) {
                    throw new Error("systemctl returned an incomplete service state");
                }
                this._serviceLoadState = properties.get("LoadState");
                this._serviceActiveState = properties.get("ActiveState");
                this._serviceMainPid = Number(properties.get("MainPID")) || 0;
                this._serviceError = "";
            } catch (error) {
                this._serviceLoadState = "unknown";
                this._serviceActiveState = "unknown";
                this._serviceMainPid = 0;
                this._serviceError = `Unable to query OneDrive service: ${error.message}`;
            }
            this._refresh();
        });
    }

    _localStorageUsage(syncDirectory) {
        if (!syncDirectory) {
            return null;
        }
        try {
            const file = Gio.File.new_for_path(syncDirectory);
            const info = file.query_filesystem_info("filesystem::size,filesystem::free", null);
            const total = info.get_attribute_uint64("filesystem::size");
            const free = info.get_attribute_uint64("filesystem::free");
            return {used: Math.max(0, total - free), total, free};
        } catch (error) {
            global.logError(`OneDrive Status: unable to query local filesystem capacity: ${error.message}`);
            return null;
        }
    }

    _addUsageBar(label, usedBytes, totalBytes, freeBytes) {
        const used = Number(usedBytes);
        const total = Number(totalBytes);
        const free = Number(freeBytes);
        if (!Number.isFinite(used) || !Number.isFinite(total) ||
            !Number.isFinite(free) || used < 0 || total <= 0 || free < 0) {
            this._addLine(`${label}: Usage unavailable`);
            return;
        }

        const percentage = used / total * 100;
        const ratio = Math.max(0, Math.min(1, percentage / 100));
        const width = 240;
        const fillWidth = ratio === 0 ? 0 : Math.max(1, Math.round(width * ratio));
        const fillColour = percentage >= 95 ? "#d9534f"
            : percentage >= 80 ? "#d99a2b"
            : "#4f9fe8";
        const item = new PopupMenu.PopupBaseMenuItem({reactive: false});
        const content = new St.BoxLayout({
            vertical: true,
            style: "spacing: 4px; padding: 4px 0;"
        });
        const summary = new St.Label({
            text: `${label}: ${formatBytes(used)} / ${formatBytes(total)} used ` +
                `(${percentage.toFixed(1)}%; ${formatBytes(free)} free)`
        });
        const track = new St.BoxLayout({
            style: `background-color: rgba(128, 128, 128, 0.3); border-radius: 4px; ` +
                `height: 8px; width: ${width}px;`
        });
        const fill = new St.Widget({
            style: `background-color: ${fillColour}; border-radius: 4px; ` +
                `height: 8px; width: ${fillWidth}px;`
        });

        track.add_child(fill);
        content.add_child(summary);
        content.add_child(track);
        item.addActor(content, {span: -1, expand: true});
        this._menu.addMenuItem(item);
    }

    _stopMonitor(status) {
        if (this._serviceActionInProgress) {
            return;
        }
        this._serviceActionInProgress = true;
        this._actionMessage = "Stopping OneDrive monitor...";
        this._refresh();

        let queryProcess;
        try {
            queryProcess = Gio.Subprocess.new(
                ["systemctl", "--user", "show", "onedrive.service", "--property=MainPID", "--value"],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
        } catch (error) {
            this._stopMonitorPid(status, `Unable to run systemctl: ${error.message}`);
            return;
        }

        queryProcess.communicate_utf8_async(null, null, (process, result) => {
            let stdout = "";
            let stderr = "";
            try {
                [, stdout, stderr] = process.communicate_utf8_finish(result);
                if (!process.get_successful()) {
                    this._stopMonitorPid(status, `Unable to query systemd unit: ${stderr.trim() || "command failed"}`);
                    return;
                }
            } catch (error) {
                this._stopMonitorPid(status, `Unable to query systemd unit: ${error.message}`);
                return;
            }

            const servicePid = Number(stdout.trim());
            if (status === null && this._monitorProcessState({pid: servicePid}) === "running") {
                this._stopSystemdService(null);
            } else if (status !== null && servicePid === Number(status.pid)) {
                this._stopSystemdService(status);
            } else {
                this._stopMonitorPid(status, "systemd unit does not own this monitor");
            }
        });
    }

    _startService() {
        if (this._serviceActionInProgress || this._serviceLoadState !== "loaded") {
            return;
        }
        this._serviceActionInProgress = true;
        this._actionMessage = "Starting OneDrive service...";
        this._refresh();

        let startProcess;
        try {
            startProcess = Gio.Subprocess.new(
                ["systemctl", "--user", "start", "onedrive.service"],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
        } catch (error) {
            this._finishAction(`Unable to run systemctl: ${error.message}`);
            return;
        }

        startProcess.communicate_utf8_async(null, null, (process, result) => {
            let stderr = "";
            try {
                [, , stderr] = process.communicate_utf8_finish(result);
                if (process.get_successful()) {
                    this._finishAction("OneDrive service started");
                    return;
                }
            } catch (error) {
                stderr = error.message;
            }
            this._finishAction(`systemctl could not start the service: ${stderr.trim() || "command failed"}`);
        });
    }

    _stopSystemdService(status) {
        let stopProcess;
        try {
            stopProcess = Gio.Subprocess.new(
                ["systemctl", "--user", "stop", "onedrive.service"],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
        } catch (error) {
            this._stopMonitorPid(status, `Unable to run systemctl: ${error.message}`);
            return;
        }

        stopProcess.communicate_utf8_async(null, null, (process, result) => {
            let stderr = "";
            try {
                [, , stderr] = process.communicate_utf8_finish(result);
                if (process.get_successful()) {
                    this._finishStop("OneDrive service stopped");
                    return;
                }
            } catch (error) {
                stderr = error.message;
            }
            this._stopMonitorPid(status, `systemctl could not stop the service: ${stderr.trim() || "command failed"}`);
        });
    }

    _stopMonitorPid(status, systemdError) {
        if (status === null) {
            this._finishStop(`${systemdError}; no status file to safely identify a manual monitor`);
            return;
        }
        const processState = this._monitorProcessState(status);
        if (processState !== "running") {
            const message = processState === "stopped"
                ? "The monitor has already stopped"
                : `Unable to verify monitor process (${processState})`;
            this._finishStop(message);
            return;
        }

        let stopProcess;
        try {
            stopProcess = Gio.Subprocess.new(
                ["kill", "-TERM", String(Number(status.pid))],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
        } catch (error) {
            this._finishStop(`${systemdError}; unable to send SIGTERM: ${error.message}`);
            return;
        }

        stopProcess.communicate_utf8_async(null, null, (process, result) => {
            let stderr = "";
            try {
                [, , stderr] = process.communicate_utf8_finish(result);
                const message = process.get_successful()
                    ? `${systemdError}; sent SIGTERM to the monitor`
                    : `${systemdError}; SIGTERM failed: ${stderr.trim() || "kill command failed"}`;
                this._finishStop(message);
            } catch (error) {
                this._finishStop(`${systemdError}; SIGTERM failed: ${error.message}`);
            }
        });
    }

    _finishStop(message) {
        this._finishAction(message);
    }

    _finishAction(message) {
        this._serviceActionInProgress = false;
        this._actionMessage = message;
        if (!this._removed) {
            this._refresh();
            this._queryServiceState();
        }
    }

    _addLine(label) {
        this._menu.addMenuItem(new PopupMenu.PopupMenuItem(label, {
            reactive: false
        }));
    }

    _addServiceControls(status, processState) {
        const serviceIsLoaded = this._serviceLoadState === "loaded";
        const serviceIsActive = this._serviceActiveState === "active";
        const serviceOwnsMonitor = status === null
            ? this._serviceMainPid > 0
            : Number(status.pid) === this._serviceMainPid;
        const serviceLabel = this._serviceError
            ? "unavailable"
            : serviceIsLoaded
                ? (this._serviceActiveState === "active"
                    ? "running"
                    : this._serviceActiveState)
                : (this._serviceLoadState === "not-found" ? "not installed" : "unavailable");

        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._addLine(`User service: ${serviceLabel}`);
        if (this._serviceError) {
            this._addLine(this._serviceError);
        }

        if (this._serviceActionInProgress) {
            return;
        }

        if (processState === "running") {
            const stopItem = new PopupMenu.PopupMenuItem(
                serviceIsActive && serviceOwnsMonitor ? "Stop OneDrive service" : "Stop OneDrive monitor"
            );
            stopItem.connect("activate", () => this._stopMonitor(status));
            this._menu.addMenuItem(stopItem);
        } else if (serviceIsLoaded && !serviceIsActive &&
                   this._serviceActiveState !== "activating" &&
                   this._serviceActiveState !== "deactivating") {
            const startItem = new PopupMenu.PopupMenuItem("Start OneDrive service");
            startItem.connect("activate", () => this._startService());
            this._menu.addMenuItem(startItem);
        } else if (serviceIsActive && this._serviceMainPid > 0) {
            const stopItem = new PopupMenu.PopupMenuItem("Stop OneDrive service");
            stopItem.connect("activate", () => this._stopMonitor(status));
            this._menu.addMenuItem(stopItem);
        }
    }

    _refresh() {
        this._menu.removeAll();
        this._menu.addMenuItem(new PopupMenu.PopupMenuItem("OneDrive", {
            reactive: false
        }));
        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        let status;
        try {
            status = this._readStatus();
        } catch (error) {
            this._addLine(`Monitor status is unreadable: ${error.message}`);
            if (this._actionMessage) {
                this._addLine(`Action: ${this._actionMessage}`);
            }
            this._addServiceControls(null, "unknown");
            this.set_applet_tooltip("OneDrive status unavailable");
            return;
        }
        if (!status) {
            this._addLine("Monitor status file is unavailable");
            this._addLine("The monitor may be stopped or status publishing may be disabled");
            if (this._actionMessage) {
                this._addLine(`Action: ${this._actionMessage}`);
            }
            this._addServiceControls(null, "unknown");
            this.set_applet_tooltip("OneDrive monitor status unavailable");
            return;
        }
        const processState = this._monitorProcessState(status);
        if (processState !== "running") {
            this._addLine(processState === "stopped"
                ? "Monitor is not running"
                : `Unable to verify monitor process (${processState})`);
            if (this._actionMessage) {
                this._addLine(`Action: ${this._actionMessage}`);
            }
            this._addServiceControls(status, processState);
            this.set_applet_tooltip("OneDrive monitor status unavailable");
            return;
        }

        const process = status.process || {};
        const sync = status.sync || {};
        const lastCycle = sync.last_cycle || {};
        const account = status.account || {};
        const storage = status.storage || {};
        const cloud = storage.cloud || {};
        const local = storage.local || {};
        const state = process.state || "unknown";
        const stateLabel = state === "syncing" ? "Synchronising"
            : state === "degraded" ? "Attention required"
            : state === "idle" ? "Monitoring (idle)"
            : "Starting";

        this._addLine(`Status: ${stateLabel}`);
        this._addLine(`Last successful sync: ${localTime(sync.last_successful_sync_at)}`);
        this._addLine(`Last cycle: ${lastCycle.result || "Not available"}`);
        this._addLine(
            `Last-cycle failures: download ${Number(lastCycle.download_failures) || 0}, ` +
            `upload ${Number(lastCycle.upload_failures) || 0}, ` +
            `recycle bin ${Number(lastCycle.recycle_bin_failures) || 0}`
        );
        const reachability = (status.conditions || {}).onedrive_reachability || "unknown";
        this._addLine(`OneDrive connection: ${reachability}`);
        if (this._actionMessage) {
            this._addLine(`Action: ${this._actionMessage}`);
        }

        const identity = [account.display_name, account.email].filter(Boolean).join(" — ");
        this._addLine(`Account: ${identity || "Not available"}`);
        this._addLine(`Account type: ${account.type || "Not available"}`);

        if (cloud.quota_restricted) {
            this._addLine("OneDrive cloud: Usage unavailable");
        } else {
            this._addUsageBar(
                "OneDrive cloud",
                cloud.used_bytes,
                cloud.total_bytes,
                cloud.remaining_bytes
            );
        }
        const localUsage = this._localStorageUsage(local.sync_dir);
        if (localUsage) {
            this._addUsageBar("Local disk", localUsage.used, localUsage.total, localUsage.free);
        } else {
            this._addLine("Local disk: Usage unavailable");
        }

        this._addServiceControls(status, processState);

        this.set_applet_tooltip(`OneDrive: ${stateLabel}`);
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new OneDriveStatusApplet(metadata, orientation, panelHeight, instanceId);
}
