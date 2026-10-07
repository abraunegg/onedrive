from __future__ import annotations

import os

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import compute_quickxor_hash_file, reset_directory, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, xlsx_pair_hashes, xlsx_pair_mtimes, xlsx_pair_sizes, xlsx_pair_backup_files, xlsx_pair_all_files
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0074SafeBackupCleanResyncNoConflictValidation(SafeBackupCaseBase):
    case_id = "0074"
    name = "safeBackup clean resync no-conflict validation"
    description = (
        "Validate with passive-text and real XLSX payloads that repeating --resync against already in-sync "
        "local files with no online change does not create safeBackup artifacts or replace unchanged canonical content"
    )

    XLSX_PAYLOAD_ROWS = 32

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
        text_relative = f"{root_name}/already-in-sync.txt"
        xlsx_relative = f"{root_name}/already-in-sync.xlsx"

        seed_text_file = seed_root / text_relative
        local_text_file = local_root / text_relative
        verify_text_file = verify_root / text_relative
        seed_xlsx_file = seed_root / xlsx_relative
        local_xlsx_file = local_root / xlsx_relative
        verify_xlsx_file = verify_root / xlsx_relative

        text_content = "TC0074 canonical content remains unchanged across a clean repeated resync\n"
        write_text_file(seed_text_file, text_content)

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0074:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx_file,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0074 clean repeated resync workbook",
        )
        generated_xlsx_hashes = xlsx_pair_hashes(seed_xlsx_file, compute_quickxor_hash_file)

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
        details: dict[str, object] = {
            "root_name": root_name,
            "text_relative": text_relative,
            "xlsx_relative": xlsx_relative,
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_xlsx_size": int(generated["size_bytes"]),
            "generated_xlsx_hashes": generated_xlsx_hashes,
        }

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
        if baseline.returncode != 0 or not local_text_file.is_file() or not xlsx_pair_all_files(local_xlsx_file):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason="Failed to establish both tracked in-sync baselines before repeated resync",
                artifacts=artifacts,
                details=details,
            )

        baseline_text_hash = self._hash_if_file(local_text_file)
        baseline_text_content = self._text_if_file(local_text_file)
        baseline_text_mtime = int(local_text_file.stat().st_mtime)
        baseline_xlsx_validation_error = validate_xlsx_pair(local_xlsx_file, REVISION_0)
        baseline_xlsx_hashes = xlsx_pair_hashes(local_xlsx_file, self._hash_if_file)
        baseline_xlsx_mtimes = xlsx_pair_mtimes(local_xlsx_file)

        baseline_xlsx_backups = xlsx_pair_backup_files(local_xlsx_file, self._safe_backup_files_for)
        baseline_backups = self._safe_backup_files_for(local_text_file)
        baseline_partials = self._partial_files_under(local_root / root_name)
        details.update(
            {
                "baseline_text_hash": baseline_text_hash,
                "baseline_text_content": baseline_text_content,
                "baseline_text_mtime": baseline_text_mtime,
                "baseline_xlsx_validation_error": baseline_xlsx_validation_error,
                "baseline_xlsx_hashes": baseline_xlsx_hashes,
                "baseline_xlsx_sizes": xlsx_pair_sizes(local_xlsx_file),
                "baseline_xlsx_mtimes": baseline_xlsx_mtimes,
                "microsoft_changed_seed_xlsx_bytes": {label: baseline_xlsx_hashes[label] != generated_xlsx_hashes[label] for label in baseline_xlsx_hashes},
            }
        )

        if baseline_text_content != text_content or not baseline_text_hash:
            details.update(
                {
                    "baseline_safe_backup_files": [str(p.relative_to(local_root)) for p in baseline_backups],
                    "baseline_partial_files": [str(p.relative_to(local_root)) for p in baseline_partials],
                }
            )
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason="Tracked passive-text baseline content does not match the remote seed",
                artifacts=artifacts,
                details=details,
            )

        if baseline_xlsx_validation_error or not all(baseline_xlsx_hashes.values()):
            details.update(
                {
                    "baseline_safe_backup_files": [str(p.relative_to(local_root)) for p in baseline_backups],
                    "baseline_partial_files": [str(p.relative_to(local_root)) for p in baseline_partials],
                }
            )
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Tracked XLSX baseline is not a valid revision-0 workbook: {baseline_xlsx_validation_error}",
                artifacts=artifacts,
                details=details,
            )

        if baseline_backups or any(baseline_xlsx_backups.values()) or baseline_partials:
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

        xlsx_backups_after_resync = xlsx_pair_backup_files(local_xlsx_file, self._safe_backup_files_for)
        backups_after_resync = self._safe_backup_files_for(local_text_file)
        partials_after_resync = self._partial_files_under(local_root / root_name)
        canonical_xlsx_validation_error = (
            validate_xlsx_pair(local_xlsx_file, REVISION_0)
            if local_xlsx_file.is_file()
            else "Canonical XLSX is missing"
        )
        details.update(
            {
                "repeated_resync_returncode": repeated_resync.returncode,
                "canonical_text_exists_after_resync": local_text_file.is_file(),
                "canonical_text_hash_after_resync": self._hash_if_file(local_text_file),
                "canonical_text_content_after_resync": self._text_if_file(local_text_file),
                "canonical_text_mtime_after_resync": int(local_text_file.stat().st_mtime) if local_text_file.is_file() else -1,
                "canonical_xlsx_exists_after_resync": local_xlsx_file.is_file(),
                "canonical_xlsx_validation_error_after_resync": canonical_xlsx_validation_error,
                "canonical_xlsx_hashes_after_resync": xlsx_pair_hashes(local_xlsx_file, self._hash_if_file),
                "canonical_xlsx_mtimes_after_resync": xlsx_pair_mtimes(local_xlsx_file),
                "safe_backup_files_after_resync": [str(p.relative_to(local_root)) for p in backups_after_resync],
                "xlsx_safe_backup_files_after_resync": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in xlsx_backups_after_resync.items()},
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
        verify_xlsx_validation_error = (
            validate_xlsx_pair(verify_xlsx_file, REVISION_0)
            if verify_xlsx_file.is_file()
            else "Verification XLSX is missing"
        )
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_text_hash": self._hash_if_file(verify_text_file),
                "verify_text_content": self._text_if_file(verify_text_file),
                "verify_xlsx_hashes": xlsx_pair_hashes(verify_xlsx_file, self._hash_if_file),
                "verify_xlsx_validation_error": verify_xlsx_validation_error,
            }
        )
        self._write_metadata(metadata_file, details)

        if repeated_resync.returncode != 0:
            return self.fail_result(
                reason=f"Repeated clean resync failed with status {repeated_resync.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if not local_text_file.is_file() or not xlsx_pair_all_files(local_xlsx_file):
            return self.fail_result(
                reason="Repeated clean resync removed one or more canonical local files",
                artifacts=artifacts,
                details=details,
            )
        if self._hash_if_file(local_text_file) != baseline_text_hash or self._text_if_file(local_text_file) != baseline_text_content:
            return self.fail_result(
                reason="Repeated clean resync changed passive-text canonical content despite no local or online change",
                artifacts=artifacts,
                details=details,
            )
        if canonical_xlsx_validation_error or xlsx_pair_hashes(local_xlsx_file, self._hash_if_file) != baseline_xlsx_hashes:
            return self.fail_result(
                reason=f"Repeated clean resync changed or invalidated canonical XLSX content: {canonical_xlsx_validation_error}",
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
        if (
            verify.returncode != 0
            or self._hash_if_file(verify_text_file) != baseline_text_hash
            or self._text_if_file(verify_text_file) != baseline_text_content
        ):
            return self.fail_result(
                reason="Fresh verification did not confirm that the online passive-text file remained unchanged",
                artifacts=artifacts,
                details=details,
            )
        if verify_xlsx_validation_error or xlsx_pair_hashes(verify_xlsx_file, self._hash_if_file) != baseline_xlsx_hashes:
            return self.fail_result(
                reason=f"Fresh verification did not confirm that the online XLSX remained unchanged: {verify_xlsx_validation_error}",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
