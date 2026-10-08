from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.pdf import REVISION_0 as PDF_REVISION_0, REVISION_1 as PDF_REVISION_1, create_random_pdf_pair, mutate_pdf_pair_revision, validate_pdf_pair, unlink_pdf_pair, pdf_pair_hashes, pdf_pair_backup_files, validate_pdf_pair_backups, pdf_pair_backup_hashes, pdf_pair_any_exists
from framework.image import REVISION_0 as IMAGE_REVISION_0, REVISION_1 as IMAGE_REVISION_1, create_random_image_set, mutate_image_set_revision, validate_image_set, unlink_image_set, image_set_hashes, image_set_backup_files, validate_image_set_backups, image_set_backup_hashes, image_set_any_exists
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, unlink_xlsx_pair, xlsx_pair_hashes, xlsx_pair_backup_files, validate_xlsx_pair_backups, xlsx_pair_backup_hashes, xlsx_pair_any_exists
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0075SafeBackupRemoteDeleteLocalModifyValidation(SafeBackupCaseBase):
    case_id = "0075"
    name = "safeBackup remote-delete local-modification validation"
    description = (
        "Validate with passive TXT plus real XLSX/PDF documents and PNG/JPEG image payloads the intentional destructive safeBackup workflow "
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
        pdf_relative = f"{root_name}/deleted-online.pdf"
        image_relative = f"{root_name}/deleted-online.png"
        seed_text, seed_xlsx, seed_pdf, seed_image = seed_root / text_relative, seed_root / xlsx_relative, seed_root / pdf_relative, seed_root / image_relative
        local_text, local_xlsx, local_pdf, local_image = local_root / text_relative, local_root / xlsx_relative, local_root / pdf_relative, local_root / image_relative
        deleter_text, deleter_xlsx, deleter_pdf, deleter_image = deleter_root / text_relative, deleter_root / xlsx_relative, deleter_root / pdf_relative, deleter_root / image_relative
        verify_text, verify_xlsx, verify_pdf, verify_image = verify_root / text_relative, verify_root / xlsx_relative, verify_root / pdf_relative, verify_root / image_relative

        baseline_text = "TC0075 baseline content before remote deletion\n"
        local_modified_text = "TC0075 locally modified content that must survive the remote deletion\n"
        write_text_file(seed_text, baseline_text)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0075:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0075 remote delete local modification workbook",
        )
        pdf_seed = f"{xlsx_seed}:pdf"
        image_seed = f"{xlsx_seed}:image"
        generated_pdf = create_random_pdf_pair(
            seed_pdf,
            pdf_seed,
            revision=PDF_REVISION_0,
            title="TC0075 remote delete local modification PDF",
        )
        generated_images = create_random_image_set(seed_image, image_seed, revision=IMAGE_REVISION_0, title="TC0075 remote delete local modification images")

        phase_names = ("seed", "local_baseline", "deleter_baseline", "remote_delete", "reconcile", "verify")
        phase_files = {name: (logs / f"{name}_stdout.log", logs / f"{name}_stderr.log") for name in phase_names}
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {
            "root_name": root_name,
            "text_relative": text_relative,
            "xlsx_relative": xlsx_relative,
            "pdf_relative": pdf_relative,
            "image_relative": image_relative,
            "xlsx_seed": xlsx_seed,
            "pdf_seed": pdf_seed,
            "image_seed": image_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_xlsx_size": int(generated["size_bytes"]),
            "generated_pdf_size": int(generated_pdf["size_bytes"]),
            "generated_large_pdf_size": int(generated_pdf["large_size_bytes"]),
            "generated_image_sizes": {k: int(v) for k, v in generated_images.items() if k.endswith("_size_bytes")},
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
        local_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_0)
        deleter_xlsx_error = validate_xlsx_pair(deleter_xlsx, REVISION_0)
        local_pdf_error = validate_pdf_pair(local_pdf, PDF_REVISION_0)
        deleter_pdf_error = validate_pdf_pair(deleter_pdf, PDF_REVISION_0)
        local_image_error = validate_image_set(local_image, IMAGE_REVISION_0)
        deleter_image_error = validate_image_set(deleter_image, IMAGE_REVISION_0)
        details.update(
            {
                "local_baseline_returncode": local_baseline.returncode,
                "deleter_baseline_returncode": deleter_baseline.returncode,
                "local_baseline_xlsx_validation_error": local_xlsx_error,
                "deleter_baseline_xlsx_validation_error": deleter_xlsx_error,
                "local_baseline_pdf_validation_error": local_pdf_error,
                "deleter_baseline_pdf_validation_error": deleter_pdf_error,
                "local_baseline_image_validation_error": local_image_error,
                "deleter_baseline_image_validation_error": deleter_image_error,
            }
        )
        if (
            local_baseline.returncode != 0
            or deleter_baseline.returncode != 0
            or self._text_if_file(local_text) != baseline_text
            or self._text_if_file(deleter_text) != baseline_text
            or local_xlsx_error
            or deleter_xlsx_error
            or local_pdf_error
            or deleter_pdf_error
            or local_image_error
            or deleter_image_error
        ):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Failed to establish tracked TXT/XLSX/PDF baselines before remote-delete conflict: XLSX={local_xlsx_error or deleter_xlsx_error}; PDF={local_pdf_error or deleter_pdf_error}",
                artifacts=artifacts,
                details=details,
            )

        write_text_file(local_text, local_modified_text)
        mutate_xlsx_pair_revision(local_xlsx, REVISION_0, REVISION_1)
        mutate_pdf_pair_revision(local_pdf, PDF_REVISION_0, PDF_REVISION_1)
        mutate_image_set_revision(local_image, IMAGE_REVISION_0, IMAGE_REVISION_1)
        local_text_hash = self._hash_if_file(local_text)
        local_xlsx_hashes = xlsx_pair_hashes(local_xlsx, self._hash_if_file)
        local_pdf_hashes = pdf_pair_hashes(local_pdf, self._hash_if_file)
        local_image_hashes = image_set_hashes(local_image, self._hash_if_file)

        deleter_text.unlink()
        unlink_xlsx_pair(deleter_xlsx)
        unlink_pdf_pair(deleter_pdf)
        unlink_image_set(deleter_image)
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
            label="reconcile remote deletion against locally modified TXT/XLSX/PDF files",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="sync", verbose_count=2),
            stdout_file=phase_files["reconcile"][0],
            stderr_file=phase_files["reconcile"][1],
        )
        text_backups = self._safe_backup_files_for(local_text)
        xlsx_backups = xlsx_pair_backup_files(local_xlsx, self._safe_backup_files_for)
        pdf_backups = pdf_pair_backup_files(local_pdf, self._safe_backup_files_for)
        image_backups = image_set_backup_files(local_image, self._safe_backup_files_for)
        partials = self._partial_files_under(local_root / root_name)
        backup_xlsx_error = validate_xlsx_pair_backups(xlsx_backups, REVISION_1)
        backup_pdf_error = validate_pdf_pair_backups(pdf_backups, PDF_REVISION_1)
        backup_image_error = validate_image_set_backups(image_backups, IMAGE_REVISION_1)
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "canonical_text_exists_after_reconcile": local_text.exists(),
                "canonical_xlsx_exists_after_reconcile": xlsx_pair_any_exists(local_xlsx),
                "canonical_pdf_exists_after_reconcile": pdf_pair_any_exists(local_pdf),
                "canonical_image_exists_after_reconcile": image_set_any_exists(local_image),
                "local_text_modified_hash": local_text_hash,
                "local_xlsx_modified_hashes": local_xlsx_hashes,
                "local_pdf_modified_hashes": local_pdf_hashes,
                "local_image_modified_hashes": local_image_hashes,
                "text_safe_backup_files": [str(p.relative_to(local_root)) for p in text_backups],
                "text_safe_backup_hashes": [self._hash_if_file(p) for p in text_backups],
                "xlsx_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in xlsx_backups.items()},
                "xlsx_safe_backup_hashes": xlsx_pair_backup_hashes(xlsx_backups, self._hash_if_file),
                "xlsx_safe_backup_validation_error": backup_xlsx_error,
                "pdf_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in pdf_backups.items()},
                "pdf_safe_backup_hashes": pdf_pair_backup_hashes(pdf_backups, self._hash_if_file),
                "pdf_safe_backup_validation_error": backup_pdf_error,
                "image_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in image_backups.items()},
                "image_safe_backup_hashes": image_set_backup_hashes(image_backups, self._hash_if_file),
                "image_safe_backup_validation_error": backup_image_error,
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
        remote_xlsx_backups = xlsx_pair_backup_files(verify_xlsx, self._safe_backup_files_for)
        remote_pdf_backups = pdf_pair_backup_files(verify_pdf, self._safe_backup_files_for)
        remote_image_backups = image_set_backup_files(verify_image, self._safe_backup_files_for)
        remote_xlsx_backup_error = validate_xlsx_pair_backups(remote_xlsx_backups, REVISION_1)
        remote_pdf_backup_error = validate_pdf_pair_backups(remote_pdf_backups, PDF_REVISION_1)
        remote_image_backup_error = validate_image_set_backups(remote_image_backups, IMAGE_REVISION_1)
        xlsx_backup_hash_error, xlsx_backup_hash_modes = self._xlsx_safe_backup_hash_contract(
            reconcile_output=reconcile.stdout + "\n" + reconcile.stderr,
            local_backups=xlsx_backups,
            expected_original_hashes=local_xlsx_hashes,
            remote_backups=remote_xlsx_backups,
        )
        pdf_backup_hash_error, pdf_backup_hash_modes = self._pdf_safe_backup_hash_contract(
            reconcile_output=reconcile.stdout + "\n" + reconcile.stderr,
            local_backups=pdf_backups,
            expected_original_hashes=local_pdf_hashes,
            remote_backups=remote_pdf_backups,
        )
        image_backup_hash_error, image_backup_hash_modes = self._image_safe_backup_hash_contract(
            reconcile_output=reconcile.stdout + "\n" + reconcile.stderr,
            local_backups=image_backups,
            expected_original_hashes=local_image_hashes,
            remote_backups=remote_image_backups,
        )
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_text_canonical_exists": verify_text.exists(),
                "verify_xlsx_canonical_exists": xlsx_pair_any_exists(verify_xlsx),
                "verify_pdf_canonical_exists": pdf_pair_any_exists(verify_pdf),
                "verify_image_canonical_exists": image_set_any_exists(verify_image),
                "verify_text_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_text_backups],
                "verify_xlsx_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_xlsx_backups.items()},
                "verify_xlsx_safe_backup_validation_error": remote_xlsx_backup_error,
                "verify_xlsx_safe_backup_hashes": xlsx_pair_backup_hashes(remote_xlsx_backups, self._hash_if_file),
                "xlsx_safe_backup_hash_contract_error": xlsx_backup_hash_error,
                "xlsx_safe_backup_hash_modes": xlsx_backup_hash_modes,
                "verify_pdf_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_pdf_backups.items()},
                "verify_pdf_safe_backup_validation_error": remote_pdf_backup_error,
                "verify_pdf_safe_backup_hashes": pdf_pair_backup_hashes(remote_pdf_backups, self._hash_if_file),
                "pdf_safe_backup_hash_contract_error": pdf_backup_hash_error,
                "pdf_safe_backup_hash_modes": pdf_backup_hash_modes,
                "verify_image_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_image_backups.items()},
                "verify_image_safe_backup_validation_error": remote_image_backup_error,
                "verify_image_safe_backup_hashes": image_set_backup_hashes(remote_image_backups, self._hash_if_file),
                "image_safe_backup_hash_contract_error": image_backup_hash_error,
                "image_safe_backup_hash_modes": image_backup_hash_modes,
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(
                reason=f"Remote-delete reconciliation failed with status {reconcile.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if local_text.exists() or xlsx_pair_any_exists(local_xlsx) or pdf_pair_any_exists(local_pdf) or image_set_any_exists(local_image):
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
        if backup_xlsx_error:
            return self.fail_result(
                reason=f"Remote-delete XLSX conflict did not preserve exactly one valid safeBackup containing the locally modified workbook: {backup_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if backup_image_error:
            return self.fail_result(reason=f"Remote-delete image conflict did not preserve exactly one valid safeBackup containing the locally modified images: {backup_image_error}", artifacts=artifacts, details=details)
        if backup_pdf_error:
            return self.fail_result(
                reason=f"Remote-delete PDF conflict did not preserve exactly one valid safeBackup containing the locally modified document: {backup_pdf_error}",
                artifacts=artifacts,
                details=details,
            )
        if partials:
            return self.fail_result(
                reason="Remote-delete conflict left an unexpected .partial file",
                artifacts=artifacts,
                details=details,
            )
        if verify.returncode != 0 or verify_text.exists() or xlsx_pair_any_exists(verify_xlsx) or pdf_pair_any_exists(verify_pdf) or image_set_any_exists(verify_image):
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
        if remote_xlsx_backup_error:
            return self.fail_result(
                reason="Fresh verification did not confirm the preserved revision-1 XLSX safeBackup was uploaded",
                artifacts=artifacts,
                details=details,
            )
        if remote_image_backup_error:
            return self.fail_result(reason=f"Fresh verification did not confirm the preserved image safeBackup online: {remote_image_backup_error}", artifacts=artifacts, details=details)
        if remote_pdf_backup_error:
            return self.fail_result(
                reason="Fresh verification did not confirm the preserved revision-1 PDF safeBackup was uploaded",
                artifacts=artifacts,
                details=details,
            )
        if xlsx_backup_hash_error:
            return self.fail_result(
                reason=f"Remote-delete XLSX safeBackup preservation/hash contract failed: {xlsx_backup_hash_error}",
                artifacts=artifacts,
                details=details,
            )
        if image_backup_hash_error:
            return self.fail_result(reason=f"Remote-delete image safeBackup preservation/hash contract failed: {image_backup_hash_error}", artifacts=artifacts, details=details)
        if pdf_backup_hash_error:
            return self.fail_result(
                reason=f"Remote-delete PDF safeBackup preservation/hash contract failed: {pdf_backup_hash_error}",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
