from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_1, REVISION_2, create_random_xlsx, mutate_xlsx_revision, validate_xlsx
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0070SafeBackupNewFileUploadCollisionValidation(SafeBackupCaseBase):
    case_id = "0070"
    name = "safeBackup new-file upload collision validation"
    description = (
        "Validate with passive TXT and real XLSX payloads that the no-database/new-local-file collision path "
        "under upload-only preserves older local files without replacing their canonical pathnames when newer "
        "same-name online files already exist"
    )

    XLSX_PAYLOAD_ROWS = 32

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
        text_relative = f"{root_name}/new-file-collision.txt"
        xlsx_relative = f"{root_name}/new-file-collision.xlsx"
        seed_text = seed_root / text_relative
        seed_xlsx = seed_root / xlsx_relative
        local_text = local_root / text_relative
        local_xlsx = local_root / xlsx_relative
        verify_text = verify_root / text_relative
        verify_xlsx = verify_root / xlsx_relative

        local_text_content = "TC0070 older local untracked file that must remain canonical under upload-only\n"
        remote_text_content = "TC0070 newer online file with the same pathname\n"
        write_text_file(local_text, local_text_content)

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0070:{os.getpid()}"
        generated = create_random_xlsx(
            local_xlsx,
            xlsx_seed,
            revision=REVISION_1,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0070 older untracked local workbook",
        )

        old_epoch = int(time.time()) - 3600
        os.utime(local_text, (old_epoch, old_epoch))
        os.utime(local_xlsx, (old_epoch, old_epoch))
        local_text_hash = self._hash_if_file(local_text)
        local_xlsx_hash = self._hash_if_file(local_xlsx)

        # Build the newer online XLSX from the exact local package, then change only the
        # revision marker. This gives the collision two realistic related document versions
        # while keeping the subject client completely untracked.
        time.sleep(2)
        write_text_file(seed_text, remote_text_content)
        seed_xlsx.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(local_xlsx, seed_xlsx)
        mutate_xlsx_revision(seed_xlsx, REVISION_1, REVISION_2)

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        collision_stdout, collision_stderr = logs / "collision_stdout.log", logs / "collision_stderr.log"
        verify_stdout, verify_stderr = logs / "verify_stdout.log", logs / "verify_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [
            str(seed_stdout), str(seed_stderr),
            str(collision_stdout), str(collision_stderr),
            str(verify_stdout), str(verify_stderr),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "root_name": root_name,
            "text_relative": text_relative,
            "xlsx_relative": xlsx_relative,
            "local_initial_mtime": old_epoch,
            "xlsx_seed": xlsx_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_local_xlsx_size": int(generated["size_bytes"]),
        }

        seed = self._run_phase(
            context,
            label="seed newer remote TXT/XLSX",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_seed,
                mode="upload-only",
                resync=True,
            ),
            stdout_file=seed_stdout,
            stderr_file=seed_stderr,
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Remote seed failed with status {seed.returncode}",
                artifacts=artifacts,
                details=details,
            )

        collision = self._run_phase(
            context,
            label="new-file upload-only collision",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_local,
                mode="upload-only",
                verbose_count=2,
            ),
            stdout_file=collision_stdout,
            stderr_file=collision_stderr,
        )

        text_backups = self._safe_backup_files_for(local_text)
        xlsx_backups = self._safe_backup_files_for(local_xlsx)
        local_xlsx_error = validate_xlsx(local_xlsx, REVISION_1) if local_xlsx.is_file() else "Local canonical XLSX is missing"
        backup_xlsx_error = validate_xlsx(xlsx_backups[0], REVISION_1) if len(xlsx_backups) == 1 else "Expected exactly one local XLSX safeBackup"
        details.update(
            {
                "collision_returncode": collision.returncode,
                "canonical_text_content": self._text_if_file(local_text),
                "canonical_text_hash": self._hash_if_file(local_text),
                "canonical_xlsx_hash": self._hash_if_file(local_xlsx),
                "canonical_xlsx_validation_error": local_xlsx_error,
                "local_text_hash": local_text_hash,
                "local_xlsx_hash": local_xlsx_hash,
                "text_safe_backup_files": [str(p.relative_to(local_root)) for p in text_backups],
                "text_safe_backup_hashes": [self._hash_if_file(p) for p in text_backups],
                "xlsx_safe_backup_files": [str(p.relative_to(local_root)) for p in xlsx_backups],
                "xlsx_safe_backup_hashes": [self._hash_if_file(p) for p in xlsx_backups],
                "xlsx_safe_backup_validation_error": backup_xlsx_error,
            }
        )

        verify = self._run_phase(
            context,
            label="verify remote",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_verify,
                mode="download-only",
                resync=True,
            ),
            stdout_file=verify_stdout,
            stderr_file=verify_stderr,
        )
        remote_text_backups = self._safe_backup_files_for(verify_text)
        remote_xlsx_backups = self._safe_backup_files_for(verify_xlsx)
        verify_xlsx_error = validate_xlsx(verify_xlsx, REVISION_2) if verify_xlsx.is_file() else "Verification canonical XLSX is missing"
        remote_xlsx_backup_errors = {
            str(path.relative_to(verify_root)): validate_xlsx(path, REVISION_1)
            for path in remote_xlsx_backups
        }
        remote_xlsx_backup_revision_seen = any(not error for error in remote_xlsx_backup_errors.values())
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_canonical_text": self._text_if_file(verify_text),
                "verify_xlsx_validation_error": verify_xlsx_error,
                "verify_text_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_text_backups],
                "verify_xlsx_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_xlsx_backups],
                "verify_xlsx_safe_backup_validation_errors": remote_xlsx_backup_errors,
                "verify_xlsx_safe_backup_revision_seen": remote_xlsx_backup_revision_seen,
            }
        )
        self._write_metadata(metadata_file, details)

        if collision.returncode != 0:
            return self.fail_result(
                reason=f"New-file upload collision phase failed with status {collision.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if self._text_if_file(local_text) != local_text_content or self._hash_if_file(local_text) != local_text_hash:
            return self.fail_result(
                reason="New-file upload-only collision removed or changed the local TXT canonical file",
                artifacts=artifacts,
                details=details,
            )
        if local_xlsx_error or self._hash_if_file(local_xlsx) != local_xlsx_hash:
            return self.fail_result(
                reason=f"New-file upload-only collision removed or changed the local XLSX canonical workbook: {local_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if len(text_backups) != 1 or self._hash_if_file(text_backups[0]) != local_text_hash:
            return self.fail_result(
                reason="New-file TXT collision did not preserve exactly one local safeBackup",
                artifacts=artifacts,
                details=details,
            )
        if len(xlsx_backups) != 1 or self._hash_if_file(xlsx_backups[0]) != local_xlsx_hash or backup_xlsx_error:
            return self.fail_result(
                reason=f"New-file XLSX collision did not preserve exactly one valid local safeBackup: {backup_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if verify.returncode != 0 or self._text_if_file(verify_text) != remote_text_content or verify_xlsx_error:
            return self.fail_result(
                reason=f"New-file upload-only collision unexpectedly replaced the newer online canonical TXT/XLSX files: {verify_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if not any(self._text_if_file(path) == local_text_content for path in remote_text_backups):
            return self.fail_result(
                reason="New-file TXT collision did not upload the preserved local safeBackup",
                artifacts=artifacts,
                details=details,
            )
        if not remote_xlsx_backup_revision_seen:
            return self.fail_result(
                reason="New-file XLSX collision did not upload the preserved revision-1 workbook under its safeBackup name",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
