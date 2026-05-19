from __future__ import annotations

import os
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_onedrive_config, write_text_file


class TestCase0059WebSocketRemoteUploadNotification(MonitorModeTestCaseBase):
    case_id = "0059"
    name = "websocket remote upload notification"
    description = (
        "Validate that a running --monitor process with WebSocket support enabled receives "
        "a remote upload notification from a second process and downloads the new file "
        "without waiting for the normal monitor_interval cadence"
    )

    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"
    WEBSOCKET_ENABLE_PATTERNS = [
        "Attempting to enable WebSocket support to monitor Microsoft Graph API changes in near real-time.",
        "Enabled WebSocket support to monitor Microsoft Graph API changes in near real-time.",
    ]
    WEBSOCKET_PING_PONG_PATTERN = "DEBUG: SOCKETIO: Socket.IO ping received"
    WEBSOCKET_SIGNAL_PATTERN = "DEBUG: Received 1 signal(s) from WebSocket handler"

    def _build_monitor_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        return (
            "# tc0059 monitor config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'disable_websocket_support = "false"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
        )

    def _write_helper_config(self, config_path: Path, sync_dir: Path, *, label: str) -> None:
        write_onedrive_config(
            config_path,
            (
                f"# tc0059 {label} config\n"
                f'sync_dir = "{sync_dir}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

    def _read_text_file(self, path: Path) -> str:
        try:
            return path.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return ""
        except OSError:
            return ""

    def _read_monitor_log_text(self, stdout_file: Path, stderr_file: Path, app_log_dir: Path) -> str:
        parts = [
            self._read_text_file(stdout_file),
            self._read_text_file(stderr_file),
            self._read_text_file(app_log_dir / "root.onedrive.log"),
        ]
        return "\n".join(part for part in parts if part)

    def _wait_for_monitor_log_patterns(
        self,
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
        required_patterns: list[str],
        timeout_seconds: int,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            content = self._read_monitor_log_text(stdout_file, stderr_file, app_log_dir)
            if all(pattern in content for pattern in required_patterns):
                return True
            time.sleep(poll_interval)
        return False

    def _count_sync_complete_markers(self, stdout_file: Path, stderr_file: Path, app_log_dir: Path) -> int:
        return self._read_monitor_log_text(stdout_file, stderr_file, app_log_dir).count(self.SYNC_COMPLETE_PATTERN)

    def _count_websocket_signal_markers(self, stdout_file: Path, stderr_file: Path, app_log_dir: Path) -> int:
        return self._read_monitor_log_text(stdout_file, stderr_file, app_log_dir).count(self.WEBSOCKET_SIGNAL_PATTERN)

    def _wait_for_remote_upload_download(
        self,
        *,
        downloaded_path: Path,
        expected_content: str,
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
        websocket_signal_count_before_upload: int,
        timeout_seconds: int,
        poll_interval: float = 0.5,
    ) -> tuple[bool, str]:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if downloaded_path.is_file():
                try:
                    actual_content = downloaded_path.read_text(encoding="utf-8", errors="replace")
                except OSError as exc:
                    return False, f"downloaded file exists but could not be read: {exc}"

                if actual_content != expected_content:
                    return False, "downloaded file content did not match uploaded content"

                websocket_signal_count = self._count_websocket_signal_markers(stdout_file, stderr_file, app_log_dir)
                if websocket_signal_count <= websocket_signal_count_before_upload:
                    return False, (
                        "downloaded file was present and content matched, but no new WebSocket "
                        "signal marker was logged after the remote upload"
                    )

                return True, ""

            time.sleep(poll_interval)

        return False, "monitor process did not download the remotely uploaded file within the WebSocket wait window"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0059",
            ensure_refresh_token=True,
        )

        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        monitor_root = case_work_dir / "monitorroot"
        uploader_root = case_work_dir / "uploaderroot"
        verify_root = case_work_dir / "verifyroot"
        conf_monitor = case_work_dir / "conf-monitor"
        conf_uploader = case_work_dir / "conf-uploader"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0059_{context.run_id}_{os.getpid()}"
        baseline_relative = f"{root_name}/baseline.txt"
        uploaded_relative = f"{root_name}/websocket-remote-upload.txt"

        baseline_content = "TC0059 baseline created by the monitor-side initial sync\n"
        uploaded_content = (
            "TC0059 WebSocket remote upload notification validation\n"
            "This file was uploaded by an independent --sync --upload-only process.\n"
        )

        baseline_monitor_path = monitor_root / baseline_relative
        uploaded_uploader_path = uploader_root / uploaded_relative
        uploaded_monitor_path = monitor_root / uploaded_relative

        context.bootstrap_config_dir(conf_monitor)
        write_onedrive_config(conf_monitor / "config", self._build_monitor_config_text(monitor_root, app_log_dir))

        context.bootstrap_config_dir(conf_uploader)
        self._write_helper_config(conf_uploader / "config", uploader_root, label="uploader")

        context.bootstrap_config_dir(conf_verify)
        self._write_helper_config(conf_verify / "config", verify_root, label="verify")

        write_text_file(baseline_monitor_path, baseline_content)

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        upload_stdout = case_log_dir / "upload_only_stdout.log"
        upload_stderr = case_log_dir / "upload_only_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        monitor_manifest_file = state_dir / "monitor_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(monitor_stdout),
            str(monitor_stderr),
            str(upload_stdout),
            str(upload_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(monitor_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
            str(app_log_dir),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "baseline_relative": baseline_relative,
            "uploaded_relative": uploaded_relative,
            "monitor_root": str(monitor_root),
            "uploader_root": str(uploader_root),
            "verify_root": str(verify_root),
            "conf_monitor": str(conf_monitor),
            "conf_uploader": str(conf_uploader),
            "monitor_interval": 300,
            "monitor_fullscan_frequency": 0,
            "websocket_wait_window_seconds": 120,
        }

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(monitor_root),
            "--confdir",
            str(conf_monitor),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")

        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            startup_timeout_seconds=300,
        )

        upload_result = None
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor process did not complete the initial sync within the expected time",
                    artifacts,
                    details,
                )

            websocket_enabled = self._wait_for_monitor_log_patterns(
                monitor_stdout,
                monitor_stderr,
                app_log_dir,
                self.WEBSOCKET_ENABLE_PATTERNS,
                timeout_seconds=30,
            )
            details["websocket_enabled"] = websocket_enabled
            details["websocket_enable_patterns"] = self.WEBSOCKET_ENABLE_PATTERNS
            if not websocket_enabled:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor process did not log WebSocket enablement markers",
                    artifacts,
                    details,
                )

            ping_pong_seen = self._wait_for_monitor_log_patterns(
                monitor_stdout,
                monitor_stderr,
                app_log_dir,
                [self.WEBSOCKET_PING_PONG_PATTERN],
                timeout_seconds=90,
            )
            details["websocket_ping_pong_seen"] = ping_pong_seen
            details["websocket_ping_pong_pattern"] = self.WEBSOCKET_PING_PONG_PATTERN
            if not ping_pong_seen:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor process did not log the expected WebSocket ping/pong activity",
                    artifacts,
                    details,
                )

            sync_complete_count_before_upload = self._count_sync_complete_markers(
                monitor_stdout,
                monitor_stderr,
                app_log_dir,
            )
            websocket_signal_count_before_upload = self._count_websocket_signal_markers(
                monitor_stdout,
                monitor_stderr,
                app_log_dir,
            )
            details["sync_complete_count_before_remote_upload"] = sync_complete_count_before_upload
            details["websocket_signal_count_before_remote_upload"] = websocket_signal_count_before_upload
            details["websocket_signal_pattern"] = self.WEBSOCKET_SIGNAL_PATTERN

            write_text_file(uploaded_uploader_path, uploaded_content)
            details["uploaded_uploader_path_exists_after_write"] = uploaded_uploader_path.is_file()

            upload_command = [
                context.onedrive_bin,
                "--display-running-config",
                "--sync",
                "--upload-only",
                "--verbose",
                "--resync",
                "--resync-auth",
                "--single-directory",
                root_name,
                "--syncdir",
                str(uploader_root),
                "--confdir",
                str(conf_uploader),
            ]
            context.log(f"Executing Test Case {self.case_id} remote upload stimulus: {command_to_string(upload_command)}")
            upload_result = run_command(upload_command, cwd=context.repo_root)
            write_text_file(upload_stdout, upload_result.stdout)
            write_text_file(upload_stderr, upload_result.stderr)
            details["upload_returncode"] = upload_result.returncode
            if upload_result.returncode != 0:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Remote upload stimulus failed with status {upload_result.returncode}",
                    artifacts,
                    details,
                )

            downloaded, download_failure_reason = self._wait_for_remote_upload_download(
                downloaded_path=uploaded_monitor_path,
                expected_content=uploaded_content,
                stdout_file=monitor_stdout,
                stderr_file=monitor_stderr,
                app_log_dir=app_log_dir,
                websocket_signal_count_before_upload=websocket_signal_count_before_upload,
                timeout_seconds=120,
            )
            details["remote_upload_downloaded_by_monitor"] = downloaded
            details["download_failure_reason"] = download_failure_reason
            details["uploaded_monitor_path_exists"] = uploaded_monitor_path.is_file()
            details["sync_complete_count_after_remote_upload"] = self._count_sync_complete_markers(
                monitor_stdout,
                monitor_stderr,
                app_log_dir,
            )
            details["websocket_signal_count_after_remote_upload"] = self._count_websocket_signal_markers(
                monitor_stdout,
                monitor_stderr,
                app_log_dir,
            )

            if not downloaded:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    download_failure_reason,
                    artifacts,
                    details,
                )
        finally:
            self._shutdown_monitor_process(process, details)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(conf_verify),
        ]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        monitor_manifest = build_manifest(monitor_root)
        verify_manifest = build_manifest(verify_root)
        write_manifest(monitor_manifest_file, monitor_manifest)
        write_manifest(verify_manifest_file, verify_manifest)
        details["monitor_manifest_entries"] = len(monitor_manifest)
        details["verify_manifest_entries"] = len(verify_manifest)

        if uploaded_monitor_path.is_file():
            details["uploaded_monitor_content"] = uploaded_monitor_path.read_text(encoding="utf-8", errors="replace")
        else:
            details["uploaded_monitor_content"] = ""

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if uploaded_relative not in monitor_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Monitor manifest is missing remotely uploaded file: {uploaded_relative}",
                artifacts,
                details,
            )

        if uploaded_relative not in verify_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification manifest is missing uploaded file: {uploaded_relative}",
                artifacts,
                details,
            )

        if details["uploaded_monitor_content"] != uploaded_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor-side downloaded file content did not match uploaded content",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
