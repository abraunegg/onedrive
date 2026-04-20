from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0043MonitorModeLocalDeletePropagation(E2ETestCase):
    case_id = "0043"
    name = "monitor mode local delete propagation"
    description = "Delete a local file under --monitor and validate the remote delete occurs as expected"

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _build_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        return (
            "# tc0043 config\n"
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
            case_dir_name="tc0043",
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

        root_name = f"ZZ_E2E_TC0043_{context.run_id}_{os.getpid()}"
        keep_relative = f"{root_name}/anchor.txt"
        delete_relative = f"{root_name}/delete-me.txt"

        keep_local_path = sync_root / keep_relative
        delete_local_path = sync_root / delete_relative

        keep_verify_path = verify_root / keep_relative
        delete_verify_path = verify_root / delete_relative

        keep_content = "TC0043 anchor\n"
        delete_content = (
            "TC0043 monitor mode local delete propagation\n"
            "This file should be removed while --monitor is active.\n"
        )

        context.bootstrap_config_dir(conf_main)
        write_text_file(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        context.bootstrap_config_dir(conf_verify)
        write_text_file(
            conf_verify / "config",
            (
                "# tc0043 verify\n"
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
            "keep_relative": keep_relative,
            "delete_relative": delete_relative,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
        }

        write_text_file(keep_local_path, keep_content)
        write_text_file(delete_local_path, delete_content)

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

        process: subprocess.Popen[str] | None = None
        try:
            with monitor_stdout.open("w", encoding="utf-8") as stdout_fp, monitor_stderr.open("w", encoding="utf-8") as stderr_fp:
                process = subprocess.Popen(
                    monitor_command,
                    cwd=str(context.repo_root),
                    stdout=stdout_fp,
                    stderr=stderr_fp,
                    text=True,
                )

                initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
                details["initial_sync_complete"] = initial_sync_complete

                if not initial_sync_complete:
                    details["monitor_returncode"] = process.returncode
                    self._write_metadata(metadata_file, details)
                    return self.fail_result(
                        self.case_id,
                        self.name,
                        "Monitor mode did not complete the initial sync within the expected time",
                        artifacts,
                        details,
                    )

                if delete_local_path.exists():
                    delete_local_path.unlink()

                details["local_deleted_exists_after_unlink"] = delete_local_path.exists()

                required_patterns = [
                    f"[M] Local item deleted: {delete_relative}",
                    f"Deleting item from Microsoft OneDrive: {delete_relative}",
                ]
                mutation_processed = self._wait_for_monitor_patterns(
                    monitor_stdout,
                    required_patterns=required_patterns,
                    timeout_seconds=120,
                )
                details["mutation_processed"] = mutation_processed
                details["mutation_required_patterns"] = required_patterns

                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=30)

                details["monitor_returncode"] = process.returncode
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

        details["verify_keep_exists"] = keep_verify_path.is_file()
        details["verify_deleted_exists"] = delete_verify_path.exists()

        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor mode did not process the local delete event before shutdown",
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

        if not keep_verify_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing retained anchor file: {keep_relative}",
                artifacts,
                details,
            )

        if delete_verify_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains deleted file: {delete_relative}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)