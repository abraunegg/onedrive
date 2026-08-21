from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0068SafeBackupUploadOnlyConflictValidation(SafeBackupCaseBase):
    case_id = "0068"
    name = "safeBackup upload-only conflict validation"
    description = (
        "Validate that upload-only conflict handling preserves a local older version without "
        "removing the canonical filename when a newer online version already exists"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0068", ensure_refresh_token=True)
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
        for conf, root in (
            (conf_seed, seed_root),
            (conf_local, local_root),
            (conf_updater, updater_root),
            (conf_verify, verify_root),
        ):
            self._prepare_config(context, conf, root)

        root_name = f"ZZ_E2E_TC0068_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/tracked-conflict.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        updater_file = updater_root / relative
        verify_file = verify_root / relative

        baseline = "TC0068 baseline\n"
        local_conflict = "TC0068 local upload-only conflict that must remain canonical locally\n"
        remote_newer = "TC0068 newer online content that upload-only must not download\n"
        write_text_file(seed_file, baseline)

        phase_files = {
            label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log")
            for label in ("seed", "initial", "remote_update", "upload_only", "verify")
        }
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

        seed = self._run_phase(
            context, label="seed",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1],
        )
        initial = self._run_phase(
            context, label="initial download",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True),
            stdout_file=phase_files["initial"][0], stderr_file=phase_files["initial"][1],
        )
        details.update({"seed_returncode": seed.returncode, "initial_returncode": initial.returncode})
        if seed.returncode != 0 or initial.returncode != 0 or self._text_if_file(local_file) != baseline:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Failed to establish tracked local/remote baseline", artifacts=artifacts, details=details)

        time.sleep(2)
        write_text_file(local_file, local_conflict)
        local_hash = self._hash_if_file(local_file)
        time.sleep(2)
        write_text_file(updater_file, remote_newer)

        update = self._run_phase(
            context, label="remote update",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_updater, mode="upload-only", resync=True),
            stdout_file=phase_files["remote_update"][0], stderr_file=phase_files["remote_update"][1],
        )
        details["remote_update_returncode"] = update.returncode
        if update.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote update failed with status {update.returncode}", artifacts=artifacts, details=details)

        upload_only = self._run_phase(
            context, label="upload-only conflict",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="upload-only"),
            stdout_file=phase_files["upload_only"][0], stderr_file=phase_files["upload_only"][1],
        )
        details["upload_only_returncode"] = upload_only.returncode
        backups = self._safe_backup_files_for(local_file)
        details.update(
            {
                "canonical_exists": local_file.is_file(),
                "canonical_content": self._text_if_file(local_file),
                "canonical_hash": self._hash_if_file(local_file),
                "local_conflict_hash": local_hash,
                "safe_backup_files": [str(p.relative_to(local_root)) for p in backups],
                "safe_backup_hashes": [self._hash_if_file(p) for p in backups],
            }
        )

        verify = self._run_phase(
            context, label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1],
        )
        details["verify_returncode"] = verify.returncode
        remote_backups = self._safe_backup_files_for(verify_file)
        details.update(
            {
                "verify_canonical_content": self._text_if_file(verify_file),
                "verify_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_backups],
                "verify_safe_backup_hashes": [self._hash_if_file(p) for p in remote_backups],
            }
        )
        self._write_metadata(metadata_file, details)

        if upload_only.returncode != 0:
            return self.fail_result(reason=f"Upload-only conflict phase failed with status {upload_only.returncode}", artifacts=artifacts, details=details)
        if not local_file.is_file() or self._text_if_file(local_file) != local_conflict:
            return self.fail_result(reason="Upload-only conflict handling removed or replaced the local canonical file", artifacts=artifacts, details=details)
        if len(backups) != 1 or self._hash_if_file(backups[0]) != local_hash:
            return self.fail_result(reason="Upload-only conflict did not preserve exactly one local safeBackup of the canonical bytes", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._text_if_file(verify_file) != remote_newer:
            return self.fail_result(reason="Upload-only conflict unexpectedly changed the newer remote canonical file", artifacts=artifacts, details=details)
        if not any(self._hash_if_file(path) == local_hash for path in remote_backups):
            return self.fail_result(reason="Preserved local conflict was not uploaded remotely under its safeBackup name", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
