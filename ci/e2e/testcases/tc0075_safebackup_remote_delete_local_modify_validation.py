from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx, mutate_xlsx_revision, validate_xlsx
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0075SafeBackupRemoteDeleteLocalModifyValidation(SafeBackupCaseBase):
    case_id = "0075"
    name = "safeBackup remote-delete local-modification validation"
    description = (
        "Validate with passive TXT and real XLSX payloads the intentional destructive safeBackup workflow "
        "where tracked files are deleted online after being independently modified locally"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0075", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        deleter_root = work / "deleterroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, local_root, deleter_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_deleter = work / "conf-deleter"
        conf_verify = work / "conf-verify"
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_deleter, deleter_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0075_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/deleted-online.txt"
        xlsx_relative = f"{root_name}/deleted-online.xlsx"
        seed_text, seed_xlsx = seed_root / text_relative, seed_root / xlsx_relative
        local_text, local_xlsx = local_root / text_relative, local_root / xlsx_relative
        deleter_text, deleter_xlsx = deleter_root / text_relative, deleter_root / xlsx_relative
        verify_text, verify_xlsx = verify_root / text_relative, verify_root / xlsx_relative

        baseline_text = "TC0075 baseline content before remote deletion\n"
        local_modified_text = "TC0075 locally modified content that must survive the remote deletion\n"
        write_text_file(seed_text, baseline_text)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0075:{os.getpid()}"
        generated = create_random_xlsx(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0075 remote delete local modification workbook",
        )

        phase_names = ("seed", "local_baseline", "deleter_baseline", "remote_delete", "reconcile", "verify")
        phase_files = {name: (logs / f"{name}_stdout.log", logs / f"{name}_stderr.log") for name in phase_names}
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {
            "root_name": root_name,
            "text_relative": text_relative,
            "xlsx_relative": xlsx_relative,
            "xlsx_seed": xlsx_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_xlsx_size": int(generated["size_bytes"]),
        }

        seed = self._run_phase(
            context,
            label="seed remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
        )
        if seed.returncode != 0:
            details["seed_returncode"] = seed.returncode
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Remote seed failed with status {seed.returncode}",
                artifacts=artifacts,
                details=details,
            )

        local_baseline = self._run_phase(
            context,
            label="establish local tracked baseline",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True),
            stdout_file=phase_files["local_baseline"][0],
            stderr_file=phase_files["local_baseline"][1],
        )
        deleter_baseline = self._run_phase(
            context,
            label="establish deleter tracked baseline",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_deleter, mode="download-only", resync=True),
            stdout_file=phase_files["deleter_baseline"][0],
            stderr_file=phase_files["deleter_baseline"][1],
        )
        local_xlsx_error = validate_xlsx(local_xlsx, REVISION_0)
        deleter_xlsx_error = validate_xlsx(deleter_xlsx, REVISION_0)
        details.update(
            {
                "local_baseline_returncode": local_baseline.returncode,
                "deleter_baseline_returncode": deleter_baseline.returncode,
                "local_baseline_xlsx_validation_error": local_xlsx_error,
                "deleter_baseline_xlsx_validation_error": deleter_xlsx_error,
            }
        )
        if (
            local_baseline.returncode != 0
            or deleter_baseline.returncode != 0
            or self._text_if_file(local_text) != baseline_text
            or self._text_if_file(deleter_text) != baseline_text
            or local_xlsx_error
            or deleter_xlsx_error
        ):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Failed to establish tracked TXT/XLSX baselines before remote-delete conflict: {local_xlsx_error or deleter_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )

        write_text_file(local_text, local_modified_text)
        mutate_xlsx_revision(local_xlsx, REVISION_0, REVISION_1)
        local_text_hash = self._hash_if_file(local_text)
        local_xlsx_hash = self._hash_if_file(local_xlsx)

        deleter_text.unlink()
        deleter_xlsx.unlink()
        remote_delete = self._run_phase(
            context,
            label="propagate remote delete",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_deleter, mode="sync"),
            stdout_file=phase_files["remote_delete"][0],
            stderr_file=phase_files["remote_delete"][1],
        )
        details["remote_delete_returncode"] = remote_delete.returncode
        if remote_delete.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Remote delete propagation failed with status {remote_delete.returncode}",
                artifacts=artifacts,
                details=details,
            )

        reconcile = self._run_phase(
            context,
            label="reconcile remote deletion against locally modified TXT/XLSX files",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="sync", verbose_count=2),
            stdout_file=phase_files["reconcile"][0],
            stderr_file=phase_files["reconcile"][1],
        )
        text_backups = self._safe_backup_files_for(local_text)
        xlsx_backups = self._safe_backup_files_for(local_xlsx)
        partials = self._partial_files_under(local_root / root_name)
        backup_xlsx_error = validate_xlsx(xlsx_backups[0], REVISION_1) if len(xlsx_backups) == 1 else "Expected exactly one local XLSX safeBackup"
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "canonical_text_exists_after_reconcile": local_text.exists(),
                "canonical_xlsx_exists_after_reconcile": local_xlsx.exists(),
                "local_text_modified_hash": local_text_hash,
                "local_xlsx_modified_hash": local_xlsx_hash,
                "text_safe_backup_files": [str(p.relative_to(local_root)) for p in text_backups],
                "text_safe_backup_hashes": [self._hash_if_file(p) for p in text_backups],
                "xlsx_safe_backup_files": [str(p.relative_to(local_root)) for p in xlsx_backups],
                "xlsx_safe_backup_hashes": [self._hash_if_file(p) for p in xlsx_backups],
                "xlsx_safe_backup_validation_error": backup_xlsx_error,
                "partial_files": [str(p.relative_to(local_root)) for p in partials],
            }
        )

        verify = self._run_phase(
            context,
            label="verify remote deletion and uploaded preservations",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
        )
        remote_text_backups = self._safe_backup_files_for(verify_text)
        remote_xlsx_backups = self._safe_backup_files_for(verify_xlsx)
        remote_xlsx_backup_errors = {
            str(path.relative_to(verify_root)): validate_xlsx(path, REVISION_1)
            for path in remote_xlsx_backups
        }
        remote_xlsx_backup_revision_seen = any(not error for error in remote_xlsx_backup_errors.values())
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_text_canonical_exists": verify_text.exists(),
                "verify_xlsx_canonical_exists": verify_xlsx.exists(),
                "verify_text_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_text_backups],
                "verify_xlsx_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_xlsx_backups],
                "verify_xlsx_safe_backup_validation_errors": remote_xlsx_backup_errors,
                "verify_xlsx_safe_backup_revision_seen": remote_xlsx_backup_revision_seen,
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(
                reason=f"Remote-delete reconciliation failed with status {reconcile.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if local_text.exists() or local_xlsx.exists():
            return self.fail_result(
                reason="One or more canonical local files remained present even though the authoritative online items were deleted",
                artifacts=artifacts,
                details=details,
            )
        if len(text_backups) != 1 or self._text_if_file(text_backups[0]) != local_modified_text or self._hash_if_file(text_backups[0]) != local_text_hash:
            return self.fail_result(
                reason="Remote-delete TXT conflict did not preserve exactly one safeBackup containing the locally modified bytes",
                artifacts=artifacts,
                details=details,
            )
        if len(xlsx_backups) != 1 or self._hash_if_file(xlsx_backups[0]) != local_xlsx_hash or backup_xlsx_error:
            return self.fail_result(
                reason=f"Remote-delete XLSX conflict did not preserve exactly one valid safeBackup containing the locally modified workbook: {backup_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if partials:
            return self.fail_result(
                reason="Remote-delete conflict left an unexpected .partial file",
                artifacts=artifacts,
                details=details,
            )
        if verify.returncode != 0 or verify_text.exists() or verify_xlsx.exists():
            return self.fail_result(
                reason="Fresh verification did not confirm that both canonical online files remain deleted",
                artifacts=artifacts,
                details=details,
            )
        if not any(self._text_if_file(path) == local_modified_text for path in remote_text_backups):
            return self.fail_result(
                reason="Fresh verification did not confirm the preserved local TXT safeBackup was uploaded",
                artifacts=artifacts,
                details=details,
            )
        if not remote_xlsx_backup_revision_seen:
            return self.fail_result(
                reason="Fresh verification did not confirm the preserved revision-1 XLSX safeBackup was uploaded",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
