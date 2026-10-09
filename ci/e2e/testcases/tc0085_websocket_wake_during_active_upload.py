from __future__ import annotations

import os
import re
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0085WebSocketWakeDuringActiveUpload(MonitorModeTestCaseBase):
    case_id = "0085"
    name = "websocket remote wake during active upload"
    description = (
        "Validate that a WebSocket remote wake received while an inotify upload worker "
        "is active is preserved and consumed promptly after the worker becomes idle"
    )

    MONITOR_INTERVAL = 300
    UPLOAD_SIZE = 96 * 1024 * 1024
    RATE_LIMIT = 1048576
    PROGRESS_THRESHOLD = 5.0
    REMOTE_WAIT_SECONDS = 180

    def _monitor_text(self, stdout_file: Path, stderr_file: Path, app_logs: Path) -> str:
        # Follow TC0059: inspect stdout, stderr, and the existing application log.
        return "\n".join((
            self._read_stdout(stdout_file),
            self._read_stdout(stderr_file),
            self._read_app_logs(app_logs),
        ))

    def _progress(self, text: str, filename: str) -> float:
        # Follow TC0021's percent-based progress observation, restricted to
        # messages associated with the target transfer wherever possible.
        relevant = "\n".join(line for line in text.splitlines() if filename in line)
        percentages = [float(value) for value in re.findall(r"(\d{1,3}(?:\.\d+)?)\s*%", relevant)]
        if not percentages:
            percentages = [float(value) for value in re.findall(r"(\d{1,3}(?:\.\d+)?)\s*%", text)]
        return max((p for p in percentages if 0 <= p <= 100), default=0.0)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0085", ensure_refresh_token=True)
        work_dir, log_dir, state_dir = layout.work_dir, layout.log_dir, layout.state_dir
        root_name = f"ZZ_E2E_TC0085_{context.run_id}_{os.getpid()}"
        monitor_root = work_dir / "monitorroot"
        mutator_root = work_dir / "mutatorroot"
        verifier_root = work_dir / "verifyroot"
        conf_monitor = work_dir / "conf-monitor"
        conf_mutator = work_dir / "conf-mutator"
        conf_verify = work_dir / "conf-verify"
        app_logs = log_dir / "app-logs"
        large_rel = f"{root_name}/active-upload.bin"
        remote_rel = f"{root_name}/remote-during-upload.txt"
        remote_content = "TC0085 remote change while another monitor worker is uploading\n"
        large_file = monitor_root / large_rel
        remote_local = monitor_root / remote_rel
        metadata_file = state_dir / "metadata.txt"
        monitor_stdout, monitor_stderr = log_dir / "monitor_stdout.log", log_dir / "monitor_stderr.log"
        mutator_stdout, mutator_stderr = log_dir / "mutator_stdout.log", log_dir / "mutator_stderr.log"
        verify_stdout, verify_stderr = log_dir / "verify_stdout.log", log_dir / "verify_stderr.log"
        monitor_manifest_file, verify_manifest_file = state_dir / "monitor_manifest.txt", state_dir / "verify_manifest.txt"
        artifacts = [str(p) for p in (
            monitor_stdout, monitor_stderr, mutator_stdout, mutator_stderr,
            verify_stdout, verify_stderr, monitor_manifest_file,
            verify_manifest_file, metadata_file, app_logs,
        )]
        details: dict[str, object] = {
            "root_name": root_name,
            "large_relative": large_rel,
            "remote_relative": remote_rel,
            "monitor_interval": self.MONITOR_INTERVAL,
            "transfer_rate_limit": self.RATE_LIMIT,
            "upload_size": self.UPLOAD_SIZE,
        }

        context.prepare_minimal_config_dir(conf_monitor, (
            '# tc0085 monitor configuration\n'
            f'sync_dir = "{monitor_root}"\n'
            'bypass_data_preservation = "true"\n'
            'threads = "1"\n'
            f'rate_limit = "{self.RATE_LIMIT}"\n'
            'force_session_upload = "true"\n'
            'disable_websocket_support = "false"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_logs}"\n'
            f'monitor_interval = "{self.MONITOR_INTERVAL}"\n'
            'monitor_fullscan_frequency = "0"\n'
        ))
        context.prepare_minimal_config_dir(conf_mutator, (
            f'# tc0085 independent mutator\nsync_dir = "{mutator_root}"\n'
            'bypass_data_preservation = "true"\n'
        ))
        context.prepare_minimal_config_dir(conf_verify, (
            f'# tc0085 independent verifier\nsync_dir = "{verifier_root}"\n'
            'bypass_data_preservation = "true"\n'
        ))
        write_text_file(monitor_root / root_name / "baseline.txt", "TC0085 tracked initial fixture\n")

        monitor_command = [
            context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--verbose",
            "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_monitor),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process, initial_ready = self._launch_monitor_process(
            context, monitor_command, monitor_stdout, monitor_stderr, startup_timeout_seconds=300,
        )
        failure = ""
        try:
            if not initial_ready:
                failure = "Monitor did not complete initial tracked synchronisation"
            else:
                start_text = self._monitor_text(monitor_stdout, monitor_stderr, app_logs)
                if "Enabled WebSocket support" not in start_text:
                    failure = "Initial monitor did not enable WebSocket support"
                elif not self._wait_for_monitor_stdout_quiet(process, monitor_stdout, quiet_seconds=3, timeout_seconds=30):
                    failure = "Monitor did not become idle after initial sync"

            if not failure:
                # Do not pre-create this file: its inotify create event must start
                # a real upload worker within the running monitor process.
                large_file.parent.mkdir(parents=True, exist_ok=True)
                with large_file.open("wb") as handle:
                    chunk = b"TC0085_REAL_TRANSFER_" * 4096
                    remaining = self.UPLOAD_SIZE
                    while remaining:
                        block = chunk[: min(len(chunk), remaining)]
                        handle.write(block)
                        remaining -= len(block)
                write_finished_at = time.monotonic()
                details["large_file_written"] = True
                deadline = time.monotonic() + 150
                progress_at_trigger = 0.0
                while time.monotonic() < deadline and process.poll() is None:
                    text = self._monitor_text(monitor_stdout, monitor_stderr, app_logs)
                    progress_at_trigger = self._progress(text, large_file.name)
                    if self.PROGRESS_THRESHOLD <= progress_at_trigger < 95.0:
                        break
                    time.sleep(0.5)
                details["upload_progress_at_mutation_percent"] = progress_at_trigger
                details["upload_wait_seconds"] = round(time.monotonic() - write_finished_at, 2)
                if not (self.PROGRESS_THRESHOLD <= progress_at_trigger < 95.0):
                    failure = "No measurable in-flight upload progress was observed before the remote mutation"

            if not failure:
                # Log offset separates the actual remote wake from prior account events.
                before_mutation = self._monitor_text(monitor_stdout, monitor_stderr, app_logs)
                old_signal_count = before_mutation.count("Received 1 signal(s) from WebSocket handler")
                old_notification_count = before_mutation.count("SOCKETIO: Notification Event")
                details["signal_count_before_mutation"] = old_signal_count
                details["notification_count_before_mutation"] = old_notification_count
                write_text_file(mutator_root / remote_rel, remote_content)
                mutator_command = [
                    context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
                    "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                    "--confdir", str(conf_mutator),
                ]
                context.log(f"Executing Test Case {self.case_id} mutator: {command_to_string(mutator_command)}")
                mutation_started_at = time.monotonic()
                mutation_result = run_command(mutator_command, cwd=context.repo_root)
                write_text_file(mutator_stdout, mutation_result.stdout)
                write_text_file(mutator_stderr, mutation_result.stderr)
                details["mutator_returncode"] = mutation_result.returncode
                details["mutator_elapsed_seconds"] = round(time.monotonic() - mutation_started_at, 2)
                if mutation_result.returncode != 0:
                    failure = f"Independent remote upload failed with exit {mutation_result.returncode}"

            if not failure:
                # Require a WebSocket notification that is observed before the
                # slowed transfer is complete. A later notification alone does
                # not test #3767's active-worker condition.
                deadline = time.monotonic() + self.REMOTE_WAIT_SECONDS
                notification_seen_during_transfer = False
                signal_seen = False
                remote_downloaded = False
                observed_notification_at = None
                observed_download_at = None
                progress_at_notification = None
                while time.monotonic() < deadline and process.poll() is None:
                    text = self._monitor_text(monitor_stdout, monitor_stderr, app_logs)
                    current_percent = self._progress(text, large_file.name)
                    if (
                        not notification_seen_during_transfer
                        and text.count("SOCKETIO: Notification Event") > old_notification_count
                    ):
                        observed_notification_at = time.monotonic()
                        progress_at_notification = current_percent
                        if current_percent < 100.0:
                            notification_seen_during_transfer = True
                    if text.count("Received 1 signal(s) from WebSocket handler") > old_signal_count:
                        signal_seen = True
                    if remote_local.is_file() and remote_local.read_text(encoding="utf-8") == remote_content:
                        remote_downloaded = True
                        observed_download_at = time.monotonic()
                    if notification_seen_during_transfer and signal_seen and remote_downloaded and current_percent >= 100.0:
                        break
                    time.sleep(0.5)
                details["notification_during_active_transfer"] = notification_seen_during_transfer
                details["upload_progress_at_notification_percent"] = progress_at_notification
                details["websocket_wake_consumed"] = signal_seen
                details["remote_downloaded"] = remote_downloaded
                details["remote_download_latency_seconds"] = (
                    round(observed_download_at - mutation_started_at, 2) if observed_download_at else None
                )
                details["upload_max_progress_percent"] = self._progress(
                    self._monitor_text(monitor_stdout, monitor_stderr, app_logs), large_file.name,
                )
                if not notification_seen_during_transfer:
                    failure = "No Socket.IO notification was demonstrated during an active, incomplete upload"
                elif not signal_seen:
                    failure = "Remote wake was not consumed by the monitor after the active worker"
                elif not remote_downloaded:
                    failure = "Remote file was not downloaded following the WebSocket notification"
                elif details["remote_download_latency_seconds"] >= self.MONITOR_INTERVAL:
                    failure = "Remote change was not handled before the scheduled monitor interval"
                elif details["upload_max_progress_percent"] < 100.0:
                    failure = "No evidence that the slowed upload completed"
        finally:
            self._shutdown_monitor_process(process, details)

        # Keep verifier independent of the monitor's existing local state.
        if not failure:
            verify_command = [
                context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                "--confdir", str(conf_verify),
            ]
            context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
            verify_result = run_command(verify_command, cwd=context.repo_root)
            write_text_file(verify_stdout, verify_result.stdout)
            write_text_file(verify_stderr, verify_result.stderr)
            details["verify_returncode"] = verify_result.returncode
            if verify_result.returncode != 0:
                failure = f"Independent remote verification failed with exit {verify_result.returncode}"
            else:
                monitor_manifest = build_manifest(monitor_root)
                verify_manifest = build_manifest(verifier_root)
                write_manifest(monitor_manifest_file, monitor_manifest)
                write_manifest(verify_manifest_file, verify_manifest)
                details["monitor_manifest_entries"] = len(monitor_manifest)
                details["verify_manifest_entries"] = len(verify_manifest)
                if remote_rel not in monitor_manifest or remote_rel not in verify_manifest:
                    failure = "Remote notification file is missing from a final manifest"
                elif (verifier_root / remote_rel).read_text(encoding="utf-8") != remote_content:
                    failure = "Independent verifier downloaded unexpected remote content"
                elif large_rel not in verify_manifest:
                    failure = "Independent verifier did not find the completed monitor-side large upload"
                elif (verifier_root / large_rel).stat().st_size != self.UPLOAD_SIZE:
                    failure = "Independent verifier received the wrong large-upload file size"

        self._write_metadata(metadata_file, details)
        if failure:
            return self.fail_result(self.case_id, self.name, failure, artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
