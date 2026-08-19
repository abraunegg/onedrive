from __future__ import annotations

import os
import re
import signal
import subprocess
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0067SafeBackupInterruptedReplacementValidation(SafeBackupCaseBase):
    case_id = "0067"
    name = "safeBackup interrupted replacement validation"
    description = (
        "Interrupt an active remote replacement download and prove the pre-existing canonical "
        "file remains present and unchanged until a later successful commit"
    )

    BASELINE_SIZE = 32 * 1024 * 1024
    REMOTE_REPLACEMENT_SIZE = 80 * 1024 * 1024
    RATE_LIMIT = "5242880"  # 5 MiB/s; deliberately leaves time to interrupt the transfer.
    INTERRUPT_THRESHOLD = 15.0
    WAIT_TIMEOUT = 300

    def _read_transfer_text(self, stdout_file: Path, stderr_file: Path, app_log_dir: Path) -> str:
        parts: list[str] = []
        for path in (stdout_file, stderr_file):
            if path.is_file():
                parts.append(path.read_text(encoding="utf-8", errors="replace"))
        if app_log_dir.exists():
            for path in sorted(app_log_dir.glob("*.onedrive.log")):
                parts.append(path.read_text(encoding="utf-8", errors="replace"))
        return "\n".join(parts)

    def _max_percent(self, text: str) -> float:
        value = 0.0
        for match in re.finditer(r"(?P<pct>\d{1,3}(?:\.\d+)?)\s*%", text):
            try:
                pct = float(match.group("pct"))
            except ValueError:
                continue
            if 0.0 <= pct <= 100.0:
                value = max(value, pct)
        return value

    def _interrupt_active_download(
        self,
        context: E2EContext,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
    ) -> tuple[int, bool, float, str]:
        context.log(f"Executing Test Case {self.case_id} interrupted replacement: {command_to_string(command)}")
        threshold_reached = False
        observed_max = 0.0

        with stdout_file.open("w", encoding="utf-8") as stdout_fp, stderr_file.open("w", encoding="utf-8") as stderr_fp:
            process = subprocess.Popen(
                command,
                cwd=str(context.repo_root),
                stdout=stdout_fp,
                stderr=stderr_fp,
                text=True,
            )
            started = time.time()
            while process.poll() is None:
                transfer_text = self._read_transfer_text(stdout_file, stderr_file, app_log_dir)
                observed_max = max(observed_max, self._max_percent(transfer_text))
                if observed_max >= self.INTERRUPT_THRESHOLD:
                    threshold_reached = True
                    process.send_signal(signal.SIGINT)
                    break
                if time.time() - started > self.WAIT_TIMEOUT:
                    process.send_signal(signal.SIGINT)
                    break
                time.sleep(0.25)

            try:
                returncode = process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                process.kill()
                returncode = process.wait(timeout=30)

        combined = self._read_transfer_text(stdout_file, stderr_file, app_log_dir)
        return returncode, threshold_reached, observed_max, combined

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0067", ensure_refresh_token=True)
        work = layout.work_dir
        logs = layout.log_dir
        state = layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        updater_root = work / "updaterroot"
        for root in (seed_root, local_root, updater_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_updater = work / "conf-updater"
        app_log_dir = logs / "local-app"
        reset_directory(app_log_dir)

        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(
            context,
            conf_local,
            local_root,
            extra_lines=[
                'enable_logging = "true"',
                f'log_dir = "{app_log_dir}"',
                f'rate_limit = "{self.RATE_LIMIT}"',
                'force_xfer_abort = "true"',
            ],
        )
        self._prepare_config(context, conf_updater, updater_root)

        root_name = f"ZZ_E2E_TC0067_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/large-conflict.bin"
        seed_file = seed_root / relative
        local_file = local_root / relative
        updater_file = updater_root / relative

        self._create_exact_size_file(seed_file, self.BASELINE_SIZE, b"A")

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        initial_stdout, initial_stderr = logs / "initial_stdout.log", logs / "initial_stderr.log"
        update_stdout, update_stderr = logs / "update_stdout.log", logs / "update_stderr.log"
        interrupt_stdout, interrupt_stderr = logs / "interrupt_stdout.log", logs / "interrupt_stderr.log"
        resume_stdout, resume_stderr = logs / "resume_stdout.log", logs / "resume_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [
            str(seed_stdout), str(seed_stderr), str(initial_stdout), str(initial_stderr),
            str(update_stdout), str(update_stderr), str(interrupt_stdout), str(interrupt_stderr),
            str(resume_stdout), str(resume_stderr), str(app_log_dir), str(metadata_file),
        ]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

        seed = self._run_phase(
            context,
            label="seed",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=seed_stdout,
            stderr_file=seed_stderr,
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Seed upload failed with status {seed.returncode}", artifacts=artifacts, details=details)

        initial = self._run_phase(
            context,
            label="initial download",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True),
            stdout_file=initial_stdout,
            stderr_file=initial_stderr,
        )
        details["initial_returncode"] = initial.returncode
        if initial.returncode != 0 or not local_file.is_file() or local_file.stat().st_size != self.BASELINE_SIZE:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Initial baseline download failed", artifacts=artifacts, details=details)

        time.sleep(2)
        self._create_exact_size_file(local_file, self.BASELINE_SIZE, b"C")
        local_conflict_hash = self._hash_if_file(local_file)

        time.sleep(2)
        self._create_exact_size_file(updater_file, self.REMOTE_REPLACEMENT_SIZE, b"B")
        remote_hash = self._hash_if_file(updater_file)
        update = self._run_phase(
            context,
            label="remote update",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_updater, mode="upload-only", resync=True),
            stdout_file=update_stdout,
            stderr_file=update_stderr,
        )
        details["remote_update_returncode"] = update.returncode
        if update.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote update failed with status {update.returncode}", artifacts=artifacts, details=details)

        # The same configured application log is used by the initial baseline download and
        # the interrupted replacement phase. Clear it between phases so progress and the
        # "Downloading file ... done" marker can only belong to the replacement transfer
        # currently being observed. This mirrors the phase-isolated transfer observation
        # used by TC0021 and avoids treating the baseline download as the replacement.
        reset_directory(app_log_dir)

        interrupt_command = self._single_directory_command(context, root_name=root_name, config_dir=conf_local)
        rc, threshold_reached, observed_max, combined_interrupt = self._interrupt_active_download(
            context,
            interrupt_command,
            interrupt_stdout,
            interrupt_stderr,
            app_log_dir,
        )

        backups_after_interrupt = self._safe_backup_files_for(local_file)
        details.update(
            {
                "interrupt_returncode": rc,
                "threshold_reached": threshold_reached,
                "observed_max_percent": observed_max,
                "canonical_exists_after_interrupt": local_file.is_file(),
                "canonical_hash_after_interrupt": self._hash_if_file(local_file),
                "local_conflict_hash": local_conflict_hash,
                "remote_hash": remote_hash,
                "safe_backups_after_interrupt": [str(p.relative_to(local_root)) for p in backups_after_interrupt],
                "partial_files_after_interrupt": [str(p.relative_to(local_root)) for p in self._partial_files_under(local_root / root_name)],
                "completed_download_marker_seen_before_interrupt": f"Downloading file: {relative} ... done" in combined_interrupt,
            }
        )

        if not threshold_reached:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Replacement download never reached {self.INTERRUPT_THRESHOLD}% before interruption", artifacts=artifacts, details=details)
        if details["completed_download_marker_seen_before_interrupt"]:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Replacement completed before the harness interruption landed", artifacts=artifacts, details=details)
        if not local_file.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Canonical filename disappeared after interrupted replacement", artifacts=artifacts, details=details)
        if self._hash_if_file(local_file) != local_conflict_hash:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Canonical bytes changed during an interrupted replacement", artifacts=artifacts, details=details)
        if any(self._hash_if_file(path) != local_conflict_hash for path in backups_after_interrupt):
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Interrupted replacement left a safeBackup that does not match the preserved canonical bytes", artifacts=artifacts, details=details)

        resume = self._run_phase(
            context,
            label="resume replacement",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local),
            stdout_file=resume_stdout,
            stderr_file=resume_stderr,
        )
        details["resume_returncode"] = resume.returncode
        backups_after_resume = self._safe_backup_files_for(local_file)
        details.update(
            {
                "canonical_exists_after_resume": local_file.is_file(),
                "canonical_hash_after_resume": self._hash_if_file(local_file),
                "safe_backups_after_resume": [str(p.relative_to(local_root)) for p in backups_after_resume],
                "safe_backup_hashes_after_resume": [self._hash_if_file(p) for p in backups_after_resume],
                "partial_files_after_resume": [str(p.relative_to(local_root)) for p in self._partial_files_under(local_root / root_name)],
            }
        )
        self._write_metadata(metadata_file, details)

        if resume.returncode != 0:
            return self.fail_result(reason=f"Replacement recovery run failed with status {resume.returncode}", artifacts=artifacts, details=details)
        if not local_file.is_file() or self._hash_if_file(local_file) != remote_hash:
            return self.fail_result(reason="Successful retry did not commit the authoritative remote bytes to the canonical filename", artifacts=artifacts, details=details)
        if len(backups_after_resume) != 1 or self._hash_if_file(backups_after_resume[0]) != local_conflict_hash:
            return self.fail_result(reason="Successful retry did not preserve exactly one safeBackup containing the displaced local bytes", artifacts=artifacts, details=details)
        if self._partial_files_under(local_root / root_name):
            return self.fail_result(reason="Successful retry left unexpected .partial files behind", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
