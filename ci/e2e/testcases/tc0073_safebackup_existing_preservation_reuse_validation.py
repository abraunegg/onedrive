from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.pdf import REVISION_0 as PDF_REVISION_0, REVISION_1 as PDF_REVISION_1, REVISION_2 as PDF_REVISION_2, create_random_pdf_pair, mutate_pdf_pair_revision, validate_pdf_pair, copy_pdf_pair, pdf_pair_hashes, pdf_pair_paths, pdf_pair_backup_files, validate_pdf_pair_backups, pdf_pair_backup_hashes
from framework.image import REVISION_0 as IMAGE_REVISION_0, REVISION_1 as IMAGE_REVISION_1, REVISION_2 as IMAGE_REVISION_2, create_random_image_set, mutate_image_set_revision, validate_image_set, copy_image_set, image_set_hashes, image_set_paths, image_set_backup_files, validate_image_set_backups, image_set_backup_hashes
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, REVISION_2, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, copy_xlsx_pair, xlsx_pair_hashes, xlsx_pair_paths, xlsx_pair_backup_files, validate_xlsx_pair_backups, xlsx_pair_backup_hashes
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0073SafeBackupExistingPreservationReuseValidation(SafeBackupCaseBase):
    case_id = "0073"
    name = "safeBackup existing preservation reuse validation"
    description = (
        "Validate with passive TXT plus real XLSX/PDF documents and PNG/JPEG image payloads that an existing same-device safeBackup with "
        "identical content and metadata is reused during replacement instead of creating another numbered backup"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0073", ensure_refresh_token=True)
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
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_updater, updater_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0073_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/reuse-existing-backup.txt"
        xlsx_relative = f"{root_name}/reuse-existing-backup.xlsx"
        pdf_relative = f"{root_name}/reuse-existing-backup.pdf"
        image_relative = f"{root_name}/reuse-existing-backup.png"
        seed_text, seed_xlsx, seed_pdf, seed_image = seed_root / text_relative, seed_root / xlsx_relative, seed_root / pdf_relative, seed_root / image_relative
        local_text, local_xlsx, local_pdf, local_image = local_root / text_relative, local_root / xlsx_relative, local_root / pdf_relative, local_root / image_relative
        updater_text, updater_xlsx, updater_pdf, updater_image = updater_root / text_relative, updater_root / xlsx_relative, updater_root / pdf_relative, updater_root / image_relative
        verify_text, verify_xlsx, verify_pdf, verify_image = verify_root / text_relative, verify_root / xlsx_relative, verify_root / pdf_relative, verify_root / image_relative

        baseline_text = "TC0073 baseline remote content\n"
        local_conflict_text = "TC0073 local conflicting content already preserved in safeBackup-0001\n"
        remote_newer_text = "TC0073 newer remote replacement\n"
        write_text_file(seed_text, baseline_text)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0073:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0073 existing preservation reuse workbook",
        )
        pdf_seed = f"{xlsx_seed}:pdf"
        image_seed = f"{xlsx_seed}:image"
        generated_pdf = create_random_pdf_pair(
            seed_pdf,
            pdf_seed,
            revision=PDF_REVISION_0,
            title="TC0073 existing preservation reuse PDF",
        )
        generated_images = create_random_image_set(seed_image, image_seed, revision=IMAGE_REVISION_0, title="TC0073 existing preservation reuse images")

        phase_files = {
            label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log")
            for label in ("seed", "initial", "remote_update", "reconcile", "verify")
        }
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
            label="seed",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
        )
        initial = self._run_phase(
            context,
            label="initial download",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True),
            stdout_file=phase_files["initial"][0],
            stderr_file=phase_files["initial"][1],
        )
        initial_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_0)
        initial_pdf_error = validate_pdf_pair(local_pdf, PDF_REVISION_0)
        initial_image_error = validate_image_set(local_image, IMAGE_REVISION_0)
        details.update(
            {
                "seed_returncode": seed.returncode,
                "initial_returncode": initial.returncode,
                "initial_xlsx_validation_error": initial_xlsx_error,
                "initial_pdf_validation_error": initial_pdf_error,
                "initial_image_validation_error": initial_image_error,
            }
        )
        if seed.returncode != 0 or initial.returncode != 0 or self._text_if_file(local_text) != baseline_text or initial_xlsx_error or initial_pdf_error or initial_image_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Failed to establish TXT/XLSX/PDF baseline before existing-safeBackup reuse validation: XLSX={initial_xlsx_error}; PDF={initial_pdf_error}",
                artifacts=artifacts,
                details=details,
            )

        # Fork the Microsoft-settled workbook before creating local and remote revisions.
        updater_xlsx.parent.mkdir(parents=True, exist_ok=True)
        copy_xlsx_pair(local_xlsx, updater_xlsx)
        copy_pdf_pair(local_pdf, updater_pdf)
        copy_image_set(local_image, updater_image)

        time.sleep(2)
        write_text_file(local_text, local_conflict_text)
        mutate_xlsx_pair_revision(local_xlsx, REVISION_0, REVISION_1)
        mutate_pdf_pair_revision(local_pdf, PDF_REVISION_0, PDF_REVISION_1)
        mutate_image_set_revision(local_image, IMAGE_REVISION_0, IMAGE_REVISION_1)
        local_text_hash = self._hash_if_file(local_text)
        local_xlsx_hashes = xlsx_pair_hashes(local_xlsx, self._hash_if_file)
        local_pdf_hashes = pdf_pair_hashes(local_pdf, self._hash_if_file)
        local_image_hashes = image_set_hashes(local_image, self._hash_if_file)

        existing_text_backup = self._device_safe_backup_name(local_text, 1)
        existing_xlsx_backups = {
            label: self._device_safe_backup_name(path, 1)
            for label, path in zip(("small", "large"), xlsx_pair_paths(local_xlsx))
        }
        existing_pdf_backups = {
            label: self._device_safe_backup_name(path, 1)
            for label, path in zip(("small", "large"), pdf_pair_paths(local_pdf))
        }
        existing_image_backups = {label: self._device_safe_backup_name(path, 1) for label, path in image_set_paths(local_image).items()}
        existing_text_backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(local_text, existing_text_backup)
        for source, destination in zip(xlsx_pair_paths(local_xlsx), existing_xlsx_backups.values()):
            shutil.copy2(source, destination)
        for source, destination in zip(pdf_pair_paths(local_pdf), existing_pdf_backups.values()):
            shutil.copy2(source, destination)
        for label, source in image_set_paths(local_image).items():
            shutil.copy2(source, existing_image_backups[label])
        existing_xlsx_backup_groups = {label: [path] for label, path in existing_xlsx_backups.items()}
        existing_pdf_backup_groups = {label: [path] for label, path in existing_pdf_backups.items()}
        existing_image_backup_groups = {label: [path] for label, path in existing_image_backups.items()}
        existing_xlsx_error = validate_xlsx_pair_backups(existing_xlsx_backup_groups, REVISION_1)
        existing_pdf_error = validate_pdf_pair_backups(existing_pdf_backup_groups, PDF_REVISION_1)
        existing_image_error = validate_image_set_backups(existing_image_backup_groups, IMAGE_REVISION_1)
        existing_xlsx_hashes = {label: self._hash_if_file(path) for label, path in existing_xlsx_backups.items()}
        existing_pdf_hashes = {label: self._hash_if_file(path) for label, path in existing_pdf_backups.items()}
        existing_image_hashes = {label: self._hash_if_file(path) for label, path in existing_image_backups.items()}
        if (
            self._hash_if_file(existing_text_backup) != local_text_hash
            or existing_xlsx_hashes != local_xlsx_hashes
            or existing_pdf_hashes != local_pdf_hashes
            or existing_image_hashes != local_image_hashes
            or existing_xlsx_error
            or existing_pdf_error
            or existing_image_error
        ):
            details.update(
                {
                    "existing_text_backup_hash": self._hash_if_file(existing_text_backup),
                    "existing_xlsx_backup_hashes": existing_xlsx_hashes,
                    "existing_xlsx_validation_error": existing_xlsx_error,
                    "existing_pdf_backup_hashes": existing_pdf_hashes,
                    "existing_pdf_validation_error": existing_pdf_error,
                    "existing_image_backup_hashes": existing_image_hashes,
                    "existing_image_validation_error": existing_image_error,
                }
            )
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Harness failed to create matching TXT/XLSX/PDF safeBackup preconditions: XLSX={existing_xlsx_error}; PDF={existing_pdf_error}",
                artifacts=artifacts,
                details=details,
            )

        time.sleep(2)
        write_text_file(updater_text, remote_newer_text)
        mutate_xlsx_pair_revision(updater_xlsx, REVISION_0, REVISION_2)
        mutate_pdf_pair_revision(updater_pdf, PDF_REVISION_0, PDF_REVISION_2)
        mutate_image_set_revision(updater_image, IMAGE_REVISION_0, IMAGE_REVISION_2)
        update = self._run_phase(
            context,
            label="remote update",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_updater, mode="upload-only", resync=True),
            stdout_file=phase_files["remote_update"][0],
            stderr_file=phase_files["remote_update"][1],
        )
        details["remote_update_returncode"] = update.returncode
        if update.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Remote update failed with status {update.returncode}",
                artifacts=artifacts,
                details=details,
            )

        reconcile = self._run_phase(
            context,
            label="reconcile with existing preservation",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, verbose_count=2),
            stdout_file=phase_files["reconcile"][0],
            stderr_file=phase_files["reconcile"][1],
        )
        text_backups = self._safe_backup_files_for(local_text)
        xlsx_backups = xlsx_pair_backup_files(local_xlsx, self._safe_backup_files_for)
        pdf_backups = pdf_pair_backup_files(local_pdf, self._safe_backup_files_for)
        image_backups = image_set_backup_files(local_image, self._safe_backup_files_for)
        combined = reconcile.stdout + "\n" + reconcile.stderr
        reuse_marker_count = combined.count("reusing existing preservation")
        canonical_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_2) if local_xlsx.is_file() else "Canonical XLSX is missing"
        canonical_pdf_error = validate_pdf_pair(local_pdf, PDF_REVISION_2) if local_pdf.is_file() else "Canonical PDF is missing"
        canonical_image_error = validate_image_set(local_image, IMAGE_REVISION_2) if local_image.is_file() else "Canonical image set is missing"
        backup_xlsx_error = validate_xlsx_pair_backups(xlsx_backups, REVISION_1)
        backup_pdf_error = validate_pdf_pair_backups(pdf_backups, PDF_REVISION_1)
        backup_image_error = validate_image_set_backups(image_backups, IMAGE_REVISION_1)
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "reuse_marker_count": reuse_marker_count,
                "canonical_text_content": self._text_if_file(local_text),
                "canonical_xlsx_validation_error": canonical_xlsx_error,
                "canonical_pdf_validation_error": canonical_pdf_error,
                "canonical_image_validation_error": canonical_image_error,
                "text_safe_backup_files": [str(p.relative_to(local_root)) for p in text_backups],
                "xlsx_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in xlsx_backups.items()},
                "pdf_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in pdf_backups.items()},
                "image_safe_backup_files": {label: [str(p.relative_to(local_root)) for p in paths] for label, paths in image_backups.items()},
                "local_text_hash": local_text_hash,
                "local_xlsx_hashes": local_xlsx_hashes,
                "local_pdf_hashes": local_pdf_hashes,
                "local_image_hashes": local_image_hashes,
                "existing_xlsx_validation_error_after_reconcile": backup_xlsx_error,
                "existing_pdf_validation_error_after_reconcile": backup_pdf_error,
                "existing_image_validation_error_after_reconcile": backup_image_error,
            }
        )

        verify = self._run_phase(
            context,
            label="verify remote canonical files",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
        )
        verify_xlsx_error = validate_xlsx_pair(verify_xlsx, REVISION_2) if verify_xlsx.is_file() else "Verification canonical XLSX is missing"
        verify_pdf_error = validate_pdf_pair(verify_pdf, PDF_REVISION_2) if verify_pdf.is_file() else "Verification canonical PDF is missing"
        verify_image_error = validate_image_set(verify_image, IMAGE_REVISION_2) if verify_image.is_file() else "Verification canonical image set is missing"
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
                "verify_text_content": self._text_if_file(verify_text),
                "verify_xlsx_validation_error": verify_xlsx_error,
                "verify_pdf_validation_error": verify_pdf_error,
                "verify_image_validation_error": verify_image_error,
                "verify_xlsx_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_xlsx_backups.items()},
                "verify_xlsx_safe_backup_hashes": xlsx_pair_backup_hashes(remote_xlsx_backups, self._hash_if_file),
                "verify_xlsx_safe_backup_validation_error": remote_xlsx_backup_error,
                "xlsx_safe_backup_hash_contract_error": xlsx_backup_hash_error,
                "xlsx_safe_backup_hash_modes": xlsx_backup_hash_modes,
                "verify_pdf_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_pdf_backups.items()},
                "verify_pdf_safe_backup_hashes": pdf_pair_backup_hashes(remote_pdf_backups, self._hash_if_file),
                "verify_pdf_safe_backup_validation_error": remote_pdf_backup_error,
                "pdf_safe_backup_hash_contract_error": pdf_backup_hash_error,
                "pdf_safe_backup_hash_modes": pdf_backup_hash_modes,
                "verify_image_safe_backup_files": {label: [str(p.relative_to(verify_root)) for p in paths] for label, paths in remote_image_backups.items()},
                "verify_image_safe_backup_hashes": image_set_backup_hashes(remote_image_backups, self._hash_if_file),
                "verify_image_safe_backup_validation_error": remote_image_backup_error,
                "image_safe_backup_hash_contract_error": image_backup_hash_error,
                "image_safe_backup_hash_modes": image_backup_hash_modes,
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(
                reason=f"Reconciliation failed with status {reconcile.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if self._text_if_file(local_text) != remote_newer_text:
            return self.fail_result(
                reason="TXT canonical file did not converge to the newer remote content",
                artifacts=artifacts,
                details=details,
            )
        if canonical_xlsx_error:
            return self.fail_result(
                reason=f"XLSX canonical file did not converge to the newer remote revision: {canonical_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if canonical_image_error:
            return self.fail_result(
                reason=f"Image canonical set did not converge to the newer remote revision: {canonical_image_error}",
                artifacts=artifacts,
                details=details,
            )
        if canonical_pdf_error:
            return self.fail_result(
                reason=f"PDF canonical file did not converge to the newer remote revision: {canonical_pdf_error}",
                artifacts=artifacts,
                details=details,
            )
        if len(text_backups) != 1 or text_backups[0] != existing_text_backup or self._hash_if_file(text_backups[0]) != local_text_hash:
            return self.fail_result(
                reason="The original matching TXT safeBackup was not retained as the sole preservation copy",
                artifacts=artifacts,
                details=details,
            )
        if (
            any(len(paths) != 1 or paths[0] != existing_xlsx_backups[label] for label, paths in xlsx_backups.items())
            or backup_xlsx_error
        ):
            return self.fail_result(
                reason=f"The original matching XLSX safeBackup was not retained as the sole valid preservation copy: {backup_xlsx_error}",
                artifacts=artifacts,
                details=details,
            )
        if (
            any(len(paths) != 1 or paths[0] != existing_image_backups[label] for label, paths in image_backups.items())
            or backup_image_error
        ):
            return self.fail_result(
                reason=f"The original matching image safeBackup was not retained as the sole valid preservation copy: {backup_image_error}",
                artifacts=artifacts,
                details=details,
            )
        if (
            any(len(paths) != 1 or paths[0] != existing_pdf_backups[label] for label, paths in pdf_backups.items())
            or backup_pdf_error
        ):
            return self.fail_result(
                reason=f"The original matching PDF safeBackup was not retained as the sole valid preservation copy: {backup_pdf_error}",
                artifacts=artifacts,
                details=details,
            )
        if reuse_marker_count < 1:
            return self.fail_result(
                reason="Reconciliation state was correct but the intended existing-safeBackup reuse path was not observed",
                artifacts=artifacts,
                details=details,
            )
        if verify.returncode != 0 or self._text_if_file(verify_text) != remote_newer_text or verify_xlsx_error or verify_pdf_error or verify_image_error:
            return self.fail_result(
                reason=f"Fresh verification did not confirm newer remote TXT/XLSX/PDF canonical content: XLSX={verify_xlsx_error}; PDF={verify_pdf_error}",
                artifacts=artifacts,
                details=details,
            )
        if remote_xlsx_backup_error:
            return self.fail_result(
                reason=f"Fresh verification did not confirm the reused revision-1 XLSX safeBackup online: {remote_xlsx_backup_error}",
                artifacts=artifacts,
                details=details,
            )
        if remote_image_backup_error:
            return self.fail_result(
                reason=f"Fresh verification did not confirm the reused revision-1 image safeBackup online: {remote_image_backup_error}",
                artifacts=artifacts,
                details=details,
            )
        if remote_pdf_backup_error:
            return self.fail_result(
                reason=f"Fresh verification did not confirm the reused revision-1 PDF safeBackup online: {remote_pdf_backup_error}",
                artifacts=artifacts,
                details=details,
            )
        if xlsx_backup_hash_error:
            return self.fail_result(
                reason=f"Reused XLSX safeBackup preservation/hash contract failed: {xlsx_backup_hash_error}",
                artifacts=artifacts,
                details=details,
            )
        if image_backup_hash_error:
            return self.fail_result(
                reason=f"Reused image safeBackup preservation/hash contract failed: {image_backup_hash_error}",
                artifacts=artifacts,
                details=details,
            )
        if pdf_backup_hash_error:
            return self.fail_result(
                reason=f"Reused PDF safeBackup preservation/hash contract failed: {pdf_backup_hash_error}",
                artifacts=artifacts,
                details=details,
            )

        return self.pass_result(artifacts=artifacts, details=details)
