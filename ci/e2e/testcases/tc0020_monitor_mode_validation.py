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
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0020MonitorModeValidation(E2ETestCase):
    case_id = "0020"
    name = "monitor mode validation"
    description = "Validate that monitor mode uploads local changes without manually re-running --sync"

    def _write_config(self, config_path: Path, app_log_dir: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0020 config\n"
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "5"\n'
            'monitor_fullscan_frequency = "1"\n',
        )

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0020"
        case_log_dir = context.logs_dir / "tc0020"
        state_dir = context.state_dir / "tc0020"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-main"
        verify_root = case_work_dir / "verifyroot"
        verify_conf = case_work_dir / "conf-verify"
        root_name = f"ZZ_E2E_TC0020_{context.run_id}_{os.getpid()}"
        app_log_dir = case_log_dir / "app-logs"

        write_text_file(sync_root / root_name / "baseline.txt", "baseline\n")

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config", app_log_dir)
        context.bootstrap_config_dir(verify_conf)
        write_onedrive_config(verify_conf / "config", "# tc0020 verify\n" 'bypass_data_preservation = "true"\n')

        stdout_file = case_log_dir / "monitor_stdout.log"
        stderr_file = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        command = [
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
            str(confdir),
        ]
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")

        with stdout_file.open("w", encoding="utf-8") as stdout_fp, stderr_file.open("w", encoding="utf-8") as stderr_fp:
            process = subprocess.Popen(
                command,
                cwd=str(context.repo_root),
                stdout=stdout_fp,
                stderr=stderr_fp,
                text=True,
            )
            time.sleep(8)
            write_text_file(sync_root / root_name / "monitor-added.txt", "added while monitor mode was running\n")
            time.sleep(12)
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(verify_conf),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"monitor_returncode={process.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                ]
            ) + "\n",
        )

        artifacts = [str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))
        details = {
            "monitor_returncode": process.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)

        if f"{root_name}/monitor-added.txt" not in remote_manifest:
            return TestResult.fail_result(self.case_id, self.name, "Monitor mode did not upload the file created while the process was running", artifacts, details)

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
