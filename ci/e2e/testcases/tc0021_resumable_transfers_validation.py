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

    # Use a larger file so the transfer is definitely active when interrupted.
    LARGE_FILE_SIZE = 100 * 1024 * 1024

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

    def _read_text_if_exists(self, path: Path) -> str:
        if not path.exists():
            return ""
        return path.read_text(encoding="utf-8", errors="replace")

    def _append_if_exists(self, artifacts: list[str], path: Path) -> None:
        if path.exists():
            artifacts.append(str(path))

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

        # Create a deterministic large file without huge memory allocation.
        chunk = b"R" * (1024 * 1024)
        with large_file.open("wb") as fp:
            for _ in range(self.LARGE_FILE_SIZE // len(chunk)):
                fp.write(chunk)

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
        local_tree_before_phase1 = state_dir / "local_tree_before_phase1.txt"
        local_tree_after_phase1 = state_dir / "local_tree_after_phase1.txt"
        local_tree_after_phase2 = state_dir / "local_tree_after_phase2.txt"

        def snapshot_tree(root: Path, output: Path) -> None:
            lines: list[str] = []
            if root.exists():
                for path in sorted(root.rglob("*")):
                    rel = path.relative_to(root).as_posix()
                    if path.is_dir():
                        lines.append(rel + "/")
                    else:
                        lines.append(rel)
            write_text_file(output, "\n".join(lines) + ("\n" if lines else ""))

        snapshot_tree(sync_root, local_tree_before_phase1)

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
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)

        snapshot_tree(sync_root, local_tree_after_phase1)

        phase1_stdout_text = self._read_text_if_exists(phase1_stdout)
        phase1_stderr_text = self._read_text_if_exists(phase1_stderr)
        app_log_text_after_phase1 = self._read_text_if_exists(app_log_file)

        combined_phase1_output = (
            phase1_stdout_text
            + "\n"
            + phase1_stderr_text
            + "\n"
            + app_log_text_after_phase1
        )

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(local_tree_before_phase1),
            str(local_tree_after_phase1),
        ]
        self._append_if_exists(artifacts, app_log_dir)

        details = {
            "phase1_returncode": process.returncode,
            "root_name": root_name,
            "large_size": self.LARGE_FILE_SIZE,
        }

        crash_markers = [
            "Segmentation fault",
            "core dumped",
            "SIGSEGV",
            "std.conv.ConvException",
            "std.utf.UTFException",
            "Traceback",
        ]
        for marker in crash_markers:
            if marker in combined_phase1_output:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"Interrupted upload phase triggered client crash or exception: {marker}",
                    artifacts,
                    details,
                )

        expected_shutdown_markers = [
            "Received termination signal",
            "attempting to cleanly shutdown application",
        ]
        if not any(marker in combined_phase1_output for marker in expected_shutdown_markers):
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Interrupted upload phase did not show clean shutdown handling after SIGINT",
                artifacts,
                details,
            )

        if not large_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Source file no longer exists after interrupted upload; resumable transfer continuity was broken",
                artifacts,
                details,
            )

        safe_backup_matches = list(large_file.parent.glob("session-large-safeBackup-*"))
        if safe_backup_matches:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Source file was renamed to safe-backup during interrupted upload: {safe_backup_matches[0].name}",
                artifacts,
                details,
            )

        context.log(f"Executing Test Case {self.case_id} phase 2: {command_to_string(upload_command)}")
        phase2_result = run_command(upload_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)

        snapshot_tree(sync_root, local_tree_after_phase2)

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

        artifacts.extend(
            [
                str(phase2_stdout),
                str(phase2_stderr),
                str(verify_stdout),
                str(verify_stderr),
                str(remote_manifest_file),
                str(local_tree_after_phase2),
            ]
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        combined_phase2_output = phase2_stdout_text + "\n" + phase2_stderr_text

        details.update(
            {
                "phase2_returncode": phase2_result.returncode,
                "verify_returncode": verify_result.returncode,
                "large_file_exists_after_phase2": large_file.exists(),
            }
        )

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
                    f"large_file_exists_after_phase1={large_file.exists()}",
                    f"safe_backup_count_after_phase1={len(safe_backup_matches)}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )
        artifacts.append(str(metadata_file))

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

        resume_markers = [
            "There are interrupted session uploads that need to be resumed",
            "Attempting to restore file upload session",
            "attempting to resume upload session",
            "resume upload session",
        ]
        if not any(marker in combined_phase2_output or marker in app_log_text_after_phase1 for marker in resume_markers):
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Subsequent run did not show evidence of resumable session recovery",
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