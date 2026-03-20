from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


@dataclass
class ScenarioResult:
    scenario_id: str
    description: str
    passed: bool
    failure_message: str = ""
    artifacts: list[str] | None = None
    details: dict | None = None


class TestCase0021ResumableTransfersValidation(E2ETestCase):
    case_id = "0021"
    name = "resumable transfers validation"
    description = "Validate interrupted upload and download recovery for resumable transfers"

    LARGE_FILE_SIZE = 100 * 1024 * 1024
    RATE_LIMIT = "262144"

    def _write_config(
        self,
        config_path: Path,
        sync_dir: Path,
        app_log_dir: Path,
        force_session_upload: bool = False,
    ) -> None:
        lines = [
            "# tc0021 config",
            f'sync_dir = "{sync_dir}"',
            'bypass_data_preservation = "true"',
            'enable_logging = "true"',
            f'log_dir = "{app_log_dir}"',
            f'rate_limit = "{self.RATE_LIMIT}"',
        ]
        if force_session_upload:
            lines.append('force_session_upload = "true"')
        write_text_file(config_path, "\n".join(lines) + "\n")

    def _read_text_if_exists(self, path: Path) -> str:
        if not path.exists():
            return ""
        return path.read_text(encoding="utf-8", errors="replace")

    def _append_if_exists(self, artifacts: list[str], path: Path) -> None:
        if path.exists():
            artifacts.append(str(path))

    def _snapshot_tree(self, root: Path, output: Path) -> None:
        lines: list[str] = []
        if root.exists():
            for path in sorted(root.rglob("*")):
                rel = path.relative_to(root).as_posix()
                if path.is_dir():
                    lines.append(rel + "/")
                else:
                    lines.append(rel)
        write_text_file(output, "\n".join(lines) + ("\n" if lines else ""))

    def _create_large_file(self, path: Path, size_bytes: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        chunk = b"R" * (1024 * 1024)
        chunk_count = size_bytes // len(chunk)
        with path.open("wb") as fp:
            for _ in range(chunk_count):
                fp.write(chunk)
            remainder = size_bytes % len(chunk)
            if remainder:
                fp.write(chunk[:remainder])

    def _interrupt_process_and_capture(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        interrupt_delay: int = 5,
        wait_timeout: int = 60,
    ) -> tuple[int, str, str]:
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")

        with stdout_file.open("w", encoding="utf-8") as stdout_fp, stderr_file.open(
            "w", encoding="utf-8"
        ) as stderr_fp:
            process = subprocess.Popen(
                command,
                cwd=str(context.repo_root),
                stdout=stdout_fp,
                stderr=stderr_fp,
                text=True,
            )
            time.sleep(interrupt_delay)
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=wait_timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)

        stdout_text = self._read_text_if_exists(stdout_file)
        stderr_text = self._read_text_if_exists(stderr_file)
        return process.returncode, stdout_text, stderr_text

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

    def _contains_any_marker(self, text: str, markers: list[str]) -> bool:
        return any(marker in text for marker in markers)

    def _scenario_fail(
        self,
        scenario_id: str,
        description: str,
        message: str,
        artifacts: list[str],
        details: dict,
    ) -> ScenarioResult:
        return ScenarioResult(
            scenario_id=scenario_id,
            description=description,
            passed=False,
            failure_message=message,
            artifacts=artifacts,
            details=details,
        )

    def _scenario_pass(
        self,
        scenario_id: str,
        description: str,
        artifacts: list[str],
        details: dict,
    ) -> ScenarioResult:
        return ScenarioResult(
            scenario_id=scenario_id,
            description=description,
            passed=True,
            artifacts=artifacts,
            details=details,
        )

    def _run_upload_resume_scenario(
        self,
        context: E2EContext,
        root_name: str,
        sync_root: Path,
        verify_root: Path,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "RT-0001"
        description = "resumable upload"

        conf_main = scenario_work_dir / "conf-main"
        conf_verify = scenario_work_dir / "conf-verify"
        app_log_dir = scenario_log_dir / "app-logs"
        app_log_file = app_log_dir / "root.onedrive.log"

        reset_directory(conf_main)
        reset_directory(conf_verify)
        context.bootstrap_config_dir(conf_main)
        context.bootstrap_config_dir(conf_verify)

        self._write_config(conf_main / "config", sync_root, app_log_dir, force_session_upload=True)
        self._write_config(conf_verify / "config", verify_root, app_log_dir, force_session_upload=False)

        relative_path = f"{root_name}/{scenario_id}/session-large.bin"
        local_file = sync_root / relative_path
        self._create_large_file(local_file, self.LARGE_FILE_SIZE)

        phase1_stdout = scenario_log_dir / "phase1_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"

        local_tree_before = scenario_state_dir / "local_tree_before_phase1.txt"
        local_tree_after_phase1 = scenario_state_dir / "local_tree_after_phase1.txt"
        local_tree_after_phase2 = scenario_state_dir / "local_tree_after_phase2.txt"
        remote_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        self._snapshot_tree(sync_root, local_tree_before)

        upload_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_main),
        ]

        phase1_returncode, phase1_stdout_text, phase1_stderr_text = self._interrupt_process_and_capture(
            context,
            f"{scenario_id} phase 1",
            upload_command,
            phase1_stdout,
            phase1_stderr,
        )

        self._snapshot_tree(sync_root, local_tree_after_phase1)

        app_log_after_phase1 = self._read_text_if_exists(app_log_file)
        combined_phase1_output = (
            phase1_stdout_text
            + "\n"
            + phase1_stderr_text
            + "\n"
            + app_log_after_phase1
        )

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            upload_command,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        app_log_after_phase2 = self._read_text_if_exists(app_log_file)
        combined_phase2_output = (
            phase2_stdout_text
            + "\n"
            + phase2_stderr_text
            + "\n"
            + app_log_after_phase2
        )

        self._snapshot_tree(sync_root, local_tree_after_phase2)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_verify),
        ]

        verify_result = self._run_and_capture(
            context,
            f"{scenario_id} verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        safe_backup_matches = list(local_file.parent.glob("session-large-safeBackup-*"))

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_tree_before),
            str(local_tree_after_phase1),
            str(local_tree_after_phase2),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        self._append_if_exists(artifacts, app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "relative_path": relative_path,
            "large_size": self.LARGE_FILE_SIZE,
            "local_file_exists_after_phase1": local_file.exists(),
            "safe_backup_count_after_phase1": len(safe_backup_matches),
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"scenario_id={scenario_id}",
                    f"phase1_returncode={phase1_returncode}",
                    f"phase2_returncode={phase2_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"relative_path={relative_path}",
                    f"large_size={self.LARGE_FILE_SIZE}",
                    f"local_file_exists_after_phase1={local_file.exists()}",
                    f"safe_backup_count_after_phase1={len(safe_backup_matches)}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )

        crash_markers = [
            "Segmentation fault",
            "core dumped",
            "SIGSEGV",
            "std.conv.ConvException",
            "std.utf.UTFException",
            "Traceback",
        ]
        if self._contains_any_marker(combined_phase1_output, crash_markers):
            for marker in crash_markers:
                if marker in combined_phase1_output:
                    return self._scenario_fail(
                        scenario_id,
                        description,
                        f"Interrupted upload phase triggered client crash or exception: {marker}",
                        artifacts,
                        details,
                    )

        clean_shutdown_markers = [
            "Received termination signal",
            "attempting to cleanly shutdown application",
        ]
        if not self._contains_any_marker(combined_phase1_output, clean_shutdown_markers):
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted upload phase did not show clean shutdown handling after SIGINT",
                artifacts,
                details,
            )

        if not local_file.exists():
            return self._scenario_fail(
                scenario_id,
                description,
                "Source file no longer exists after interrupted upload; resumable upload continuity was broken",
                artifacts,
                details,
            )

        if safe_backup_matches:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Source file was renamed to safe-backup during interrupted upload: {safe_backup_matches[0].name}",
                artifacts,
                details,
            )

        if phase2_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Resumable upload recovery phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        upload_resume_markers = [
            "There are interrupted session uploads that need to be resumed",
            "Attempting to restore file upload session",
            "resume upload session",
            "resumed_upload",
        ]
        if not self._contains_any_marker(combined_phase2_output, upload_resume_markers):
            return self._scenario_fail(
                scenario_id,
                description,
                "Subsequent upload run did not show evidence of resumable upload recovery",
                artifacts,
                details,
            )

        if relative_path not in remote_manifest:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted resumable upload did not complete successfully on the subsequent run",
                artifacts,
                details,
            )

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def _run_download_resume_scenario(
        self,
        context: E2EContext,
        root_name: str,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "RT-0002"
        description = "resumable download"

        seed_root = scenario_work_dir / "seedroot"
        download_root = scenario_work_dir / "downloadroot"
        verify_root = scenario_work_dir / "verifyroot"

        conf_seed = scenario_work_dir / "conf-seed"
        conf_download = scenario_work_dir / "conf-download"
        conf_verify = scenario_work_dir / "conf-verify"

        app_log_dir = scenario_log_dir / "app-logs"
        app_log_file = app_log_dir / "root.onedrive.log"

        reset_directory(seed_root)
        reset_directory(download_root)
        reset_directory(verify_root)
        reset_directory(conf_seed)
        reset_directory(conf_download)
        reset_directory(conf_verify)

        context.bootstrap_config_dir(conf_seed)
        context.bootstrap_config_dir(conf_download)
        context.bootstrap_config_dir(conf_verify)

        self._write_config(conf_seed / "config", seed_root, app_log_dir, force_session_upload=True)
        self._write_config(conf_download / "config", download_root, app_log_dir, force_session_upload=False)
        self._write_config(conf_verify / "config", verify_root, app_log_dir, force_session_upload=False)

        relative_path = f"{root_name}/{scenario_id}/session-large.bin"
        seed_file = seed_root / relative_path
        self._create_large_file(seed_file, self.LARGE_FILE_SIZE)

        seed_stdout = scenario_log_dir / "seed_stdout.log"
        seed_stderr = scenario_log_dir / "seed_stderr.log"
        phase1_stdout = scenario_log_dir / "phase1_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"

        local_tree_before = scenario_state_dir / "local_tree_before_phase1.txt"
        local_tree_after_phase1 = scenario_state_dir / "local_tree_after_phase1.txt"
        local_tree_after_phase2 = scenario_state_dir / "local_tree_after_phase2.txt"
        local_tree_after_verify = scenario_state_dir / "local_tree_after_verify.txt"
        verify_manifest_file = scenario_state_dir / "verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_seed),
        ]
        seed_result = self._run_and_capture(
            context,
            f"{scenario_id} seed",
            seed_command,
            seed_stdout,
            seed_stderr,
        )

        if seed_result.returncode != 0:
            artifacts = [str(seed_stdout), str(seed_stderr)]
            details = {
                "scenario_id": scenario_id,
                "seed_returncode": seed_result.returncode,
                "relative_path": relative_path,
            }
            return self._scenario_fail(
                scenario_id,
                description,
                f"Seed upload phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        self._snapshot_tree(download_root, local_tree_before)

        download_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_download),
        ]

        phase1_returncode, phase1_stdout_text, phase1_stderr_text = self._interrupt_process_and_capture(
            context,
            f"{scenario_id} phase 1",
            download_command,
            phase1_stdout,
            phase1_stderr,
        )

        self._snapshot_tree(download_root, local_tree_after_phase1)

        app_log_after_phase1 = self._read_text_if_exists(app_log_file)
        combined_phase1_output = (
            phase1_stdout_text
            + "\n"
            + phase1_stderr_text
            + "\n"
            + app_log_after_phase1
        )

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            download_command,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        app_log_after_phase2 = self._read_text_if_exists(app_log_file)
        combined_phase2_output = (
            phase2_stdout_text
            + "\n"
            + phase2_stderr_text
            + "\n"
            + app_log_after_phase2
        )

        self._snapshot_tree(download_root, local_tree_after_phase2)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_verify),
        ]
        verify_result = self._run_and_capture(
            context,
            f"{scenario_id} verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        self._snapshot_tree(verify_root, local_tree_after_verify)

        downloaded_file = download_root / relative_path

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_tree_before),
            str(local_tree_after_phase1),
            str(local_tree_after_phase2),
            str(local_tree_after_verify),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        self._append_if_exists(artifacts, app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "seed_returncode": seed_result.returncode,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "relative_path": relative_path,
            "large_size": self.LARGE_FILE_SIZE,
            "downloaded_file_exists_after_phase2": downloaded_file.exists(),
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"scenario_id={scenario_id}",
                    f"seed_returncode={seed_result.returncode}",
                    f"phase1_returncode={phase1_returncode}",
                    f"phase2_returncode={phase2_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"relative_path={relative_path}",
                    f"large_size={self.LARGE_FILE_SIZE}",
                    f"downloaded_file_exists_after_phase2={downloaded_file.exists()}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )

        crash_markers = [
            "Segmentation fault",
            "core dumped",
            "SIGSEGV",
            "std.conv.ConvException",
            "std.utf.UTFException",
            "Traceback",
        ]
        if self._contains_any_marker(combined_phase1_output, crash_markers):
            for marker in crash_markers:
                if marker in combined_phase1_output:
                    return self._scenario_fail(
                        scenario_id,
                        description,
                        f"Interrupted download phase triggered client crash or exception: {marker}",
                        artifacts,
                        details,
                    )

        clean_shutdown_markers = [
            "Received termination signal",
            "attempting to cleanly shutdown application",
        ]
        if not self._contains_any_marker(combined_phase1_output, clean_shutdown_markers):
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted download phase did not show clean shutdown handling after SIGINT",
                artifacts,
                details,
            )

        if phase2_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Resumable download recovery phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Download verification phase failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        download_resume_markers = [
            "There are interrupted downloads that need to be resumed",
            "Attempting to resume file download using this 'resumable data' file",
            "resume file download",
            "resumed_download",
        ]
        if not self._contains_any_marker(combined_phase2_output, download_resume_markers):
            return self._scenario_fail(
                scenario_id,
                description,
                "Subsequent download run did not show evidence of resumable download recovery",
                artifacts,
                details,
            )

        if not downloaded_file.exists():
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted resumable download did not produce the expected local file on the subsequent run",
                artifacts,
                details,
            )

        if downloaded_file.stat().st_size != self.LARGE_FILE_SIZE:
            return self._scenario_fail(
                scenario_id,
                description,
                "Downloaded file size after resumed download did not match expected size",
                artifacts,
                details,
            )

        if relative_path not in verify_manifest:
            return self._scenario_fail(
                scenario_id,
                description,
                "Verification download did not contain the expected remote file",
                artifacts,
                details,
            )

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0021"
        case_log_dir = context.logs_dir / "tc0021"
        state_dir = context.state_dir / "tc0021"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        root_name = f"ZZ_E2E_TC0021_{context.run_id}_{os.getpid()}"

        upload_sync_root = case_work_dir / "upload-syncroot"
        upload_verify_root = case_work_dir / "upload-verifyroot"
        upload_work_dir = case_work_dir / "rt0001-upload"
        upload_log_dir = case_log_dir / "rt0001-upload"
        upload_state_dir = state_dir / "rt0001-upload"

        reset_directory(upload_sync_root)
        reset_directory(upload_verify_root)
        reset_directory(upload_work_dir)
        reset_directory(upload_log_dir)
        reset_directory(upload_state_dir)

        results: list[ScenarioResult] = []

        results.append(
            self._run_upload_resume_scenario(
                context,
                root_name,
                upload_sync_root,
                upload_verify_root,
                upload_work_dir,
                upload_log_dir,
                upload_state_dir,
            )
        )

        download_work_dir = case_work_dir / "rt0002-download"
        download_log_dir = case_log_dir / "rt0002-download"
        download_state_dir = state_dir / "rt0002-download"

        reset_directory(download_work_dir)
        reset_directory(download_log_dir)
        reset_directory(download_state_dir)

        results.append(
            self._run_download_resume_scenario(
                context,
                root_name,
                download_work_dir,
                download_log_dir,
                download_state_dir,
            )
        )

        failed = [result for result in results if not result.passed]
        artifacts: list[str] = []
        details: dict = {"root_name": root_name, "scenario_results": {}}

        for result in results:
            if result.artifacts:
                artifacts.extend(result.artifacts)
            if result.details:
                details["scenario_results"][result.scenario_id] = result.details

        deduped_artifacts = []
        seen = set()
        for artifact in artifacts:
            if artifact not in seen:
                deduped_artifacts.append(artifact)
                seen.add(artifact)

        summary_file = state_dir / "scenario_summary.txt"
        summary_lines = []
        for result in results:
            status = "PASS" if result.passed else "FAIL"
            line = f"{result.scenario_id} [{status}] {result.description}"
            if result.failure_message:
                line += f" — {result.failure_message}"
            summary_lines.append(line)
        write_text_file(summary_file, "\n".join(summary_lines) + "\n")
        deduped_artifacts.append(str(summary_file))

        if failed:
            failed_ids = ", ".join(result.scenario_id for result in failed)
            first_failure = failed[0].failure_message or "scenario failure"
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"{len(failed)} of {len(results)} resumable transfer scenarios failed: {failed_ids} — {first_failure}",
                deduped_artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, deduped_artifacts, details)