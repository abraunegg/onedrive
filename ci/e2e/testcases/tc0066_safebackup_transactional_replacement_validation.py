from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, REVISION_2, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, copy_xlsx_pair, xlsx_pair_hashes, xlsx_pair_mtimes, xlsx_pair_backup_files, validate_xlsx_pair_backups, xlsx_pair_backup_hashes
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0066SafeBackupTransactionalReplacementValidation(SafeBackupCaseBase):
    case_id = "0066"
    name = "safeBackup transactional replacement validation"
    description = (
        "Validate with passive TXT and real XLSX payloads that a remote-newer/local-modified conflict "
        "completes with the authoritative remote files at the canonical pathnames and the prior local "
        "bytes preserved exactly once as safeBackup"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0066", ensure_refresh_token=True)
        work = layout.work_dir
        logs = layout.log_dir
        state = layout.state_dir

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
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_updater, updater_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0066_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/conflict.txt"
        xlsx_relative = f"{root_name}/conflict.xlsx"
        seed_text = seed_root / text_relative
        seed_xlsx = seed_root / xlsx_relative
        local_text = local_root / text_relative
        local_xlsx = local_root / xlsx_relative
        updater_text = updater_root / text_relative
        updater_xlsx = updater_root / xlsx_relative
        verify_text = verify_root / text_relative
        verify_xlsx = verify_root / xlsx_relative

        baseline_text = "TC0066 baseline remote content\n"
        local_conflict_text = "TC0066 locally modified content that must be preserved\n"
        remote_replacement_text = "TC0066 newer authoritative remote replacement\n"
        write_text_file(seed_text, baseline_text)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0066:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0066 transactional replacement workbook",
        )

        phase_files = {
            label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log")
            for label in ("seed", "initial_download", "remote_update", "reconcile", "verify")
        }
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
            label="seed",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Seed upload failed with status {seed.returncode}", artifacts=artifacts, details=details)

        initial = self._run_phase(
            context,
            label="initial download",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True),
            stdout_file=phase_files["initial_download"][0],
            stderr_file=phase_files["initial_download"][1],
        )
        details["initial_download_returncode"] = initial.returncode
        initial_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_0)
        details["initial_xlsx_validation_error"] = initial_xlsx_error
        if initial.returncode != 0 or self._text_if_file(local_text) != baseline_text or initial_xlsx_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Initial local TXT/XLSX baseline download failed: {initial_xlsx_error}", artifacts=artifacts, details=details)

        # The downloaded XLSX is now the Microsoft-settled baseline. Build both divergent
        # revisions from that package so any service-added package members remain under test.
        updater_xlsx.parent.mkdir(parents=True, exist_ok=True)
        copy_xlsx_pair(local_xlsx, updater_xlsx)

        time.sleep(2)
        write_text_file(local_text, local_conflict_text)
        mutate_xlsx_pair_revision(local_xlsx, REVISION_0, REVISION_1)
        local_text_hash = self._hash_if_file(local_text)
        local_xlsx_hashes = xlsx_pair_hashes(local_xlsx, self._hash_if_file)
        local_text_mtime = int(local_text.stat().st_mtime)
        local_xlsx_mtimes = xlsx_pair_mtimes(local_xlsx)

        time.sleep(2)
        write_text_file(updater_text, remote_replacement_text)
        mutate_xlsx_pair_revision(updater_xlsx, REVISION_0, REVISION_2)
        remote_update = self._run_phase(
            context,
            label="remote update",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_updater, mode="upload-only", resync=True),
            stdout_file=phase_files["remote_update"][0],
            stderr_file=phase_files["remote_update"][1],
        )
        details["remote_update_returncode"] = remote_update.returncode
        if remote_update.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote update failed with status {remote_update.returncode}", artifacts=artifacts, details=details)

        reconcile = self._run_phase(
            context,
            label="reconcile conflict",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local),
            stdout_file=phase_files["reconcile"][0],
            stderr_file=phase_files["reconcile"][1],
        )
        details["reconcile_returncode"] = reconcile.returncode

        text_backups = self._safe_backup_files_for(local_text)
        xlsx_backups = xlsx_pair_backup_files(local_xlsx, self._safe_backup_files_for)
        partials = self._partial_files_under(local_root / root_name)
        canonical_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_2) if local_xlsx.is_file() else "Canonical XLSX is missing"
        backup_xlsx_error = validate_xlsx_pair_backups(xlsx_backups, REVISION_1)
        details.update(
            {
                "canonical_text_content": self._text_if_file(local_text),
                "canonical_xlsx_validation_error": canonical_xlsx_error,
                "local_text_conflict_hash": local_text_hash,
                "local_xlsx_conflict_hashes": local_xlsx_hashes,
                "local_text_conflict_mtime": local_text_mtime,
                "local_xlsx_conflict_mtimes": local_xlsx_mtimes,
                "text_safe_backup_files": [str(p.relative_to(local_root)) for p in text_backups],
                "text_safe_backup_hashes": [self._hash_if_file(p) for p in text_backups],
                "xlsx_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in xlsx_backups.items()},
                "xlsx_safe_backup_hashes": xlsx_pair_backup_hashes(xlsx_backups, self._hash_if_file),
                "xlsx_safe_backup_validation_error": backup_xlsx_error,
                "partial_files": [str(p.relative_to(local_root)) for p in partials],
            }
        )

        verify = self._run_phase(
            context,
            label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
        )
        verify_xlsx_error = validate_xlsx_pair(verify_xlsx, REVISION_2) if verify_xlsx.is_file() else "Verification XLSX is missing"
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_text_content": self._text_if_file(verify_text),
                "verify_xlsx_validation_error": verify_xlsx_error,
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(reason=f"Conflict reconciliation failed with status {reconcile.returncode}", artifacts=artifacts, details=details)
        if self._text_if_file(local_text) != remote_replacement_text:
            return self.fail_result(reason="TXT canonical filename does not contain the authoritative remote replacement", artifacts=artifacts, details=details)
        if canonical_xlsx_error:
            return self.fail_result(reason=f"XLSX canonical filename does not contain the authoritative remote revision: {canonical_xlsx_error}", artifacts=artifacts, details=details)
        if len(text_backups) != 1 or self._text_if_file(text_backups[0]) != local_conflict_text or self._hash_if_file(text_backups[0]) != local_text_hash:
            return self.fail_result(reason="TXT safeBackup does not contain the exact pre-replacement local bytes", artifacts=artifacts, details=details)
        if xlsx_pair_backup_hashes(xlsx_backups, self._hash_if_file) != local_xlsx_hashes or backup_xlsx_error:
            return self.fail_result(reason=f"XLSX safeBackup does not contain the exact valid pre-replacement local workbook: {backup_xlsx_error}", artifacts=artifacts, details=details)
        if partials:
            return self.fail_result(reason="Completed replacement left unexpected .partial files behind", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._text_if_file(verify_text) != remote_replacement_text or verify_xlsx_error:
            return self.fail_result(reason=f"Fresh verification did not confirm authoritative TXT/XLSX replacements: {verify_xlsx_error}", artifacts=artifacts, details=details)
        return self.pass_result(artifacts=artifacts, details=details)
