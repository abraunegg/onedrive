from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, copy_xlsx_pair, xlsx_pair_hashes, xlsx_pair_backup_files, validate_xlsx_pair_backups, xlsx_pair_backup_hashes
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0076SafeBackupResyncContentConflictValidation(SafeBackupCaseBase):
    case_id = "0076"
    name = "safeBackup resync content-conflict validation"
    description = (
        "Validate with passive TXT and a Microsoft-settled real XLSX that --resync preserves same-path local "
        "files as safeBackup when there is no usable DB identity and local content genuinely differs from the "
        "authoritative online files"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0076", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        settle_root = work / "settleroot"
        local_root = work / "localroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, settle_root, local_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_settle = work / "conf-settle"
        conf_local = work / "conf-local"
        conf_verify = work / "conf-verify"
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(context, conf_settle, settle_root)
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0076_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/resync-conflict.txt"
        xlsx_relative = f"{root_name}/resync-conflict.xlsx"
        seed_text, seed_xlsx = seed_root / text_relative, seed_root / xlsx_relative
        settled_text, settled_xlsx = settle_root / text_relative, settle_root / xlsx_relative
        local_text, local_xlsx = local_root / text_relative, local_root / xlsx_relative
        verify_text, verify_xlsx = verify_root / text_relative, verify_root / xlsx_relative

        remote_text_content = "TC0076 authoritative online content\n"
        local_text_content = "TC0076 different local content with no usable DB identity\n"
        write_text_file(seed_text, remote_text_content)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0076:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0076 resync content conflict workbook",
        )

        phase_files = {
            label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log")
            for label in ("seed", "settle", "reconcile", "verify")
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
            label="seed remote TXT/XLSX",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Remote seed failed with status {seed.returncode}",
                artifacts=artifacts,
                details=details,
            )

        # Obtain Microsoft-returned bytes in an independent client, then copy those bytes
        # into the subject local tree. conf-local remains without usable tracked identity;
        # the later --resync therefore exercises the original no-identity conflict path.
        settle = self._run_phase(
            context,
            label="settle remote XLSX through independent download",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_settle, mode="download-only", resync=True),
            stdout_file=phase_files["settle"][0],
            stderr_file=phase_files["settle"][1],
        )
        settled_xlsx_error = validate_xlsx_pair(settled_xlsx, REVISION_0)
        details.update(
            {
                "settle_returncode": settle.returncode,
                "settled_text_content": self._text_if_file(settled_text),
                "settled_xlsx_validation_error": settled_xlsx_error,
            }
        )
        if settle.returncode != 0 or self._text_if_file(settled_text) != remote_text_content or settled_xlsx_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Failed to establish Microsoft-settled TXT/XLSX baseline before resync conflict: {settled_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )

        write_text_file(local_text, local_text_content)
        local_xlsx.parent.mkdir(parents=True, exist_ok=True)
        copy_xlsx_pair(settled_xlsx, local_xlsx)
        mutate_xlsx_pair_revision(local_xlsx, REVISION_0, REVISION_1)
        local_text_hash = self._hash_if_file(local_text)
        local_xlsx_hashes = xlsx_pair_hashes(local_xlsx, self._hash_if_file)

        reconcile = self._run_phase(
            context,
            label="resync content conflict",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_local,
                mode="sync",
                resync=True,
                verbose_count=2,
            ),
            stdout_file=phase_files["reconcile"][0],
            stderr_file=phase_files["reconcile"][1],
        )
        text_backups = self._safe_backup_files_for(local_text)
        xlsx_backups = xlsx_pair_backup_files(local_xlsx, self._safe_backup_files_for)
        partials = self._partial_files_under(local_root / root_name)
        canonical_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_0) if local_xlsx.is_file() else "Canonical XLSX is missing"
        backup_xlsx_error = validate_xlsx_pair_backups(xlsx_backups, REVISION_1)
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "canonical_text_content": self._text_if_file(local_text),
                "canonical_text_hash": self._hash_if_file(local_text),
                "canonical_xlsx_hashes": xlsx_pair_hashes(local_xlsx, self._hash_if_file),
                "canonical_xlsx_validation_error": canonical_xlsx_error,
                "local_text_pre_resync_hash": local_text_hash,
                "local_xlsx_pre_resync_hashes": local_xlsx_hashes,
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
            label="verify remote canonical and preserved conflicts",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
        )
        remote_text_backups = self._safe_backup_files_for(verify_text)
        remote_xlsx_backups = xlsx_pair_backup_files(verify_xlsx, self._safe_backup_files_for)
        verify_xlsx_error = validate_xlsx_pair(verify_xlsx, REVISION_0) if verify_xlsx.is_file() else "Verification canonical XLSX is missing"
        remote_xlsx_backup_error = validate_xlsx_pair_backups(remote_xlsx_backups, REVISION_1)
        xlsx_backup_hash_error, xlsx_backup_hash_modes = self._xlsx_safe_backup_hash_contract(
            reconcile_output=reconcile.stdout + "\n" + reconcile.stderr,
            local_backups=xlsx_backups,
            expected_original_hashes=local_xlsx_hashes,
            remote_backups=remote_xlsx_backups,
        )
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_text_content": self._text_if_file(verify_text),
                "verify_xlsx_validation_error": verify_xlsx_error,
                "verify_text_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_text_backups],
                "verify_xlsx_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_xlsx_backups.items()},
                "verify_xlsx_safe_backup_validation_error": remote_xlsx_backup_error,
                "verify_xlsx_safe_backup_hashes": xlsx_pair_backup_hashes(remote_xlsx_backups, self._hash_if_file),
                "xlsx_safe_backup_hash_contract_error": xlsx_backup_hash_error,
                "xlsx_safe_backup_hash_modes": xlsx_backup_hash_modes,
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(
                reason=f"Resync content-conflict reconciliation failed with status {reconcile.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if self._text_if_file(local_text) != remote_text_content:
            return self.fail_result(
                reason="Resync TXT content conflict did not leave the authoritative online content at the canonical pathname",
                artifacts=artifacts,
                details=details,
            )
        if canonical_xlsx_error:
            return self.fail_result(
                reason=f"Resync XLSX content conflict did not leave the authoritative online revision at the canonical pathname: {canonical_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if len(text_backups) != 1 or self._text_if_file(text_backups[0]) != local_text_content or self._hash_if_file(text_backups[0]) != local_text_hash:
            return self.fail_result(
                reason="Resync TXT content conflict did not preserve exactly one safeBackup containing the pre-resync local bytes",
                artifacts=artifacts,
                details=details,
            )
        if backup_xlsx_error:
            return self.fail_result(
                reason=f"Resync XLSX content conflict did not preserve exactly one valid safeBackup containing the pre-resync local workbook: {backup_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if partials:
            return self.fail_result(
                reason="Resync content conflict left an unexpected .partial file",
                artifacts=artifacts,
                details=details,
            )
        if verify.returncode != 0 or self._text_if_file(verify_text) != remote_text_content or verify_xlsx_error:
            return self.fail_result(
                reason=f"Fresh verification did not confirm authoritative remote TXT/XLSX canonical content: {verify_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if not any(self._text_if_file(path) == local_text_content for path in remote_text_backups):
            return self.fail_result(
                reason="Fresh verification did not confirm the resync-preserved TXT safeBackup online",
                artifacts=artifacts,
                details=details,
            )
        if remote_xlsx_backup_error:
            return self.fail_result(
                reason="Fresh verification did not confirm the resync-preserved revision-1 XLSX safeBackup online",
                artifacts=artifacts,
                details=details,
            )
        if xlsx_backup_hash_error:
            return self.fail_result(
                reason=f"Resync XLSX safeBackup preservation/hash contract failed: {xlsx_backup_hash_error}",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
