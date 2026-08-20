from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0074SafeBackupCleanResyncNoConflictValidation(SafeBackupCaseBase):
    case_id = "0074"
    name = "safeBackup clean resync no-conflict validation"
    description = (
        "Validate that repeating --resync against an already in-sync local file with no online change "
        "does not create a safeBackup or replace unchanged canonical content"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0074", ensure_refresh_token=True)
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

        root_name = f"ZZ_E2E_TC0074_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/already-in-sync.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        verify_file = verify_root / relative
        content = "TC0074 canonical content remains unchanged across a clean repeated resync\n"
        write_text_file(seed_file, content)

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        baseline_stdout, baseline_stderr = logs / "baseline_stdout.log", logs / "baseline_stderr.log"
        resync_stdout, resync_stderr = logs / "resync_stdout.log", logs / "resync_stderr.log"
        verify_stdout, verify_stderr = logs / "verify_stdout.log", logs / "verify_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [
            str(seed_stdout), str(seed_stderr),
            str(baseline_stdout), str(baseline_stderr),
            str(resync_stdout), str(resync_stderr),
            str(verify_stdout), str(verify_stderr),
            str(metadata_file),
        ]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

        seed = self._run_phase(
            context,
            label="seed remote",
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

        baseline = self._run_phase(
            context,
            label="establish tracked in-sync baseline",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_local,
                mode="download-only",
                resync=True,
            ),
            stdout_file=baseline_stdout,
            stderr_file=baseline_stderr,
        )
        details["baseline_returncode"] = baseline.returncode
        if baseline.returncode != 0 or not local_file.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason="Failed to establish the tracked in-sync baseline before repeated resync",
                artifacts=artifacts,
                details=details,
            )

        baseline_hash = self._hash_if_file(local_file)
        baseline_content = self._text_if_file(local_file)
        baseline_mtime = int(local_file.stat().st_mtime)
        baseline_backups = self._safe_backup_files_for(local_file)
        baseline_partials = self._partial_files_under(local_root / root_name)

        if baseline_content != content or not baseline_hash:
            details.update(
                {
                    "baseline_hash": baseline_hash,
                    "baseline_content": baseline_content,
                    "baseline_safe_backup_files": [str(p.relative_to(local_root)) for p in baseline_backups],
                    "baseline_partial_files": [str(p.relative_to(local_root)) for p in baseline_partials],
                }
            )
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason="Tracked baseline content does not match the remote seed",
                artifacts=artifacts,
                details=details,
            )

        if baseline_backups or baseline_partials:
            details.update(
                {
                    "baseline_safe_backup_files": [str(p.relative_to(local_root)) for p in baseline_backups],
                    "baseline_partial_files": [str(p.relative_to(local_root)) for p in baseline_partials],
                }
            )
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason="Baseline establishment unexpectedly created preservation artifacts",
                artifacts=artifacts,
                details=details,
            )

        # No local or online mutation occurs between the established baseline and this
        # second --resync. This is the exact regression condition being validated.
        repeated_resync = self._run_phase(
            context,
            label="repeat resync with unchanged local and online state",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_local,
                mode="sync",
                resync=True,
                verbose_count=2,
            ),
            stdout_file=resync_stdout,
            stderr_file=resync_stderr,
        )

        backups_after_resync = self._safe_backup_files_for(local_file)
        partials_after_resync = self._partial_files_under(local_root / root_name)
        details.update(
            {
                "repeated_resync_returncode": repeated_resync.returncode,
                "baseline_hash": baseline_hash,
                "baseline_content": baseline_content,
                "baseline_mtime": baseline_mtime,
                "canonical_exists_after_resync": local_file.is_file(),
                "canonical_hash_after_resync": self._hash_if_file(local_file),
                "canonical_content_after_resync": self._text_if_file(local_file),
                "canonical_mtime_after_resync": int(local_file.stat().st_mtime) if local_file.is_file() else -1,
                "safe_backup_files_after_resync": [str(p.relative_to(local_root)) for p in backups_after_resync],
                "partial_files_after_resync": [str(p.relative_to(local_root)) for p in partials_after_resync],
            }
        )

        verify = self._run_phase(
            context,
            label="verify unchanged remote",
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
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_hash": self._hash_if_file(verify_file),
                "verify_content": self._text_if_file(verify_file),
            }
        )
        self._write_metadata(metadata_file, details)

        if repeated_resync.returncode != 0:
            return self.fail_result(
                reason=f"Repeated clean resync failed with status {repeated_resync.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if not local_file.is_file():
            return self.fail_result(
                reason="Repeated clean resync removed the canonical local file",
                artifacts=artifacts,
                details=details,
            )
        if self._hash_if_file(local_file) != baseline_hash or self._text_if_file(local_file) != baseline_content:
            return self.fail_result(
                reason="Repeated clean resync changed canonical content despite no local or online change",
                artifacts=artifacts,
                details=details,
            )
        if backups_after_resync:
            return self.fail_result(
                reason="Repeated clean resync incorrectly created a safeBackup for an already in-sync unchanged file",
                artifacts=artifacts,
                details=details,
            )
        if partials_after_resync:
            return self.fail_result(
                reason="Repeated clean resync left an unexpected .partial file",
                artifacts=artifacts,
                details=details,
            )
        if verify.returncode != 0 or self._hash_if_file(verify_file) != baseline_hash or self._text_if_file(verify_file) != baseline_content:
            return self.fail_result(
                reason="Fresh verification did not confirm that the online file remained unchanged",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
