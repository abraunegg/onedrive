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


class TestCase0021ResumableTransfersValidation(E2ETestCase):
    case_id = "0021"
    name = "resumable transfers validation"
    description = "Validate interrupted upload recovery for a resumable session upload"

    LARGE_FILE_SIZE = 5 * 1024 * 1024

    def _write_config(self, config_path: Path, sync_dir: Path, app_log_dir: Path) -> None:
        write_text_file(
            config_path,
            (
                "# tc0021 config\n"
                f'sync_dir = "{sync_dir}"\n'
                'bypass_data_preservation = "true"\n'
                'enable_logging = "true"\n'
                f'log_dir = "{app_log_dir}"\n'
                'force_session_upload = "true"\n'
                'rate_limit = "262144"\n'
            ),
        )

    def _run_and_capture(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def _read_text_if_exists(self, path: Path) -> str:
        if not path.exists():
            return ""
        return path.read_text(encoding="utf-8", errors="replace")

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0021"
        case_log_dir = context.logs_dir / "tc0021"
        state_dir = context.state_dir / "tc0021"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-main"
        verify_root = case_work_dir / "verifyroot"
        verify_conf = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0021_{context.run_id}_{os.getpid()}"
        app_log_dir = case_log_dir / "app-logs"
        app_log_file = app_log_dir / "root.onedrive.log"

        large_file = sync_root / root_name / "session-large.bin"
        large_file.parent.mkdir(parents=True, exist_ok=True)
        large_file.write_bytes(b"R" * self.LARGE_FILE_SIZE)

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config", sync_root, app_log_dir)

        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config", verify_root, app_log_dir)

        phase1_stdout = case_log_dir / "phase1_stdout.log"
        phase1_stderr = case_log_dir / "phase1_stderr.log"
        phase2_stdout = case_log_dir / "phase2_stdout.log"
        phase2_stderr = case_log_dir / "phase2_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

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
            "--confdir",
            str(confdir),
        ]

        context.log(f"Executing Test Case {self.case_id} phase 1: {command_to_string(upload_command)}")
        with phase1_stdout.open("w", encoding="utf-8") as stdout_fp, phase1_stderr.open(
            "w", encoding="utf-8"
        ) as stderr_fp:
            process = subprocess.Popen(
                upload_command,
                cwd=str(context.repo_root),
                stdout=stdout_fp,
                stderr=stderr_fp,
                text=True,
            )
            time.sleep(5)
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)

        phase1_stdout_text = self._read_text_if_exists(phase1_stdout)
        phase1_stderr_text = self._read_text_if_exists(phase1_stderr)
        app_log_text_after_phase1 = self._read_text_if_exists(app_log_file)

        context.log(f"Executing Test Case {self.case_id} phase 2: {command_to_string(upload_command)}")
        phase2_result = run_command(upload_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)

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
            "--confdir",
            str(verify_conf),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        current_large_file_exists = large_file.exists()

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"phase1_returncode={process.returncode}",
                    f"phase2_returncode={phase2_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"large_size={self.LARGE_FILE_SIZE}",
                    f"large_file_exists_after_recovery={current_large_file_exists}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        details = {
            "phase1_returncode": process.returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
            "large_size": self.LARGE_FILE_SIZE,
            "large_file_exists_after_recovery": current_large_file_exists,
        }

        crash_markers = [
            "Segmentation fault",
            "core dumped",
            "SIGSEGV",
            "std.conv.ConvException",
            "std.utf.UTFException",
            "Traceback",
        ]

        combined_phase1_output = (
            phase1_stdout_text
            + "\n"
            + phase1_stderr_text
            + "\n"
            + app_log_text_after_phase1
        )

        for marker in crash_markers:
            if marker in combined_phase1_output:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"Interrupted upload phase triggered client crash or exception: {marker}",
                    artifacts,
                    details,
                )

        if phase2_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Resumable upload recovery phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if f"{root_name}/session-large.bin" not in remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Interrupted resumable upload did not complete successfully on the subsequent run",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)