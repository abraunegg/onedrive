from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, copy_xlsx_pair, set_xlsx_pair_mtime, xlsx_pair_hashes, xlsx_pair_mtimes, xlsx_pair_backup_files
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0071SafeBackupMetadataOnlyIdentityValidation(SafeBackupCaseBase):
    case_id = "0071"
    name = "safeBackup metadata-only identity validation"
    description = (
        "Validate with passive TXT and a Microsoft-settled real XLSX that identical local and online content "
        "with deliberately different local metadata is reconciled without creating safeBackup artifacts or "
        "being misclassified as a content conflict"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0071", ensure_refresh_token=True)
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

        root_name = f"ZZ_E2E_TC0071_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/metadata-only.txt"
        xlsx_relative = f"{root_name}/metadata-only.xlsx"
        seed_text = seed_root / text_relative
        seed_xlsx = seed_root / xlsx_relative
        settled_text = settle_root / text_relative
        settled_xlsx = settle_root / xlsx_relative
        local_text = local_root / text_relative
        local_xlsx = local_root / xlsx_relative
        verify_text = verify_root / text_relative
        verify_xlsx = verify_root / xlsx_relative

        text_content = "TC0071 content is identical; only local mtime starts different\n"
        write_text_file(seed_text, text_content)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0071:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0071 metadata-only identity workbook",
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
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_seed,
                mode="upload-only",
                resync=True,
            ),
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

        # Obtain the real Microsoft-returned workbook in an independent client. The subject
        # conf-local remains untouched, preserving the original no-usable-identity/resync
        # test shape while removing ZIP-package differences from the content comparison.
        settle = self._run_phase(
            context,
            label="settle remote XLSX through independent download",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_settle,
                mode="download-only",
                resync=True,
            ),
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
        if settle.returncode != 0 or self._text_if_file(settled_text) != text_content or settled_xlsx_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Failed to establish Microsoft-settled TXT/XLSX baseline: {settled_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )

        local_text.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(settled_text, local_text)
        copy_xlsx_pair(settled_xlsx, local_xlsx)
        deliberately_different_mtime = int(time.time()) + 7200
        os.utime(local_text, (deliberately_different_mtime, deliberately_different_mtime))
        set_xlsx_pair_mtime(local_xlsx, (deliberately_different_mtime, deliberately_different_mtime))
        initial_text_hash = self._hash_if_file(local_text)
        initial_xlsx_hashes = xlsx_pair_hashes(local_xlsx, self._hash_if_file)

        reconcile = self._run_phase(
            context,
            label="metadata-only reconcile",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_local,
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
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "deliberately_different_mtime": deliberately_different_mtime,
                "canonical_text_content": self._text_if_file(local_text),
                "canonical_text_hash": self._hash_if_file(local_text),
                "canonical_text_mtime": int(local_text.stat().st_mtime) if local_text.is_file() else -1,
                "canonical_xlsx_hashes": xlsx_pair_hashes(local_xlsx, self._hash_if_file),
                "canonical_xlsx_mtimes": xlsx_pair_mtimes(local_xlsx),
                "canonical_xlsx_validation_error": canonical_xlsx_error,
                "initial_text_hash": initial_text_hash,
                "initial_xlsx_hashes": initial_xlsx_hashes,
                "text_safe_backup_files": [str(p.relative_to(local_root)) for p in text_backups],
                "xlsx_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in xlsx_backups.items()},
                "partial_files": [str(p.relative_to(local_root)) for p in partials],
            }
        )

        verify = self._run_phase(
            context,
            label="verify remote unchanged",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_verify,
                mode="download-only",
                resync=True,
            ),
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
        )
        verify_xlsx_error = validate_xlsx_pair(verify_xlsx, REVISION_0) if verify_xlsx.is_file() else "Verification XLSX is missing"
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_text_content": self._text_if_file(verify_text),
                "verify_text_hash": self._hash_if_file(verify_text),
                "verify_text_mtime": int(verify_text.stat().st_mtime) if verify_text.is_file() else -1,
                "verify_xlsx_validation_error": verify_xlsx_error,
                "verify_xlsx_hashes": xlsx_pair_hashes(verify_xlsx, self._hash_if_file),
                "verify_xlsx_mtimes": xlsx_pair_mtimes(verify_xlsx),
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(
                reason=f"Metadata-only reconciliation failed with status {reconcile.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if self._text_if_file(local_text) != text_content or self._hash_if_file(local_text) != initial_text_hash:
            return self.fail_result(
                reason="Metadata-only reconciliation changed canonical TXT content",
                artifacts=artifacts,
                details=details,
            )
        if canonical_xlsx_error or xlsx_pair_hashes(local_xlsx, self._hash_if_file) != initial_xlsx_hashes:
            return self.fail_result(
                reason=f"Metadata-only reconciliation changed canonical XLSX content: {canonical_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if text_backups or any(xlsx_backups.values()):
            return self.fail_result(
                reason="Metadata-only reconciliation incorrectly created a safeBackup for identical TXT/XLSX content",
                artifacts=artifacts,
                details=details,
            )
        if partials:
            return self.fail_result(
                reason="Metadata-only reconciliation left an unexpected .partial file",
                artifacts=artifacts,
                details=details,
            )
        if verify.returncode != 0 or self._text_if_file(verify_text) != text_content or verify_xlsx_error:
            return self.fail_result(
                reason=f"Fresh verification did not confirm unchanged online TXT/XLSX content: {verify_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if int(local_text.stat().st_mtime) == deliberately_different_mtime or any(mtime == deliberately_different_mtime for mtime in xlsx_pair_mtimes(local_xlsx).values()):
            return self.fail_result(
                reason="Metadata-only reconciliation did not correct one or more deliberately divergent local mtimes",
                artifacts=artifacts,
                details=details,
            )
        if int(local_text.stat().st_mtime) != int(verify_text.stat().st_mtime):
            return self.fail_result(
                reason="Local TXT mtime after metadata-only reconciliation does not match authoritative downloaded metadata",
                artifacts=artifacts,
                details=details,
            )
        if xlsx_pair_mtimes(local_xlsx) != xlsx_pair_mtimes(verify_xlsx):
            return self.fail_result(
                reason="Local XLSX mtime after metadata-only reconciliation does not match authoritative downloaded metadata",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
