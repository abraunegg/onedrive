from __future__ import annotations

import os
import re
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


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
    INTERRUPT_THRESHOLD_PERCENT = 15.0
    TRANSFER_WAIT_TIMEOUT = 300
    PROCESS_EXIT_TIMEOUT = 120

    # Apply a 10 MB/s rate limit for both upload and download scenarios
    # so that the phase1 interrupt lands during an active resumable transfer.
    RATE_LIMIT: str | None = "10485760"

    def _write_config(
        self,
        config_path: Path,
        sync_dir: Path,
        app_log_dir: Path,
    ) -> None:
        lines = [
            "# tc0021 config",
            f'sync_dir = "{sync_dir}"',
            'enable_logging = "true"',
            f'log_dir = "{app_log_dir}"',
        ]
        if self.RATE_LIMIT:
            lines.append(f'rate_limit = "{self.RATE_LIMIT}"')
        write_onedrive_config(config_path, "\n".join(lines) + "\n")

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

    def _contains_any_marker(self, text: str, markers: list[str]) -> bool:
        return any(marker in text for marker in markers)

    def _extract_max_progress_percent(self, text: str) -> float:
        max_percent = 0.0
        for match in re.finditer(r"(?P<percent>\d{1,3}(?:\.\d+)?)\s*%", text):
            try:
                value = float(match.group("percent"))
            except ValueError:
                continue
            if 0.0 <= value <= 100.0 and value > max_percent:
                max_percent = value
        return max_percent

    def _build_transfer_observation(
        self,
        stdout_file: Path,
        stderr_file: Path,
        app_log_file: Path,
        target_filename: str,
    ) -> tuple[str, float]:
        stdout_text = self._read_text_if_exists(stdout_file)
        stderr_text = self._read_text_if_exists(stderr_file)
        app_log_text = self._read_text_if_exists(app_log_file)

        combined_text = stdout_text + "\n" + stderr_text + "\n" + app_log_text

        relevant_lines: list[str] = []
        for line in combined_text.splitlines():
            if target_filename in line:
                relevant_lines.append(line)

        relevant_text = "\n".join(relevant_lines)
        max_percent = 0.0

        if relevant_text:
            max_percent = self._extract_max_progress_percent(relevant_text)

        if max_percent == 0.0:
            max_percent = self._extract_max_progress_percent(combined_text)

        return combined_text, max_percent

    def _interrupt_process_at_transfer_threshold(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        app_log_file: Path,
        target_filename: str,
        threshold_percent: float,
        wait_timeout: int,
        exit_timeout: int,
    ) -> tuple[int, str, str, bool, float]:
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")

        threshold_reached = False
        observed_max_percent = 0.0

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

            start_time = time.time()

            while True:
                if process.poll() is not None:
                    break

                _, current_max = self._build_transfer_observation(
                    stdout_file,
                    stderr_file,
                    app_log_file,
                    target_filename,
                )

                if current_max > observed_max_percent:
                    observed_max_percent = current_max

                if current_max >= threshold_percent:
                    threshold_reached = True
                    process.send_signal(signal.SIGINT)
                    break

                if (time.time() - start_time) > wait_timeout:
                    process.send_signal(signal.SIGINT)
                    break

                time.sleep(1)

            try:
                process.wait(timeout=exit_timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)

        stdout_text = self._read_text_if_exists(stdout_file)
        stderr_text = self._read_text_if_exists(stderr_file)
        return process.returncode, stdout_text, stderr_text, threshold_reached, observed_max_percent

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

    def _phase_app_log_file(self, phase_app_log_dir: Path) -> Path:
        return phase_app_log_dir / "root.onedrive.log"

    def _phase1_interruption_acceptable(self, combined_phase1_output: str, phase1_returncode: int) -> tuple[bool, str]:
        crash_markers = [
            "Segmentation fault",
            "core dumped",
            "SIGSEGV",
        ]

        crash_marker_seen = ""
        for marker in crash_markers:
            if marker in combined_phase1_output:
                crash_marker_seen = marker
                break

        interrupted_as_expected = (
            phase1_returncode in (-2, 130, -11, 139)
            or crash_marker_seen in {"Segmentation fault", "core dumped", "SIGSEGV"}
        )

        return interrupted_as_expected, crash_marker_seen

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

        conf_dir = scenario_work_dir / "conf"
        verify_conf_dir = scenario_work_dir / "verify-conf"

        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        app_log_file = self._phase_app_log_file(app_log_dir)
        verify_app_log_file = self._phase_app_log_file(verify_app_log_dir)

        reset_directory(conf_dir)
        reset_directory(verify_conf_dir)
        context.bootstrap_config_dir(conf_dir)
        context.bootstrap_config_dir(verify_conf_dir)

        self._write_config(conf_dir / "config", sync_root, app_log_dir)
        self._write_config(verify_conf_dir / "config", verify_root, verify_app_log_dir)

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
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        (
            phase1_returncode,
            phase1_stdout_text,
            phase1_stderr_text,
            threshold_reached,
            observed_max_percent,
        ) = self._interrupt_process_at_transfer_threshold(
            context,
            f"{scenario_id} phase 1",
            upload_command,
            phase1_stdout,
            phase1_stderr,
            app_log_file,
            "session-large.bin",
            self.INTERRUPT_THRESHOLD_PERCENT,
            self.TRANSFER_WAIT_TIMEOUT,
            self.PROCESS_EXIT_TIMEOUT,
        )

        self._snapshot_tree(sync_root, local_tree_after_phase1)

        phase1_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase1_output = phase1_stdout_text + "\n" + phase1_stderr_text + "\n" + phase1_app_log_text

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            upload_command,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        phase2_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase2_output = phase2_stdout_text + "\n" + phase2_stderr_text + "\n" + phase2_app_log_text

        self._snapshot_tree(sync_root, local_tree_after_phase2)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(verify_conf_dir),
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

        interrupted_as_expected, crash_marker_seen = self._phase1_interruption_acceptable(
            combined_phase1_output,
            phase1_returncode,
        )

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
        self._append_if_exists(artifacts, verify_app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "relative_path": relative_path,
            "large_size": self.LARGE_FILE_SIZE,
            "interrupt_threshold_percent": self.INTERRUPT_THRESHOLD_PERCENT,
            "threshold_reached": threshold_reached,
            "observed_max_percent": observed_max_percent,
            "phase1_crash_marker_seen": crash_marker_seen,
            "phase1_interrupted_as_expected": interrupted_as_expected,
            "rate_limit": self.RATE_LIMIT or "disabled",
            "conf_dir": str(conf_dir),
            "app_log_file": str(app_log_file),
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
                    f"interrupt_threshold_percent={self.INTERRUPT_THRESHOLD_PERCENT}",
                    f"threshold_reached={threshold_reached}",
                    f"observed_max_percent={observed_max_percent}",
                    f"phase1_crash_marker_seen={crash_marker_seen}",
                    f"phase1_interrupted_as_expected={interrupted_as_expected}",
                    f"rate_limit={self.RATE_LIMIT or 'disabled'}",
                    f"conf_dir={conf_dir}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )

        if not threshold_reached:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted upload phase never reached {self.INTERRUPT_THRESHOLD_PERCENT}% transfer progress before shutdown; observed maximum was {observed_max_percent:.2f}%",
                artifacts,
                details,
            )

        if not interrupted_as_expected:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted upload phase did not terminate as expected after threshold was reached; return code was {phase1_returncode}",
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
            "Attempting to restore file upload session using this session data file",
            "Attempting to restore file upload session",
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

        seed_conf_dir = scenario_work_dir / "seed-conf"
        conf_dir = scenario_work_dir / "conf"
        verify_conf_dir = scenario_work_dir / "verify-conf"

        seed_app_log_dir = scenario_log_dir / "seed-app-logs"
        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        seed_app_log_file = self._phase_app_log_file(seed_app_log_dir)
        app_log_file = self._phase_app_log_file(app_log_dir)
        verify_app_log_file = self._phase_app_log_file(verify_app_log_dir)

        reset_directory(seed_root)
        reset_directory(download_root)
        reset_directory(verify_root)
        reset_directory(seed_conf_dir)
        reset_directory(conf_dir)
        reset_directory(verify_conf_dir)

        context.bootstrap_config_dir(seed_conf_dir)
        context.bootstrap_config_dir(conf_dir)
        context.bootstrap_config_dir(verify_conf_dir)

        self._write_config(seed_conf_dir / "config", seed_root, seed_app_log_dir)
        self._write_config(conf_dir / "config", download_root, app_log_dir)
        self._write_config(verify_conf_dir / "config", verify_root, verify_app_log_dir)

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
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(seed_conf_dir),
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
            self._append_if_exists(artifacts, seed_app_log_dir)
            details = {
                "scenario_id": scenario_id,
                "seed_returncode": seed_result.returncode,
                "relative_path": relative_path,
                "rate_limit": self.RATE_LIMIT or "disabled",
            }
            return self._scenario_fail(
                scenario_id,
                description,
                f"Seed upload phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        # Prepare a clean local download state before phase1.
        # This is the only point in TC0021 where resync/resync-auth should be used.
        reset_directory(download_root)

        items_db = conf_dir / "items.sqlite3"
        items_db_wal = conf_dir / "items.sqlite3-wal"
        items_db_shm = conf_dir / "items.sqlite3-shm"
        for db_file in (items_db, items_db_wal, items_db_shm):
            if db_file.exists():
                db_file.unlink()

        self._snapshot_tree(download_root, local_tree_before)

        download_command_phase1 = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        (
            phase1_returncode,
            phase1_stdout_text,
            phase1_stderr_text,
            threshold_reached,
            observed_max_percent,
        ) = self._interrupt_process_at_transfer_threshold(
            context,
            f"{scenario_id} phase 1",
            download_command_phase1,
            phase1_stdout,
            phase1_stderr,
            app_log_file,
            "session-large.bin",
            self.INTERRUPT_THRESHOLD_PERCENT,
            self.TRANSFER_WAIT_TIMEOUT,
            self.PROCESS_EXIT_TIMEOUT,
        )

        self._snapshot_tree(download_root, local_tree_after_phase1)

        phase1_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase1_output = phase1_stdout_text + "\n" + phase1_stderr_text + "\n" + phase1_app_log_text

        download_command_phase2 = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            download_command_phase2,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        phase2_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase2_output = phase2_stdout_text + "\n" + phase2_stderr_text + "\n" + phase2_app_log_text

        self._snapshot_tree(download_root, local_tree_after_phase2)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(verify_conf_dir),
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

        interrupted_as_expected, crash_marker_seen = self._phase1_interruption_acceptable(
            combined_phase1_output,
            phase1_returncode,
        )

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
        self._append_if_exists(artifacts, seed_app_log_dir)
        self._append_if_exists(artifacts, app_log_dir)
        self._append_if_exists(artifacts, verify_app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "seed_returncode": seed_result.returncode,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "relative_path": relative_path,
            "large_size": self.LARGE_FILE_SIZE,
            "interrupt_threshold_percent": self.INTERRUPT_THRESHOLD_PERCENT,
            "threshold_reached": threshold_reached,
            "observed_max_percent": observed_max_percent,
            "downloaded_file_exists_after_phase2": downloaded_file.exists(),
            "phase1_crash_marker_seen": crash_marker_seen,
            "phase1_interrupted_as_expected": interrupted_as_expected,
            "rate_limit": self.RATE_LIMIT or "disabled",
            "conf_dir": str(conf_dir),
            "app_log_file": str(app_log_file),
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
                    f"interrupt_threshold_percent={self.INTERRUPT_THRESHOLD_PERCENT}",
                    f"threshold_reached={threshold_reached}",
                    f"observed_max_percent={observed_max_percent}",
                    f"downloaded_file_exists_after_phase2={downloaded_file.exists()}",
                    f"phase1_crash_marker_seen={crash_marker_seen}",
                    f"phase1_interrupted_as_expected={interrupted_as_expected}",
                    f"rate_limit={self.RATE_LIMIT or 'disabled'}",
                    f"conf_dir={conf_dir}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )

        if not threshold_reached:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted download phase never reached {self.INTERRUPT_THRESHOLD_PERCENT}% transfer progress before shutdown; observed maximum was {observed_max_percent:.2f}%",
                artifacts,
                details,
            )

        if not interrupted_as_expected:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted download phase did not terminate as expected after threshold was reached; return code was {phase1_returncode}",
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
            "Attempting to resume file download using this resumable data file",
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