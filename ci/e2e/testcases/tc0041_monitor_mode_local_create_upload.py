from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, large_xlsx_relative
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0041MonitorModeLocalCreateUpload(MonitorModeTestCaseBase):
    case_id = "0041"
    name = "monitor mode local create upload"
    description = "Start --monitor, create passive TXT and real XLSX files, and validate both upload without restarting the client"

    XLSX_PAYLOAD_ROWS = 32

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _build_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        return (
            "# tc0041 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n'
        )

    def _read_stdout(self, stdout_file: Path) -> str:
        if not stdout_file.exists():
            return ""
        try:
            return stdout_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def _wait_for_initial_sync_complete(
        self,
        stdout_file: Path,
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds
        marker = "Sync with Microsoft OneDrive is complete"

        while time.time() < deadline:
            if marker in self._read_stdout(stdout_file):
                return True
            time.sleep(poll_interval)

        return False

    def _wait_for_monitor_patterns(
        self,
        stdout_file: Path,
        required_patterns: list[str],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            content = self._read_stdout(stdout_file)
            if all(self._monitor_output_contains(content, pattern) for pattern in required_patterns):
                return True
            time.sleep(poll_interval)

        return False

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0041",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0041_{context.run_id}_{os.getpid()}"
        baseline_relative = f"{root_name}/baseline.txt"
        created_relative = f"{root_name}/monitor-created.xlsx"
        created_text_relative = f"{root_name}/monitor-created.txt"

        baseline_local_path = sync_root / baseline_relative
        created_local_path = sync_root / created_relative
        created_verify_path = verify_root / created_relative
        created_text_local_path = sync_root / created_text_relative
        created_text_verify_path = verify_root / created_text_relative

        baseline_content = "TC0041 baseline\n"
        created_text_content = (
            "TC0041 monitor mode local create upload\n"
            "This passive TXT file was created while --monitor was already running.\n"
        )
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0041:{os.getpid()}"

        context.bootstrap_config_dir(conf_main)
        write_text_file(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        context.bootstrap_config_dir(conf_verify)
        write_text_file(
            conf_verify / "config",
            (
                "# tc0041 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(baseline_local_path, baseline_content)

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        details: dict[str, object] = {
            "root_name": root_name,
            "baseline_relative": baseline_relative,
            "created_relative": created_relative,
            "created_text_relative": created_text_relative,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
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
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")

        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
        )
        try:
            details["initial_sync_complete"] = initial_sync_complete

            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor mode did not complete the initial sync within the expected time",
                    artifacts,
                    details,
                )

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            context.log(f"Test Case {self.case_id}: creating local XLSX while monitor is running: {created_relative}")
            generated = create_random_xlsx_pair(
                created_local_path,
                xlsx_seed,
                revision=REVISION_0,
                payload_rows=self.XLSX_PAYLOAD_ROWS,
                title="TC0041 monitor local create upload workbook",
            )
            details["generated_size"] = int(generated["size_bytes"])
            details["created_local_exists_after_write"] = created_local_path.is_file()
            details["created_local_validation_error"] = validate_xlsx_pair(created_local_path, REVISION_0)
            write_text_file(created_text_local_path, created_text_content)
            details["created_text_exists_after_write"] = created_text_local_path.is_file()

            required_patterns = [
                f"Uploading new file: {created_relative} ... done",
                f"Uploading new file: {large_xlsx_relative(created_relative)} ... done",
                f"Uploading new file: {created_text_relative} ... done",
            ]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=180,
            )
            post_mutation_sync_complete = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["post_mutation_sync_complete"] = post_mutation_sync_complete
            details["mutation_processed"] = mutation_processed
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_required_patterns"] = required_patterns
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

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)

        details["verify_created_exists"] = created_verify_path.is_file()
        details["verify_created_text_exists"] = created_text_verify_path.is_file()
        verify_text_content = created_text_verify_path.read_text(encoding="utf-8") if created_text_verify_path.is_file() else ""
        details["verify_created_text_content"] = verify_text_content
        verify_validation_error = (
            validate_xlsx_pair(created_verify_path, REVISION_0)
            if created_verify_path.is_file()
            else "Verification XLSX is missing"
        )
        details["verify_validation_error"] = verify_validation_error

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if not created_verify_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing created file: {created_relative}",
                artifacts,
                details,
            )

        if not created_text_verify_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing created passive TXT file: {created_text_relative}",
                artifacts,
                details,
            )

        if verify_text_content != created_text_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Created passive TXT content did not match after remote verification",
                artifacts,
                details,
            )

        if verify_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification returned an invalid or stale XLSX workbook: {verify_validation_error}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
