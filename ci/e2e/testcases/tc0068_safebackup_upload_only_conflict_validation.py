from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, REVISION_2, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, copy_xlsx_pair, xlsx_pair_hashes, xlsx_pair_backup_files, validate_xlsx_pair_backups, xlsx_pair_backup_hashes
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0068SafeBackupUploadOnlyConflictValidation(SafeBackupCaseBase):
    case_id = "0068"
    name = "safeBackup upload-only conflict validation"
    description = (
        "Validate with passive TXT and real XLSX payloads that upload-only conflict handling preserves "
        "older local versions without replacing the canonical local pathnames when newer online versions exist"
    )

    XLSX_PAYLOAD_ROWS = 32

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
        for conf, root in ((conf_seed, seed_root), (conf_local, local_root), (conf_updater, updater_root), (conf_verify, verify_root)):
            self._prepare_config(context, conf, root)

        root_name = f"ZZ_E2E_TC0068_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/tracked-conflict.txt"
        xlsx_relative = f"{root_name}/tracked-conflict.xlsx"
        seed_text, seed_xlsx = seed_root / text_relative, seed_root / xlsx_relative
        local_text, local_xlsx = local_root / text_relative, local_root / xlsx_relative
        updater_text, updater_xlsx = updater_root / text_relative, updater_root / xlsx_relative
        verify_text, verify_xlsx = verify_root / text_relative, verify_root / xlsx_relative

        baseline_text = "TC0068 baseline\n"
        local_conflict_text = "TC0068 local upload-only conflict that must remain canonical locally\n"
        remote_newer_text = "TC0068 newer online content that upload-only must not download\n"
        write_text_file(seed_text, baseline_text)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0068:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0068 upload-only conflict workbook",
        )

        phase_files = {label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log") for label in ("seed", "initial", "remote_update", "upload_only", "verify")}
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

        seed = self._run_phase(context, label="seed", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True), stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1])
        initial = self._run_phase(context, label="initial download", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True), stdout_file=phase_files["initial"][0], stderr_file=phase_files["initial"][1])
        initial_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_0)
        details.update({"seed_returncode": seed.returncode, "initial_returncode": initial.returncode, "initial_xlsx_validation_error": initial_xlsx_error})
        if seed.returncode != 0 or initial.returncode != 0 or self._text_if_file(local_text) != baseline_text or initial_xlsx_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Failed to establish tracked TXT/XLSX baseline: {initial_xlsx_error}", artifacts=artifacts, details=details)

        # Fork the Microsoft-settled workbook before mutating the local canonical copy.
        updater_xlsx.parent.mkdir(parents=True, exist_ok=True)
        copy_xlsx_pair(local_xlsx, updater_xlsx)

        time.sleep(2)
        write_text_file(local_text, local_conflict_text)
        mutate_xlsx_pair_revision(local_xlsx, REVISION_0, REVISION_1)
        local_text_hash = self._hash_if_file(local_text)
        local_xlsx_hashes = xlsx_pair_hashes(local_xlsx, self._hash_if_file)

        time.sleep(2)
        write_text_file(updater_text, remote_newer_text)
        mutate_xlsx_pair_revision(updater_xlsx, REVISION_0, REVISION_2)
        update = self._run_phase(context, label="remote update", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_updater, mode="upload-only", resync=True), stdout_file=phase_files["remote_update"][0], stderr_file=phase_files["remote_update"][1])
        details["remote_update_returncode"] = update.returncode
        if update.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote update failed with status {update.returncode}", artifacts=artifacts, details=details)

        upload_only = self._run_phase(context, label="upload-only conflict", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="upload-only"), stdout_file=phase_files["upload_only"][0], stderr_file=phase_files["upload_only"][1])
        text_backups = self._safe_backup_files_for(local_text)
        xlsx_backups = xlsx_pair_backup_files(local_xlsx, self._safe_backup_files_for)
        local_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_1) if local_xlsx.is_file() else "Local canonical XLSX is missing"
        backup_xlsx_error = validate_xlsx_pair_backups(xlsx_backups, REVISION_1)
        details.update({
            "upload_only_returncode": upload_only.returncode,
            "canonical_text_content": self._text_if_file(local_text),
            "canonical_xlsx_validation_error": local_xlsx_error,
            "local_text_conflict_hash": local_text_hash,
            "local_xlsx_conflict_hashes": local_xlsx_hashes,
            "text_safe_backup_files": [str(p.relative_to(local_root)) for p in text_backups],
            "xlsx_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in xlsx_backups.items()},
            "xlsx_safe_backup_validation_error": backup_xlsx_error,
        })

        verify = self._run_phase(context, label="verify remote", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True), stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1])
        remote_text_backups = self._safe_backup_files_for(verify_text)
        remote_xlsx_backups = xlsx_pair_backup_files(verify_xlsx, self._safe_backup_files_for)
        verify_xlsx_error = validate_xlsx_pair(verify_xlsx, REVISION_2) if verify_xlsx.is_file() else "Verification canonical XLSX is missing"
        remote_xlsx_backup_error = validate_xlsx_pair_backups(remote_xlsx_backups, REVISION_1)
        details.update({
            "verify_returncode": verify.returncode,
            "verify_canonical_text": self._text_if_file(verify_text),
            "verify_xlsx_validation_error": verify_xlsx_error,
            "verify_text_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_text_backups],
            "verify_xlsx_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_xlsx_backups.items()},
            "verify_xlsx_safe_backup_validation_error": remote_xlsx_backup_error,
        })
        self._write_metadata(metadata_file, details)

        if upload_only.returncode != 0:
            return self.fail_result(reason=f"Upload-only conflict phase failed with status {upload_only.returncode}", artifacts=artifacts, details=details)
        if self._text_if_file(local_text) != local_conflict_text:
            return self.fail_result(reason="Upload-only conflict handling removed or replaced the local TXT canonical file", artifacts=artifacts, details=details)
        if local_xlsx_error or xlsx_pair_hashes(local_xlsx, self._hash_if_file) != local_xlsx_hashes:
            return self.fail_result(reason=f"Upload-only conflict handling removed or changed the local XLSX canonical workbook: {local_xlsx_error}", artifacts=artifacts, details=details)
        if len(text_backups) != 1 or self._hash_if_file(text_backups[0]) != local_text_hash:
            return self.fail_result(reason="Upload-only TXT conflict did not preserve exactly one local safeBackup", artifacts=artifacts, details=details)
        if xlsx_pair_backup_hashes(xlsx_backups, self._hash_if_file) != local_xlsx_hashes or backup_xlsx_error:
            return self.fail_result(reason=f"Upload-only XLSX conflict did not preserve exactly one valid local safeBackup: {backup_xlsx_error}", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._text_if_file(verify_text) != remote_newer_text or verify_xlsx_error:
            return self.fail_result(reason=f"Upload-only conflict unexpectedly changed the newer remote canonical TXT/XLSX files: {verify_xlsx_error}", artifacts=artifacts, details=details)
        if not any(self._text_if_file(path) == local_conflict_text for path in remote_text_backups):
            return self.fail_result(reason="Preserved local TXT conflict was not uploaded remotely under its safeBackup name", artifacts=artifacts, details=details)
        if remote_xlsx_backup_error:
            return self.fail_result(reason="Preserved local XLSX conflict was not uploaded remotely as a valid revision-1 safeBackup", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
