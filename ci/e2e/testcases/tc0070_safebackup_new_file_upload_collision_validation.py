from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0070SafeBackupNewFileUploadCollisionValidation(SafeBackupCaseBase):
    case_id = "0070"
    name = "safeBackup new-file upload collision validation"
    description = (
        "Validate the no-database/new-local-file collision path when upload-only discovers a newer "
        "same-name online file: preserve locally without removing the canonical pathname"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0070", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, local_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_verify = work / "conf-verify"
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0070_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/new-file-collision.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        verify_file = verify_root / relative

        local_content = "TC0070 older local untracked file that must remain canonical under upload-only\n"
        remote_content = "TC0070 newer online file with the same pathname\n"
        write_text_file(local_file, local_content)
        old_epoch = int(time.time()) - 3600
        os.utime(local_file, (old_epoch, old_epoch))
        local_hash = self._hash_if_file(local_file)

        time.sleep(2)
        write_text_file(seed_file, remote_content)

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        collision_stdout, collision_stderr = logs / "collision_stdout.log", logs / "collision_stderr.log"
        verify_stdout, verify_stderr = logs / "verify_stdout.log", logs / "verify_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [str(seed_stdout), str(seed_stderr), str(collision_stdout), str(collision_stderr), str(verify_stdout), str(verify_stderr), str(metadata_file)]
        details: dict[str, object] = {"root_name": root_name, "relative": relative, "local_initial_mtime": old_epoch}

        seed = self._run_phase(
            context, label="seed remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=seed_stdout, stderr_file=seed_stderr,
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote seed failed with status {seed.returncode}", artifacts=artifacts, details=details)

        collision = self._run_phase(
            context, label="new-file upload-only collision",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="upload-only", verbose_count=2),
            stdout_file=collision_stdout, stderr_file=collision_stderr,
        )
        details["collision_returncode"] = collision.returncode
        backups = self._safe_backup_files_for(local_file)
        details.update(
            {
                "canonical_exists": local_file.is_file(),
                "canonical_content": self._text_if_file(local_file),
                "canonical_hash": self._hash_if_file(local_file),
                "local_hash": local_hash,
                "safe_backup_files": [str(p.relative_to(local_root)) for p in backups],
                "safe_backup_hashes": [self._hash_if_file(p) for p in backups],
            }
        )

        verify = self._run_phase(
            context, label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=verify_stdout, stderr_file=verify_stderr,
        )
        remote_backups = self._safe_backup_files_for(verify_file)
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_canonical_content": self._text_if_file(verify_file),
                "verify_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_backups],
                "verify_safe_backup_hashes": [self._hash_if_file(p) for p in remote_backups],
            }
        )
        self._write_metadata(metadata_file, details)

        if collision.returncode != 0:
            return self.fail_result(reason=f"New-file upload collision phase failed with status {collision.returncode}", artifacts=artifacts, details=details)
        if not local_file.is_file() or self._text_if_file(local_file) != local_content:
            return self.fail_result(reason="New-file upload-only collision removed or replaced the local canonical file", artifacts=artifacts, details=details)
        if len(backups) != 1 or self._hash_if_file(backups[0]) != local_hash:
            return self.fail_result(reason="New-file collision did not preserve exactly one local safeBackup", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._text_if_file(verify_file) != remote_content:
            return self.fail_result(reason="New-file upload-only collision unexpectedly replaced the newer online canonical file", artifacts=artifacts, details=details)
        if not any(self._hash_if_file(path) == local_hash for path in remote_backups):
            return self.fail_result(reason="New-file collision did not upload the preserved local safeBackup", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
