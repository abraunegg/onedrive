from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    CommandResult,
    command_to_string,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0077TimestampAuthorityValidation(MonitorModeTestCaseBase):
    case_id = "0077"
    name = "timestamp authority safety gating"
    description = (
        "Validate confirmed unsafe system-time handling at --monitor startup, "
        "during an active --monitor session, at --sync startup, and when the "
        "explicit --disable-time-check override is used"
    )

    CLOCK_SKEW_SECONDS = 180
    BLOCKING_PATTERN = (
        "ERROR: OneDrive synchronisation suspended because unsafe local system clock drift has been confirmed"
    )
    BLOCKING_RESULT_PATTERN = "Result:                    TIME_DRIFT_BLOCKING"
    MONITOR_STARTUP_SUSPENDED_PATTERN = (
        "OneDrive monitor startup is suspended until the local system clock returns to a safe range."
    )
    MONITOR_STARTUP_RECOVERED_PATTERN = "System time is now safe; continuing OneDrive monitor startup."
    RUNTIME_RECOVERED_PATTERN = (
        "NOTICE: System clock validation has recovered; OneDrive synchronisation will resume"
    )
    SYNC_STARTUP_BLOCKED_PATTERN = "ERROR: --sync cannot continue while system time is in a blocking state."
    SYNC_CORRECTION_GUIDANCE_PATTERN = (
        "Correct the local system time or time synchronisation service, then retry the sync."
    )
    TIME_CHECK_DISABLED_WARNING_PATTERN = "WARNING: System time validation has been disabled by configuration"
    TIME_CHECK_DISABLED_STATE_PATTERN = "TIME_CHECK_DISABLED"

    def _find_libfaketime_mt(self) -> Path | None:
        candidates = [
            Path("/usr/lib64/faketime/libfaketimeMT.so.1"),
            Path("/usr/lib64/libfaketimeMT.so.1"),
            Path("/usr/lib/faketime/libfaketimeMT.so.1"),
            Path("/usr/lib/libfaketimeMT.so.1"),
        ]
        for candidate in candidates:
            if candidate.is_file():
                return candidate

        for root in (Path("/usr/lib64"), Path("/usr/lib")):
            if not root.is_dir():
                continue
            try:
                for candidate in root.rglob("libfaketimeMT.so.1"):
                    if candidate.is_file():
                        return candidate
            except OSError:
                continue

        return None

    def _set_faketime_offset(self, control_file: Path, offset_seconds: int) -> None:
        control_file.parent.mkdir(parents=True, exist_ok=True)
        temporary_file = control_file.with_name(control_file.name + ".tmp")
        temporary_file.write_text(f"{offset_seconds:+d}\n", encoding="utf-8")
        os.replace(temporary_file, control_file)

    def _build_faketime_env(self, library: Path, control_file: Path) -> dict[str, str]:
        env = dict(os.environ)
        existing_preload = env.get("LD_PRELOAD", "").strip()
        env["LD_PRELOAD"] = str(library) + (f":{existing_preload}" if existing_preload else "")
        env["FAKETIME_TIMESTAMP_FILE"] = str(control_file)
        env["FAKETIME_NO_CACHE"] = "1"
        env["FAKETIME_DONT_FAKE_MONOTONIC"] = "1"
        env["NO_FAKE_STAT"] = "1"
        env.pop("FAKETIME", None)
        return env

    def _remember_monitor_offsets(self, monitor_stdout: Path) -> int:
        stdout_content = self._read_stdout(monitor_stdout)
        app_log_content = self._read_app_logs(self._monitor_app_log_dir_for_stdout(monitor_stdout))
        self._remember_monitor_app_log_offset(monitor_stdout, len(app_log_content))
        return len(stdout_content)

    def _write_sync_config(self, config_dir: Path, sync_dir: Path) -> None:
        write_onedrive_config(
            config_dir / "config",
            (
                f"# tc{self.case_id} sync config\n"
                f'sync_dir = "{sync_dir}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

    def _run_sync_phase(
        self,
        context: E2EContext,
        label: str,
        conf_dir: Path,
        sync_root: Path,
        root_name: str,
        stdout_file: Path,
        stderr_file: Path,
        *,
        download_only: bool = False,
        env: dict[str, str] | None = None,
    ) -> CommandResult:
        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
        ]
        if download_only:
            command.append("--download-only")
        command.extend(
            [
                "--verbose",
                "--resync",
                "--resync-auth",
                "--single-directory",
                root_name,
                "--syncdir",
                str(sync_root),
                "--confdir",
                str(conf_dir),
            ]
        )
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root, env=env)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def _verify_remote_state(
        self,
        context: E2EContext,
        *,
        label: str,
        root_name: str,
        verify_root: Path,
        verify_conf: Path,
        stdout_file: Path,
        stderr_file: Path,
        manifest_file: Path,
    ) -> tuple[CommandResult, list[str]]:
        reset_directory(verify_root)
        context.bootstrap_config_dir(verify_conf)
        self._write_sync_config(verify_conf, verify_root)

        result = self._run_sync_phase(
            context,
            label,
            verify_conf,
            verify_root,
            root_name,
            stdout_file,
            stderr_file,
            download_only=True,
        )
        manifest = build_manifest(verify_root)
        write_manifest(manifest_file, manifest)
        return result, manifest

    def _scenario_startup_monitor_blocked_then_recovers(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        library: Path,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_id = "TA-0001"
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id
        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        sync_root = scenario_work_dir / "syncroot"
        final_verify_root = scenario_work_dir / "verify-final-root"
        conf_main = scenario_work_dir / "conf-main"
        conf_final_verify = scenario_work_dir / "conf-verify-final"
        app_log_dir = scenario_log_dir / "app-logs"
        control_file = scenario_state_dir / "faketime.rc"

        reset_directory(sync_root)
        context.bootstrap_config_dir(conf_main)
        write_onedrive_config(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        root_name = f"ZZ_E2E_TC0077_{scenario_id}_{context.run_id}_{os.getpid()}"
        delayed_relative = f"{root_name}/startup-delayed.txt"
        delayed_path = sync_root / delayed_relative
        delayed_content = "TC0077 TA-0001 file must not upload until startup time authority recovers.\n"
        write_text_file(delayed_path, delayed_content)

        monitor_stdout = scenario_log_dir / "monitor_stdout.log"
        monitor_stderr = scenario_log_dir / "monitor_stderr.log"
        final_verify_stdout = scenario_log_dir / "final_verify_stdout.log"
        final_verify_stderr = scenario_log_dir / "final_verify_stderr.log"
        final_manifest_file = scenario_state_dir / "final_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts.extend(
            [
                str(monitor_stdout),
                str(monitor_stderr),
                str(final_verify_stdout),
                str(final_verify_stderr),
                str(final_manifest_file),
                str(metadata_file),
                str(control_file),
                str(app_log_dir),
            ]
        )

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": "bad time at --monitor startup blocks initial sync until recovery",
            "root_name": root_name,
            "delayed_relative": delayed_relative,
            "clock_skew_seconds": self.CLOCK_SKEW_SECONDS,
            "faketime_library": str(library),
        }

        self._set_faketime_offset(control_file, self.CLOCK_SKEW_SECONDS)
        faketime_env = self._build_faketime_env(library, control_file)

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} {scenario_id} monitor: {command_to_string(monitor_command)}")

        process = self._launch_monitor_process_raw(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            env=faketime_env,
        )
        try:
            blocked_seen, blocked_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=0,
                required_patterns=[
                    self.BLOCKING_PATTERN,
                    self.BLOCKING_RESULT_PATTERN,
                    self.MONITOR_STARTUP_SUSPENDED_PATTERN,
                ],
                timeout_seconds=120,
            )
            details["blocking_evidence_seen"] = blocked_seen
            details["monitor_alive_while_blocked"] = process.poll() is None
            details["sync_started_while_blocked"] = "Starting a sync with Microsoft OneDrive" in blocked_segment
            details["delayed_upload_seen_while_blocked"] = (
                f"Uploading new file: {delayed_relative} ... done" in blocked_segment
            )

            if not blocked_seen:
                return False, f"{scenario_id} did not enter confirmed blocking state at monitor startup", details
            if process.poll() is not None:
                return False, f"{scenario_id} monitor exited instead of waiting for time recovery", details
            if details["sync_started_while_blocked"] or details["delayed_upload_seen_while_blocked"]:
                return False, f"{scenario_id} started synchronisation while startup time was blocked", details

            recovery_offset = self._remember_monitor_offsets(monitor_stdout)
            recovery_started = time.monotonic()
            self._set_faketime_offset(control_file, 0)
            recovery_seen, recovery_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=recovery_offset,
                required_patterns=[
                    self.MONITOR_STARTUP_RECOVERED_PATTERN,
                    f"Uploading new file: {delayed_relative} ... done",
                    self.SYNC_COMPLETE_PATTERN,
                ],
                timeout_seconds=390,
            )
            details["recovery_evidence_seen"] = recovery_seen
            details["recovery_wait_seconds"] = round(time.monotonic() - recovery_started, 3)
            details["monitor_alive_after_recovery"] = process.poll() is None
            details["recovery_segment_length"] = len(recovery_segment)

            if not recovery_seen:
                return False, f"{scenario_id} did not resume monitor startup and upload after time recovery", details
            if process.poll() is not None:
                return False, f"{scenario_id} monitor exited during startup recovery", details
        finally:
            self._set_faketime_offset(control_file, 0)
            self._shutdown_monitor_process(process, details)

        final_verify_result, final_manifest = self._verify_remote_state(
            context,
            label=f"{scenario_id} final remote verification",
            root_name=root_name,
            verify_root=final_verify_root,
            verify_conf=conf_final_verify,
            stdout_file=final_verify_stdout,
            stderr_file=final_verify_stderr,
            manifest_file=final_manifest_file,
        )
        details["final_verify_returncode"] = final_verify_result.returncode
        final_delayed_path = final_verify_root / delayed_relative
        details["delayed_file_present_after_recovery"] = delayed_relative in final_manifest
        details["delayed_file_content_matches"] = (
            final_delayed_path.is_file() and final_delayed_path.read_text(encoding="utf-8") == delayed_content
        )
        self._write_metadata(metadata_file, details)

        if final_verify_result.returncode != 0:
            return False, f"{scenario_id} final remote verification failed with status {final_verify_result.returncode}", details
        if delayed_relative not in final_manifest:
            return False, f"{scenario_id} delayed file was not present remotely after time recovery", details
        if not details["delayed_file_content_matches"]:
            return False, f"{scenario_id} delayed file content did not match after recovery", details

        return True, "startup-blocked monitor waited for time recovery before synchronising", details

    def _scenario_running_monitor_blocks_then_recovers(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        library: Path,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_id = "TA-0002"
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id
        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        sync_root = scenario_work_dir / "syncroot"
        blocked_verify_root = scenario_work_dir / "verify-blocked-root"
        final_verify_root = scenario_work_dir / "verify-final-root"
        conf_main = scenario_work_dir / "conf-main"
        conf_blocked_verify = scenario_work_dir / "conf-verify-blocked"
        conf_final_verify = scenario_work_dir / "conf-verify-final"
        app_log_dir = scenario_log_dir / "app-logs"
        control_file = scenario_state_dir / "faketime.rc"

        reset_directory(sync_root)
        context.bootstrap_config_dir(conf_main)
        write_onedrive_config(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        root_name = f"ZZ_E2E_TC0077_{scenario_id}_{context.run_id}_{os.getpid()}"
        baseline_relative = f"{root_name}/baseline.txt"
        blocked_relative = f"{root_name}/queued-while-time-blocked.txt"
        wake_relative = f"{root_name}/recovery-wake.txt"
        blocked_content = "TC0077 TA-0002 queued while system time is blocked.\n"
        wake_content = "TC0077 TA-0002 recovery wake event.\n"

        write_text_file(sync_root / baseline_relative, "TC0077 TA-0002 baseline\n")
        self._set_faketime_offset(control_file, 0)
        faketime_env = self._build_faketime_env(library, control_file)

        monitor_stdout = scenario_log_dir / "monitor_stdout.log"
        monitor_stderr = scenario_log_dir / "monitor_stderr.log"
        blocked_verify_stdout = scenario_log_dir / "blocked_verify_stdout.log"
        blocked_verify_stderr = scenario_log_dir / "blocked_verify_stderr.log"
        blocked_manifest_file = scenario_state_dir / "blocked_verify_manifest.txt"
        final_verify_stdout = scenario_log_dir / "final_verify_stdout.log"
        final_verify_stderr = scenario_log_dir / "final_verify_stderr.log"
        final_manifest_file = scenario_state_dir / "final_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts.extend(
            [
                str(monitor_stdout),
                str(monitor_stderr),
                str(blocked_verify_stdout),
                str(blocked_verify_stderr),
                str(blocked_manifest_file),
                str(final_verify_stdout),
                str(final_verify_stderr),
                str(final_manifest_file),
                str(metadata_file),
                str(control_file),
                str(app_log_dir),
            ]
        )

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": "running --monitor suspends on clock drift and resumes queued work after recovery",
            "root_name": root_name,
            "baseline_relative": baseline_relative,
            "blocked_relative": blocked_relative,
            "wake_relative": wake_relative,
            "clock_skew_seconds": self.CLOCK_SKEW_SECONDS,
            "faketime_library": str(library),
        }

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} {scenario_id} monitor: {command_to_string(monitor_command)}")

        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            env=faketime_env,
        )
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                return False, f"{scenario_id} monitor did not complete its initial healthy-time sync", details

            mutation_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)
            self._set_faketime_offset(control_file, self.CLOCK_SKEW_SECONDS)
            write_text_file(sync_root / blocked_relative, blocked_content)

            blocked_seen, blocked_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_offset,
                required_patterns=[
                    self.BLOCKING_PATTERN,
                    self.BLOCKING_RESULT_PATTERN,
                ],
                timeout_seconds=120,
            )
            details["blocking_evidence_seen"] = blocked_seen
            details["monitor_alive_while_blocked"] = process.poll() is None
            details["blocked_file_upload_seen_at_block"] = any(
                pattern in blocked_segment
                for pattern in (
                    f"Uploading new file: {blocked_relative} ... done",
                    f"Uploading new file: ./{blocked_relative} ... done",
                )
            )
            details["sync_complete_seen_after_block"] = self.SYNC_COMPLETE_PATTERN in blocked_segment

            if not blocked_seen:
                return False, f"{scenario_id} did not enter confirmed blocking state after runtime clock drift", details
            if process.poll() is not None:
                return False, f"{scenario_id} monitor exited after runtime clock drift", details
            if details["blocked_file_upload_seen_at_block"]:
                return False, f"{scenario_id} uploaded the queued file while system time was blocked", details
            if details["sync_complete_seen_after_block"]:
                return False, f"{scenario_id} reported sync completion after the time gate blocked the cycle", details

            time.sleep(3.0)
            blocked_segment = self._read_monitor_output_from_offsets(monitor_stdout, mutation_offset)
            if any(
                pattern in blocked_segment
                for pattern in (
                    f"Uploading new file: {blocked_relative} ... done",
                    f"Uploading new file: ./{blocked_relative} ... done",
                )
            ):
                return False, f"{scenario_id} uploaded the queued file while remaining in blocking state", details

            blocked_verify_result, blocked_manifest = self._verify_remote_state(
                context,
                label=f"{scenario_id} blocked remote verification",
                root_name=root_name,
                verify_root=blocked_verify_root,
                verify_conf=conf_blocked_verify,
                stdout_file=blocked_verify_stdout,
                stderr_file=blocked_verify_stderr,
                manifest_file=blocked_manifest_file,
            )
            details["blocked_verify_returncode"] = blocked_verify_result.returncode
            details["baseline_present_remotely_while_blocked"] = baseline_relative in blocked_manifest
            details["blocked_file_present_remotely_while_blocked"] = blocked_relative in blocked_manifest

            if blocked_verify_result.returncode != 0:
                return (
                    False,
                    f"{scenario_id} blocked-state remote verification failed with status {blocked_verify_result.returncode}",
                    details,
                )
            if baseline_relative not in blocked_manifest:
                return False, f"{scenario_id} baseline file disappeared during blocked-state verification", details
            if blocked_relative in blocked_manifest:
                return False, f"{scenario_id} queued file reached OneDrive while system time was blocked", details

            recovery_offset = self._remember_monitor_offsets(monitor_stdout)
            self._set_faketime_offset(control_file, 0)
            write_text_file(sync_root / wake_relative, wake_content)

            recovery_notice_seen, recovery_uploads_seen, matched_upload_group, recovery_segment = (
                self._wait_for_required_patterns_and_any_group(
                    monitor_stdout,
                    start_offset=recovery_offset,
                    required_patterns=[self.RUNTIME_RECOVERED_PATTERN],
                    alternative_pattern_groups=[
                        [
                            f"Uploading new file: {blocked_relative} ... done",
                            f"Uploading new file: {wake_relative} ... done",
                        ],
                        [
                            f"Uploading new file: ./{blocked_relative} ... done",
                            f"Uploading new file: ./{wake_relative} ... done",
                        ],
                    ],
                    timeout_seconds=180,
                )
            )
            recovered = recovery_notice_seen and recovery_uploads_seen
            details["recovery_evidence_seen"] = recovered
            details["recovery_notice_seen"] = recovery_notice_seen
            details["recovery_uploads_seen"] = recovery_uploads_seen
            details["recovery_upload_path_format"] = (
                "relative" if matched_upload_group == 0 else "dot-relative" if matched_upload_group == 1 else "not-matched"
            )
            details["monitor_alive_after_recovery"] = process.poll() is None
            details["recovery_segment_length"] = len(recovery_segment)

            if not recovered:
                return False, f"{scenario_id} did not resume and apply queued local changes after time recovery", details
            if process.poll() is not None:
                return False, f"{scenario_id} monitor exited during runtime time recovery", details
        finally:
            self._set_faketime_offset(control_file, 0)
            self._shutdown_monitor_process(process, details)

        final_verify_result, final_manifest = self._verify_remote_state(
            context,
            label=f"{scenario_id} final remote verification",
            root_name=root_name,
            verify_root=final_verify_root,
            verify_conf=conf_final_verify,
            stdout_file=final_verify_stdout,
            stderr_file=final_verify_stderr,
            manifest_file=final_manifest_file,
        )
        details["final_verify_returncode"] = final_verify_result.returncode
        blocked_verify_path = final_verify_root / blocked_relative
        wake_verify_path = final_verify_root / wake_relative
        details["blocked_file_present_after_recovery"] = blocked_relative in final_manifest
        details["wake_file_present_after_recovery"] = wake_relative in final_manifest
        details["blocked_file_content_matches"] = (
            blocked_verify_path.is_file() and blocked_verify_path.read_text(encoding="utf-8") == blocked_content
        )
        details["wake_file_content_matches"] = (
            wake_verify_path.is_file() and wake_verify_path.read_text(encoding="utf-8") == wake_content
        )
        self._write_metadata(metadata_file, details)

        if final_verify_result.returncode != 0:
            return False, f"{scenario_id} final remote verification failed with status {final_verify_result.returncode}", details
        if blocked_relative not in final_manifest or wake_relative not in final_manifest:
            return False, f"{scenario_id} recovered monitor did not upload all queued/recovery files", details
        if not details["blocked_file_content_matches"] or not details["wake_file_content_matches"]:
            return False, f"{scenario_id} recovered remote file content did not match", details

        return True, "running monitor suspended on unsafe time and resumed queued work after recovery", details

    def _scenario_sync_startup_blocked_exits(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        library: Path,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_id = "TA-0003"
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id
        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        sync_root = scenario_work_dir / "syncroot"
        conf_main = scenario_work_dir / "conf-main"
        control_file = scenario_state_dir / "faketime.rc"
        stdout_file = scenario_log_dir / "sync_stdout.log"
        stderr_file = scenario_log_dir / "sync_stderr.log"
        metadata_file = scenario_state_dir / "metadata.txt"

        reset_directory(sync_root)
        context.bootstrap_config_dir(conf_main)
        self._write_sync_config(conf_main, sync_root)

        root_name = f"ZZ_E2E_TC0077_{scenario_id}_{context.run_id}_{os.getpid()}"
        local_relative = f"{root_name}/must-not-upload.txt"
        write_text_file(sync_root / local_relative, "TC0077 TA-0003 must never enter sync while time is unsafe.\n")

        artifacts.extend(
            [
                str(stdout_file),
                str(stderr_file),
                str(metadata_file),
                str(control_file),
            ]
        )

        self._set_faketime_offset(control_file, self.CLOCK_SKEW_SECONDS)
        faketime_env = self._build_faketime_env(library, control_file)

        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} {scenario_id} blocked --sync: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root, env=faketime_env)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        self._set_faketime_offset(control_file, 0)

        combined_output = (result.stdout or "") + "\n" + (result.stderr or "")
        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": "bad time at --sync startup refuses synchronization and exits",
            "root_name": root_name,
            "local_relative": local_relative,
            "clock_skew_seconds": self.CLOCK_SKEW_SECONDS,
            "faketime_library": str(library),
            "returncode": result.returncode,
            "blocking_message_seen": self.BLOCKING_PATTERN in combined_output,
            "blocking_result_seen": self.BLOCKING_RESULT_PATTERN in combined_output,
            "sync_startup_blocked_message_seen": self.SYNC_STARTUP_BLOCKED_PATTERN in combined_output,
            "correction_guidance_seen": self.SYNC_CORRECTION_GUIDANCE_PATTERN in combined_output,
            "sync_started": "Starting a sync with Microsoft OneDrive" in combined_output,
            "sync_complete_reported": self.SYNC_COMPLETE_PATTERN in combined_output,
        }
        self._write_metadata(metadata_file, details)

        if result.returncode != 1:
            return False, f"{scenario_id} expected --sync to exit with status 1, got {result.returncode}", details
        if not details["blocking_message_seen"] or not details["blocking_result_seen"]:
            return False, f"{scenario_id} did not report the confirmed TIME_DRIFT_BLOCKING state", details
        if not details["sync_startup_blocked_message_seen"] or not details["correction_guidance_seen"]:
            return False, f"{scenario_id} did not provide the expected --sync blocking guidance", details
        if details["sync_started"]:
            return False, f"{scenario_id} entered synchronisation despite unsafe startup time", details
        if details["sync_complete_reported"]:
            return False, f"{scenario_id} incorrectly reported a completed sync after startup blocking", details

        return True, "bad startup time caused --sync to refuse synchronisation and exit non-zero", details

    def _scenario_sync_time_check_disabled_allows_sync(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        library: Path,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_id = "TA-0004"
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id
        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        sync_root = scenario_work_dir / "syncroot"
        final_verify_root = scenario_work_dir / "verify-final-root"
        conf_main = scenario_work_dir / "conf-main"
        conf_final_verify = scenario_work_dir / "conf-verify-final"
        control_file = scenario_state_dir / "faketime.rc"
        stdout_file = scenario_log_dir / "sync_stdout.log"
        stderr_file = scenario_log_dir / "sync_stderr.log"
        final_verify_stdout = scenario_log_dir / "final_verify_stdout.log"
        final_verify_stderr = scenario_log_dir / "final_verify_stderr.log"
        final_manifest_file = scenario_state_dir / "final_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        reset_directory(sync_root)
        context.bootstrap_config_dir(conf_main)
        self._write_sync_config(conf_main, sync_root)

        root_name = f"ZZ_E2E_TC0077_{scenario_id}_{context.run_id}_{os.getpid()}"
        local_relative = f"{root_name}/must-upload-with-time-check-disabled.txt"
        local_content = "TC0077 TA-0004 explicit --disable-time-check override permits this upload.\n"
        write_text_file(sync_root / local_relative, local_content)

        artifacts.extend(
            [
                str(stdout_file),
                str(stderr_file),
                str(final_verify_stdout),
                str(final_verify_stderr),
                str(final_manifest_file),
                str(metadata_file),
                str(control_file),
            ]
        )

        self._set_faketime_offset(control_file, self.CLOCK_SKEW_SECONDS)
        faketime_env = self._build_faketime_env(library, control_file)

        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--disable-time-check",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(
            f"Executing Test Case {self.case_id} {scenario_id} --sync with time check disabled: "
            f"{command_to_string(command)}"
        )
        try:
            result = run_command(command, cwd=context.repo_root, env=faketime_env)
        finally:
            self._set_faketime_offset(control_file, 0)

        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        combined_output = (result.stdout or "") + "\n" + (result.stderr or "")
        upload_seen = any(
            pattern in combined_output
            for pattern in (
                f"Uploading new file: {local_relative} ... done",
                f"Uploading new file: ./{local_relative} ... done",
            )
        )

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": "unsafe startup clock is explicitly ignored by --disable-time-check",
            "root_name": root_name,
            "local_relative": local_relative,
            "clock_skew_seconds": self.CLOCK_SKEW_SECONDS,
            "faketime_library": str(library),
            "returncode": result.returncode,
            "time_check_disabled_warning_seen": self.TIME_CHECK_DISABLED_WARNING_PATTERN in combined_output,
            "time_check_disabled_state_seen": self.TIME_CHECK_DISABLED_STATE_PATTERN in combined_output,
            "blocking_message_seen": self.BLOCKING_PATTERN in combined_output,
            "blocking_result_seen": self.BLOCKING_RESULT_PATTERN in combined_output,
            "sync_started": "Starting a sync with Microsoft OneDrive" in combined_output,
            "upload_seen": upload_seen,
            "sync_complete_reported": self.SYNC_COMPLETE_PATTERN in combined_output,
        }

        if result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} expected --sync to succeed with --disable-time-check, got {result.returncode}", details
        if not details["time_check_disabled_warning_seen"] or not details["time_check_disabled_state_seen"]:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not report that system-time validation was disabled", details
        if details["blocking_message_seen"] or details["blocking_result_seen"]:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} entered TIME_DRIFT_BLOCKING despite --disable-time-check", details
        if not details["sync_started"] or not details["upload_seen"] or not details["sync_complete_reported"]:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not complete normal synchronisation with the time check disabled", details

        final_verify_result, final_manifest = self._verify_remote_state(
            context,
            label=f"{scenario_id} final remote verification",
            root_name=root_name,
            verify_root=final_verify_root,
            verify_conf=conf_final_verify,
            stdout_file=final_verify_stdout,
            stderr_file=final_verify_stderr,
            manifest_file=final_manifest_file,
        )
        final_local_path = final_verify_root / local_relative
        details["final_verify_returncode"] = final_verify_result.returncode
        details["uploaded_file_present_remotely"] = local_relative in final_manifest
        details["uploaded_file_content_matches"] = (
            final_local_path.is_file() and final_local_path.read_text(encoding="utf-8") == local_content
        )
        self._write_metadata(metadata_file, details)

        if final_verify_result.returncode != 0:
            return False, f"{scenario_id} final remote verification failed with status {final_verify_result.returncode}", details
        if local_relative not in final_manifest:
            return False, f"{scenario_id} file was not present remotely after bypassed time validation", details
        if not details["uploaded_file_content_matches"]:
            return False, f"{scenario_id} uploaded file content did not match after verification", details

        return True, "--disable-time-check explicitly bypassed unsafe-time gating and allowed synchronisation", details

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0077",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        artifacts: list[str] = []
        details: dict[str, object] = {}

        library = self._find_libfaketime_mt()
        details["libfaketime_mt"] = str(library) if library is not None else ""
        if library is None:
            dependency_file = state_dir / "dependency-error.txt"
            write_text_file(
                dependency_file,
                "TC0077 requires the Fedora libfaketime package and libfaketimeMT.so.1.\n",
            )
            artifacts.append(str(dependency_file))
            return self.fail_result(
                self.case_id,
                self.name,
                "libfaketimeMT.so.1 was not found; install the Fedora libfaketime package in the E2E job",
                artifacts,
                details,
            )

        scenarios = [
            ("TA-0001", self._scenario_startup_monitor_blocked_then_recovers),
            ("TA-0002", self._scenario_running_monitor_blocks_then_recovers),
            ("TA-0003", self._scenario_sync_startup_blocked_exits),
            ("TA-0004", self._scenario_sync_time_check_disabled_allows_sync),
        ]
        scenarios = [
            (scenario_id, scenario_runner)
            for scenario_id, scenario_runner in scenarios
            if context.should_run_scenario(self.case_id, scenario_id)
        ]

        failed_scenarios: list[str] = []
        for scenario_id, scenario_runner in scenarios:
            try:
                passed, message, scenario_details = scenario_runner(
                    context,
                    case_work_dir,
                    case_log_dir,
                    state_dir,
                    library,
                    artifacts,
                )
            except Exception as exc:
                passed = False
                message = f"{scenario_id} raised an unexpected exception: {exc}"
                scenario_details = {"exception": repr(exc)}

            # Persist scenario details even when a scenario returned early on failure.
            self._write_metadata(state_dir / scenario_id / "metadata.txt", scenario_details)
            details[scenario_id] = scenario_details
            details[f"{scenario_id}_passed"] = passed
            details[f"{scenario_id}_message"] = message
            if not passed:
                failed_scenarios.append(scenario_id)

        details["executed_scenario_ids"] = [scenario_id for scenario_id, _ in scenarios]
        details["failed_scenario_ids"] = list(failed_scenarios)

        summary_file = state_dir / "scenario-summary.txt"
        write_text_file(
            summary_file,
            "\n".join(
                f"{scenario_id}: passed={details.get(f'{scenario_id}_passed')} "
                f"message={details.get(f'{scenario_id}_message')!r}"
                for scenario_id, _ in scenarios
            )
            + "\n",
        )
        artifacts.append(str(summary_file))

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        artifacts.append(str(metadata_file))

        if failed_scenarios:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failed_scenarios)} of {len(scenarios)} timestamp-authority scenarios failed: "
                + ", ".join(failed_scenarios),
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
