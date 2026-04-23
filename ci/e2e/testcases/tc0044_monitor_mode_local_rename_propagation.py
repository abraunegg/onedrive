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
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0044MonitorModeLocalRenamePropagation(MonitorModeTestCaseBase):
    case_id = "0044"
    name = "monitor mode local rename propagation"
    description = "Rename a local file while --monitor is active and validate correct behaviour"

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _build_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        return (
            "# tc0044 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "5"\n'
            'monitor_fullscan_frequency = "1"\n'
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
            if all(pattern in content for pattern in required_patterns):
                return True
            time.sleep(poll_interval)

        return False

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0044",
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

        root_name = f"ZZ_E2E_TC0044_{context.run_id}_{os.getpid()}"
        old_relative = f"{root_name}/original-name.txt"
        new_relative = f"{root_name}/renamed-file.txt"

        old_local_path = sync_root / old_relative
        new_local_path = sync_root / new_relative
        old_verify_path = verify_root / old_relative
        new_verify_path = verify_root / new_relative

        file_content = (
            "TC0044 monitor mode local rename propagation\n"
            "This content must survive the rename unchanged.\n"
        )

        context.bootstrap_config_dir(conf_main)
        write_text_file(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        context.bootstrap_config_dir(conf_verify)
        write_text_file(
            conf_verify / "config",
            (
                "# tc0044 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
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
            "old_relative": old_relative,
            "new_relative": new_relative,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
        }

        write_text_file(old_local_path, file_content)

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode

        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")

        process = None
        try:
            process, initial_sync_complete = self._launch_monitor_process(
                context,
                monitor_command,
                monitor_stdout,
                monitor_stderr,
            )
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

                old_local_path.rename(new_local_path)
                details["old_local_exists_after_rename"] = old_local_path.exists()
                details["new_local_exists_after_rename"] = new_local_path.is_file()

                required_patterns = [
                    f"[M] Local item moved: {old_relative} -> {new_relative}",
                    f"Moving {old_relative} to {new_relative}",
                ]
                mutation_processed = self._wait_for_monitor_patterns(
                    monitor_stdout,
                    required_patterns=required_patterns,
                    timeout_seconds=120,
                )
                details["mutation_processed"] = mutation_processed
                details["mutation_required_patterns"] = required_patterns

            self._shutdown_monitor_process(process, details)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=30)

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

        details["verify_old_exists"] = old_verify_path.exists()
        details["verify_new_exists"] = new_verify_path.is_file()
        details["verify_new_content"] = new_verify_path.read_text(encoding="utf-8") if new_verify_path.is_file() else ""

        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor mode did not process the local rename event before shutdown",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if old_verify_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains old filename: {old_relative}",
                artifacts,
                details,
            )

        if not new_verify_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing renamed file: {new_relative}",
                artifacts,
                details,
            )

        if details["verify_new_content"] != file_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Renamed file content did not match after remote verification",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)