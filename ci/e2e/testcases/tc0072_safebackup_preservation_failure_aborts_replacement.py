from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0072SafeBackupPreservationFailureAbortsReplacement(SafeBackupCaseBase):
    case_id = "0072"
    name = "safeBackup preservation failure aborts replacement"
    description = (
        "Force safeBackup allocation failure by occupying all 1000 valid backup names and verify "
        "the validated remote replacement is refused while the canonical local bytes remain intact"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0072", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        updater_root = work / "updaterroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, local_root, updater_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_updater = work / "conf-updater"
        conf_verify = work / "conf-verify"
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(
            context,
            conf_local,
            local_root,
            extra_lines=['skip_file = "~*|.~*|*.tmp|*.swp|*.partial|*-safeBackup-*"'],
        )
        self._prepare_config(context, conf_updater, updater_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0072_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/exhausted-backup-names.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        updater_file = updater_root / relative
        verify_file = verify_root / relative

        baseline = "TC0072 baseline remote content\n"
        local_conflict = "TC0072 local bytes must survive forced safeBackup creation failure\n"
        remote_newer = "TC0072 newer remote replacement must NOT overwrite when preservation fails\n"
        write_text_file(seed_file, baseline)

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        initial_stdout, initial_stderr = logs / "initial_stdout.log", logs / "initial_stderr.log"
        update_stdout, update_stderr = logs / "update_stdout.log", logs / "update_stderr.log"
        reconcile_stdout, reconcile_stderr = logs / "reconcile_stdout.log", logs / "reconcile_stderr.log"
        verify_stdout, verify_stderr = logs / "verify_stdout.log", logs / "verify_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [
            str(seed_stdout), str(seed_stderr), str(initial_stdout), str(initial_stderr),
            str(update_stdout), str(update_stderr), str(reconcile_stdout), str(reconcile_stderr),
            str(verify_stdout), str(verify_stderr), str(metadata_file),
        ]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

        seed = self._run_phase(
            context, label="seed",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=seed_stdout, stderr_file=seed_stderr,
        )
        initial = self._run_phase(
            context, label="initial download",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True),
            stdout_file=initial_stdout, stderr_file=initial_stderr,
        )
        details.update({"seed_returncode": seed.returncode, "initial_returncode": initial.returncode})
        if seed.returncode != 0 or initial.returncode != 0 or self._text_if_file(local_file) != baseline:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Failed to establish baseline before preservation-failure injection", artifacts=artifacts, details=details)

        time.sleep(2)
        write_text_file(local_file, local_conflict)
        local_hash = self._hash_if_file(local_file)
        time.sleep(2)
        write_text_file(updater_file, remote_newer)

        update = self._run_phase(
            context, label="remote update",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_updater, mode="upload-only", resync=True),
            stdout_file=update_stdout, stderr_file=update_stderr,
        )
        details["remote_update_returncode"] = update.returncode
        if update.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote update failed with status {update.returncode}", artifacts=artifacts, details=details)

        # Deterministically exhaust the exact 0001..1000 name range used by safeBackup().
        # Empty placeholder files deliberately cannot match the non-empty canonical file,
        # so findMatchingSafeBackup() cannot reuse one of them as a valid preservation.
        for counter in range(1, 1001):
            candidate = self._device_safe_backup_name(local_file, counter)
            candidate.parent.mkdir(parents=True, exist_ok=True)
            candidate.write_bytes(b"")

        reconcile = self._run_phase(
            context, label="forced preservation failure",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, verbose_count=2),
            stdout_file=reconcile_stdout, stderr_file=reconcile_stderr,
        )
        details["reconcile_returncode"] = reconcile.returncode
        combined_reconcile = reconcile.stdout + "\n" + reconcile.stderr
        allocation_failure_seen = "Unique file name could not be found after 1000 attempts" in combined_reconcile
        replacement_refused_seen = "refusing to replace the canonical file" in combined_reconcile
        details.update(
            {
                "allocation_failure_seen": allocation_failure_seen,
                "replacement_refused_seen": replacement_refused_seen,
                "canonical_exists_after_failure": local_file.is_file(),
                "canonical_content_after_failure": self._text_if_file(local_file),
                "canonical_hash_after_failure": self._hash_if_file(local_file),
                "local_hash": local_hash,
                "partial_files_after_failure": [str(p.relative_to(local_root)) for p in self._partial_files_under(local_root / root_name)],
            }
        )

        verify = self._run_phase(
            context, label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=verify_stdout, stderr_file=verify_stderr,
        )
        details.update({"verify_returncode": verify.returncode, "verify_content": self._text_if_file(verify_file)})
        self._write_metadata(metadata_file, details)

        if not allocation_failure_seen:
            return self.fail_result(reason="Fault injection did not exhaust the safeBackup filename range as intended", artifacts=artifacts, details=details)
        if not replacement_refused_seen:
            return self.fail_result(reason="Application did not report that replacement was refused after preservation failure", artifacts=artifacts, details=details)
        if not local_file.is_file() or self._hash_if_file(local_file) != local_hash or self._text_if_file(local_file) != local_conflict:
            return self.fail_result(reason="Canonical local file was lost or changed after safeBackup preservation failure", artifacts=artifacts, details=details)
        if self._partial_files_under(local_root / root_name):
            return self.fail_result(reason="Preservation failure left an unexpected staged replacement behind", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._text_if_file(verify_file) != remote_newer:
            return self.fail_result(reason="Remote authoritative file changed unexpectedly during local preservation failure handling", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
