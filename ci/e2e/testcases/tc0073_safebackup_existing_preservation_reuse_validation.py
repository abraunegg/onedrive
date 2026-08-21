from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0073SafeBackupExistingPreservationReuseValidation(SafeBackupCaseBase):
    case_id = "0073"
    name = "safeBackup existing preservation reuse validation"
    description = (
        "Validate that an existing same-device safeBackup with identical content and metadata is "
        "reused during replacement instead of creating another numbered backup"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0073", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        updater_root = work / "updaterroot"
        for root in (seed_root, local_root, updater_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_updater = work / "conf-updater"
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_updater, updater_root)

        root_name = f"ZZ_E2E_TC0073_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/reuse-existing-backup.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        updater_file = updater_root / relative

        baseline = "TC0073 baseline remote content\n"
        local_conflict = "TC0073 local conflicting content already preserved in safeBackup-0001\n"
        remote_newer = "TC0073 newer remote replacement\n"
        write_text_file(seed_file, baseline)

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        initial_stdout, initial_stderr = logs / "initial_stdout.log", logs / "initial_stderr.log"
        update_stdout, update_stderr = logs / "update_stdout.log", logs / "update_stderr.log"
        reconcile_stdout, reconcile_stderr = logs / "reconcile_stdout.log", logs / "reconcile_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [
            str(seed_stdout), str(seed_stderr), str(initial_stdout), str(initial_stderr),
            str(update_stdout), str(update_stderr), str(reconcile_stdout), str(reconcile_stderr),
            str(metadata_file),
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
            return self.fail_result(reason="Failed to establish baseline before existing-safeBackup reuse validation", artifacts=artifacts, details=details)

        time.sleep(2)
        write_text_file(local_file, local_conflict)
        local_hash = self._hash_if_file(local_file)

        existing_backup = self._device_safe_backup_name(local_file, 1)
        existing_backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(local_file, existing_backup)
        if self._hash_if_file(existing_backup) != local_hash:
            details["existing_backup_hash"] = self._hash_if_file(existing_backup)
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Harness failed to create the matching safeBackup precondition", artifacts=artifacts, details=details)

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

        reconcile = self._run_phase(
            context, label="reconcile with existing preservation",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, verbose_count=2),
            stdout_file=reconcile_stdout, stderr_file=reconcile_stderr,
        )
        backups = self._safe_backup_files_for(local_file)
        combined = reconcile.stdout + "\n" + reconcile.stderr
        reuse_marker_seen = "reusing existing preservation" in combined
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "reuse_marker_seen": reuse_marker_seen,
                "canonical_content": self._text_if_file(local_file),
                "safe_backup_files": [str(p.relative_to(local_root)) for p in backups],
                "safe_backup_hashes": [self._hash_if_file(p) for p in backups],
                "local_hash": local_hash,
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(reason=f"Reconciliation failed with status {reconcile.returncode}", artifacts=artifacts, details=details)
        if not local_file.is_file() or self._text_if_file(local_file) != remote_newer:
            return self.fail_result(reason="Canonical file did not converge to the newer remote content", artifacts=artifacts, details=details)
        if len(backups) != 1:
            return self.fail_result(reason=f"Existing safeBackup was not reused; expected one backup, found {len(backups)}", artifacts=artifacts, details=details)
        if backups[0] != existing_backup or self._hash_if_file(backups[0]) != local_hash:
            return self.fail_result(reason="The original matching safeBackup was not retained as the sole preservation copy", artifacts=artifacts, details=details)
        if not reuse_marker_seen:
            return self.fail_result(reason="Reconciliation state was correct but the intended existing-safeBackup reuse path was not observed", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
