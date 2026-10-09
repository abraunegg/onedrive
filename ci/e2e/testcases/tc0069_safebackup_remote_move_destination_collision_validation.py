from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.pdf import REVISION_0 as PDF_REVISION_0, REVISION_1 as PDF_REVISION_1, create_random_pdf_pair, validate_pdf_pair, rename_pdf_pair, pdf_pair_hashes, pdf_pair_backup_files, validate_pdf_pair_backups, pdf_pair_backup_hashes, pdf_pair_any_exists
from framework.image import REVISION_0 as IMAGE_REVISION_0, REVISION_1 as IMAGE_REVISION_1, create_random_image_set, validate_image_set, rename_image_set, image_set_hashes, image_set_backup_files, validate_image_set_backups, image_set_backup_hashes, image_set_any_exists, image_set_all_files
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx_pair, validate_xlsx_pair, rename_xlsx_pair, xlsx_pair_hashes, xlsx_pair_backup_files, validate_xlsx_pair_backups, xlsx_pair_backup_hashes, xlsx_pair_any_exists
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0069SafeBackupRemoteMoveDestinationCollisionValidation(SafeBackupCaseBase):
    case_id = "0069"
    name = "safeBackup remote move destination collision validation"
    description = (
        "Validate with passive TXT plus real XLSX/PDF documents and PNG/JPEG image payloads that reconciling remote moves into occupied "
        "local destinations preserves each displaced local file as safeBackup while the moved remote "
        "files take the canonical pathnames"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0069", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        validator_root = work / "validatorroot"
        mutator_root = work / "mutatorroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, validator_root, mutator_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_validator = work / "conf-validator"
        conf_mutator = work / "conf-mutator"
        conf_verify = work / "conf-verify"
        for conf, root in ((conf_seed, seed_root), (conf_validator, validator_root), (conf_mutator, mutator_root), (conf_verify, verify_root)):
            self._prepare_config(context, conf, root)

        root_name = f"ZZ_E2E_TC0069_{context.run_id}_{os.getpid()}"
        text_source = f"{root_name}/source/move-me.txt"
        text_destination = f"{root_name}/destination/move-me.txt"
        xlsx_source = f"{root_name}/source/move-me.xlsx"
        xlsx_destination = f"{root_name}/destination/move-me.xlsx"
        pdf_source = f"{root_name}/source/move-me.pdf"
        pdf_destination = f"{root_name}/destination/move-me.pdf"
        image_source = f"{root_name}/source/move-me.png"
        image_destination = f"{root_name}/destination/move-me.png"
        control_relative = f"{root_name}/destination/control.txt"
        moved_text = "TC0069 remote item that will be moved\n"
        occupant_text = "TC0069 unsynchronised local destination occupant that must be preserved\n"
        control_content = "TC0069 destination directory control file\n"

        write_text_file(seed_root / text_source, moved_text)
        write_text_file(seed_root / control_relative, control_content)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0069:remote:{os.getpid()}"
        occupant_xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0069:occupant:{os.getpid()}"
        generated_remote = create_random_xlsx_pair(seed_root / xlsx_source, xlsx_seed, revision=REVISION_0, payload_rows=self.XLSX_PAYLOAD_ROWS, title="TC0069 remotely moved workbook")
        pdf_seed = f"{xlsx_seed}:pdf"
        occupant_pdf_seed = f"{occupant_xlsx_seed}:pdf"
        image_seed = f"{xlsx_seed}:image"
        occupant_image_seed = f"{occupant_xlsx_seed}:image"
        generated_remote_pdf = create_random_pdf_pair(seed_root / pdf_source, pdf_seed, revision=PDF_REVISION_0, title="TC0069 remotely moved PDF")
        generated_remote_images = create_random_image_set(seed_root / image_source, image_seed, revision=IMAGE_REVISION_0, title="TC0069 remotely moved images")

        phase_files = {label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log") for label in ("seed", "validator_initial", "mutator_initial", "mutator_move", "validator_reconcile", "verify")}
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {
            "root_name": root_name,
            "text_source": text_source,
            "text_destination": text_destination,
            "xlsx_source": xlsx_source,
            "xlsx_destination": xlsx_destination,
            "pdf_source": pdf_source,
            "pdf_destination": pdf_destination,
            "image_source": image_source,
            "image_destination": image_destination,
            "xlsx_seed": xlsx_seed,
            "pdf_seed": pdf_seed,
            "occupant_xlsx_seed": occupant_xlsx_seed,
            "occupant_pdf_seed": occupant_pdf_seed,
            "image_seed": image_seed,
            "occupant_image_seed": occupant_image_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_remote_xlsx_size": int(generated_remote["size_bytes"]),
            "generated_remote_pdf_size": int(generated_remote_pdf["size_bytes"]),
            "generated_remote_large_pdf_size": int(generated_remote_pdf["large_size_bytes"]),
            "generated_remote_image_sizes": {k: int(v) for k, v in generated_remote_images.items() if k.endswith("_size_bytes")},
        }

        seed = self._run_phase(context, label="seed", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True), stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1])
        validator_initial = self._run_phase(context, label="validator initial", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_validator, mode="download-only", resync=True), stdout_file=phase_files["validator_initial"][0], stderr_file=phase_files["validator_initial"][1])
        mutator_initial = self._run_phase(context, label="mutator initial", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_mutator, mode="download-only", resync=True), stdout_file=phase_files["mutator_initial"][0], stderr_file=phase_files["mutator_initial"][1])
        validator_initial_xlsx_error = validate_xlsx_pair(validator_root / xlsx_source, REVISION_0)
        mutator_initial_xlsx_error = validate_xlsx_pair(mutator_root / xlsx_source, REVISION_0)
        validator_initial_pdf_error = validate_pdf_pair(validator_root / pdf_source, PDF_REVISION_0)
        mutator_initial_pdf_error = validate_pdf_pair(mutator_root / pdf_source, PDF_REVISION_0)
        validator_initial_image_error = validate_image_set(validator_root / image_source, IMAGE_REVISION_0)
        mutator_initial_image_error = validate_image_set(mutator_root / image_source, IMAGE_REVISION_0)
        details.update({
            "seed_returncode": seed.returncode,
            "validator_initial_returncode": validator_initial.returncode,
            "mutator_initial_returncode": mutator_initial.returncode,
            "validator_initial_xlsx_validation_error": validator_initial_xlsx_error,
            "mutator_initial_xlsx_validation_error": mutator_initial_xlsx_error,
            "validator_initial_pdf_validation_error": validator_initial_pdf_error,
            "mutator_initial_pdf_validation_error": mutator_initial_pdf_error,
            "validator_initial_image_validation_error": validator_initial_image_error,
            "mutator_initial_image_validation_error": mutator_initial_image_error,
        })
        if any(result.returncode != 0 for result in (seed, validator_initial, mutator_initial)) or validator_initial_xlsx_error or mutator_initial_xlsx_error or validator_initial_pdf_error or mutator_initial_pdf_error or validator_initial_image_error or mutator_initial_image_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Failed to establish remote-move TXT/XLSX/PDF baseline clients", artifacts=artifacts, details=details)

        validator_text_destination = validator_root / text_destination
        validator_xlsx_destination = validator_root / xlsx_destination
        validator_pdf_destination = validator_root / pdf_destination
        validator_image_destination = validator_root / image_destination
        write_text_file(validator_text_destination, occupant_text)
        generated_occupant = create_random_xlsx_pair(validator_xlsx_destination, occupant_xlsx_seed, revision=REVISION_1, payload_rows=self.XLSX_PAYLOAD_ROWS, title="TC0069 unsynchronised destination occupant workbook")
        generated_occupant_pdf = create_random_pdf_pair(validator_pdf_destination, occupant_pdf_seed, revision=PDF_REVISION_1, title="TC0069 unsynchronised destination occupant PDF")
        generated_occupant_images = create_random_image_set(validator_image_destination, occupant_image_seed, revision=IMAGE_REVISION_1, title="TC0069 unsynchronised destination occupant images")
        text_occupant_hash = self._hash_if_file(validator_text_destination)
        xlsx_occupant_hashes = xlsx_pair_hashes(validator_xlsx_destination, self._hash_if_file)
        pdf_occupant_hashes = pdf_pair_hashes(validator_pdf_destination, self._hash_if_file)
        image_occupant_hashes = image_set_hashes(validator_image_destination, self._hash_if_file)
        details["generated_occupant_xlsx_size"] = int(generated_occupant["size_bytes"])
        details["generated_occupant_pdf_size"] = int(generated_occupant_pdf["size_bytes"])
        details["generated_occupant_large_pdf_size"] = int(generated_occupant_pdf["large_size_bytes"])
        details["generated_occupant_image_sizes"] = {k: int(v) for k, v in generated_occupant_images.items() if k.endswith("_size_bytes")}

        mutator_text_source = mutator_root / text_source
        mutator_text_destination = mutator_root / text_destination
        mutator_xlsx_source = mutator_root / xlsx_source
        mutator_xlsx_destination = mutator_root / xlsx_destination
        mutator_pdf_source = mutator_root / pdf_source
        mutator_pdf_destination = mutator_root / pdf_destination
        mutator_image_source = mutator_root / image_source
        mutator_image_destination = mutator_root / image_destination
        mutator_text_destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(mutator_text_source, mutator_text_destination)
        rename_xlsx_pair(mutator_xlsx_source, mutator_xlsx_destination)
        rename_pdf_pair(mutator_pdf_source, mutator_pdf_destination)
        rename_image_set(mutator_image_source, mutator_image_destination)

        mutator_move = self._run_phase(context, label="mutator remote move", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_mutator), stdout_file=phase_files["mutator_move"][0], stderr_file=phase_files["mutator_move"][1])
        details["mutator_move_returncode"] = mutator_move.returncode
        if mutator_move.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Mutator move propagation failed with status {mutator_move.returncode}", artifacts=artifacts, details=details)

        validator_reconcile = self._run_phase(context, label="validator reconcile", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_validator, mode="download-only"), stdout_file=phase_files["validator_reconcile"][0], stderr_file=phase_files["validator_reconcile"][1])
        text_backups = self._safe_backup_files_for(validator_text_destination)
        xlsx_backups = xlsx_pair_backup_files(validator_xlsx_destination, self._safe_backup_files_for)
        pdf_backups = pdf_pair_backup_files(validator_pdf_destination, self._safe_backup_files_for)
        image_backups = image_set_backup_files(validator_image_destination, self._safe_backup_files_for)
        validator_xlsx_error = validate_xlsx_pair(validator_xlsx_destination, REVISION_0) if validator_xlsx_destination.is_file() else "Moved canonical XLSX is missing"
        validator_pdf_error = validate_pdf_pair(validator_pdf_destination, PDF_REVISION_0) if validator_pdf_destination.is_file() else "Moved canonical PDF is missing"
        validator_image_error = validate_image_set(validator_image_destination, IMAGE_REVISION_0) if validator_image_destination.is_file() else "Moved canonical image set is missing"
        backup_xlsx_error = validate_xlsx_pair_backups(xlsx_backups, REVISION_1)
        backup_pdf_error = validate_pdf_pair_backups(pdf_backups, PDF_REVISION_1)
        backup_image_error = validate_image_set_backups(image_backups, IMAGE_REVISION_1)
        details.update({
            "validator_reconcile_returncode": validator_reconcile.returncode,
            "text_source_exists_after_reconcile": (validator_root / text_source).exists(),
            "xlsx_source_exists_after_reconcile": xlsx_pair_any_exists(validator_root / xlsx_source),
            "pdf_source_exists_after_reconcile": pdf_pair_any_exists(validator_root / pdf_source),
            "image_source_exists_after_reconcile": image_set_any_exists(validator_root / image_source),
            "text_destination_content_after_reconcile": self._text_if_file(validator_text_destination),
            "xlsx_destination_validation_error": validator_xlsx_error,
            "pdf_destination_validation_error": validator_pdf_error,
            "image_destination_validation_error": validator_image_error,
            "text_safe_backup_files": [str(p.relative_to(validator_root)) for p in text_backups],
            "xlsx_safe_backup_files": {label: [str(p.relative_to(validator_root)) for p in paths] for label, paths in xlsx_backups.items()},
            "pdf_safe_backup_files": {label: [str(p.relative_to(validator_root)) for p in paths] for label, paths in pdf_backups.items()},
            "image_safe_backup_files": {label: [str(p.relative_to(validator_root)) for p in paths] for label, paths in image_backups.items()},
            "text_occupant_hash": text_occupant_hash,
            "xlsx_occupant_hashes": xlsx_occupant_hashes,
            "pdf_occupant_hashes": pdf_occupant_hashes,
            "image_occupant_hashes": image_occupant_hashes,
            "xlsx_safe_backup_validation_error": backup_xlsx_error,
            "pdf_safe_backup_validation_error": backup_pdf_error,
            "image_safe_backup_validation_error": backup_image_error,
        })

        verify = self._run_phase(context, label="verify remote move", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True), stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1])
        verify_xlsx_error = validate_xlsx_pair(verify_root / xlsx_destination, REVISION_0) if (verify_root / xlsx_destination).is_file() else "Verification destination XLSX is missing"
        verify_pdf_error = validate_pdf_pair(verify_root / pdf_destination, PDF_REVISION_0) if (verify_root / pdf_destination).is_file() else "Verification destination PDF is missing"
        verify_image_error = validate_image_set(verify_root / image_destination, IMAGE_REVISION_0) if (verify_root / image_destination).is_file() else "Verification destination image set is missing"
        details.update({
            "verify_returncode": verify.returncode,
            "verify_text_source_exists": (verify_root / text_source).exists(),
            "verify_xlsx_source_exists": xlsx_pair_any_exists(verify_root / xlsx_source),
            "verify_pdf_source_exists": pdf_pair_any_exists(verify_root / pdf_source),
            "verify_image_source_exists": image_set_any_exists(verify_root / image_source),
            "verify_text_destination_content": self._text_if_file(verify_root / text_destination),
            "verify_xlsx_destination_validation_error": verify_xlsx_error,
            "verify_pdf_destination_validation_error": verify_pdf_error,
            "verify_image_destination_validation_error": verify_image_error,
        })
        self._write_metadata(metadata_file, details)

        if validator_reconcile.returncode != 0:
            return self.fail_result(reason=f"Validator reconciliation failed with status {validator_reconcile.returncode}", artifacts=artifacts, details=details)
        if (validator_root / text_source).exists() or xlsx_pair_any_exists(validator_root / xlsx_source) or pdf_pair_any_exists(validator_root / pdf_source) or image_set_any_exists(validator_root / image_source):
            return self.fail_result(reason="One or more stale source paths remained after remote move reconciliation", artifacts=artifacts, details=details)
        if self._text_if_file(validator_text_destination) != moved_text:
            return self.fail_result(reason="Moved remote TXT file did not take the occupied canonical destination pathname", artifacts=artifacts, details=details)
        if validator_xlsx_error:
            return self.fail_result(reason=f"Moved remote XLSX did not take the occupied canonical destination pathname: {validator_xlsx_error}", artifacts=artifacts, details=details)
        if validator_image_error:
            return self.fail_result(reason=f"Moved remote image set did not take the occupied canonical destination pathname: {validator_image_error}", artifacts=artifacts, details=details)
        if validator_pdf_error:
            return self.fail_result(reason=f"Moved remote PDF did not take the occupied canonical destination pathname: {validator_pdf_error}", artifacts=artifacts, details=details)
        if len(text_backups) != 1 or self._hash_if_file(text_backups[0]) != text_occupant_hash or self._text_if_file(text_backups[0]) != occupant_text:
            return self.fail_result(reason="Occupied TXT destination was not preserved exactly once as safeBackup", artifacts=artifacts, details=details)
        if xlsx_pair_backup_hashes(xlsx_backups, self._hash_if_file) != xlsx_occupant_hashes or backup_xlsx_error:
            return self.fail_result(reason=f"Occupied XLSX destination was not preserved exactly once as a valid safeBackup: {backup_xlsx_error}", artifacts=artifacts, details=details)
        if image_set_backup_hashes(image_backups, self._hash_if_file) != image_occupant_hashes or backup_image_error:
            return self.fail_result(reason=f"Occupied image destination was not preserved exactly once as a valid safeBackup: {backup_image_error}", artifacts=artifacts, details=details)
        if pdf_pair_backup_hashes(pdf_backups, self._hash_if_file) != pdf_occupant_hashes or backup_pdf_error:
            return self.fail_result(reason=f"Occupied PDF destination was not preserved exactly once as a valid safeBackup: {backup_pdf_error}", artifacts=artifacts, details=details)
        if verify.returncode != 0 or (verify_root / text_source).exists() or xlsx_pair_any_exists(verify_root / xlsx_source) or pdf_pair_any_exists(verify_root / pdf_source) or image_set_any_exists(verify_root / image_source) or self._text_if_file(verify_root / text_destination) != moved_text or verify_xlsx_error or verify_pdf_error or verify_image_error:
            return self.fail_result(reason=f"Fresh verification did not confirm the TXT/XLSX/PDF remote move result: XLSX={verify_xlsx_error}; PDF={verify_pdf_error}", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
