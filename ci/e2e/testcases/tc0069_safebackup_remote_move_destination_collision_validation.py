from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx, validate_xlsx
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0069SafeBackupRemoteMoveDestinationCollisionValidation(SafeBackupCaseBase):
    case_id = "0069"
    name = "safeBackup remote move destination collision validation"
    description = (
        "Validate with passive TXT and real XLSX payloads that reconciling remote moves into occupied "
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
        control_relative = f"{root_name}/destination/control.txt"
        moved_text = "TC0069 remote item that will be moved\n"
        occupant_text = "TC0069 unsynchronised local destination occupant that must be preserved\n"
        control_content = "TC0069 destination directory control file\n"

        write_text_file(seed_root / text_source, moved_text)
        write_text_file(seed_root / control_relative, control_content)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0069:remote:{os.getpid()}"
        occupant_xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0069:occupant:{os.getpid()}"
        generated_remote = create_random_xlsx(seed_root / xlsx_source, xlsx_seed, revision=REVISION_0, payload_rows=self.XLSX_PAYLOAD_ROWS, title="TC0069 remotely moved workbook")

        phase_files = {label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log") for label in ("seed", "validator_initial", "mutator_initial", "mutator_move", "validator_reconcile", "verify")}
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {
            "root_name": root_name,
            "text_source": text_source,
            "text_destination": text_destination,
            "xlsx_source": xlsx_source,
            "xlsx_destination": xlsx_destination,
            "xlsx_seed": xlsx_seed,
            "occupant_xlsx_seed": occupant_xlsx_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_remote_xlsx_size": int(generated_remote["size_bytes"]),
        }

        seed = self._run_phase(context, label="seed", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True), stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1])
        validator_initial = self._run_phase(context, label="validator initial", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_validator, mode="download-only", resync=True), stdout_file=phase_files["validator_initial"][0], stderr_file=phase_files["validator_initial"][1])
        mutator_initial = self._run_phase(context, label="mutator initial", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_mutator, mode="download-only", resync=True), stdout_file=phase_files["mutator_initial"][0], stderr_file=phase_files["mutator_initial"][1])
        validator_initial_xlsx_error = validate_xlsx(validator_root / xlsx_source, REVISION_0)
        mutator_initial_xlsx_error = validate_xlsx(mutator_root / xlsx_source, REVISION_0)
        details.update({
            "seed_returncode": seed.returncode,
            "validator_initial_returncode": validator_initial.returncode,
            "mutator_initial_returncode": mutator_initial.returncode,
            "validator_initial_xlsx_validation_error": validator_initial_xlsx_error,
            "mutator_initial_xlsx_validation_error": mutator_initial_xlsx_error,
        })
        if any(result.returncode != 0 for result in (seed, validator_initial, mutator_initial)) or validator_initial_xlsx_error or mutator_initial_xlsx_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Failed to establish remote-move TXT/XLSX baseline clients", artifacts=artifacts, details=details)

        validator_text_destination = validator_root / text_destination
        validator_xlsx_destination = validator_root / xlsx_destination
        write_text_file(validator_text_destination, occupant_text)
        generated_occupant = create_random_xlsx(validator_xlsx_destination, occupant_xlsx_seed, revision=REVISION_1, payload_rows=self.XLSX_PAYLOAD_ROWS, title="TC0069 unsynchronised destination occupant workbook")
        text_occupant_hash = self._hash_if_file(validator_text_destination)
        xlsx_occupant_hash = self._hash_if_file(validator_xlsx_destination)
        details["generated_occupant_xlsx_size"] = int(generated_occupant["size_bytes"])

        mutator_text_source = mutator_root / text_source
        mutator_text_destination = mutator_root / text_destination
        mutator_xlsx_source = mutator_root / xlsx_source
        mutator_xlsx_destination = mutator_root / xlsx_destination
        mutator_text_destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(mutator_text_source, mutator_text_destination)
        os.replace(mutator_xlsx_source, mutator_xlsx_destination)

        mutator_move = self._run_phase(context, label="mutator remote move", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_mutator), stdout_file=phase_files["mutator_move"][0], stderr_file=phase_files["mutator_move"][1])
        details["mutator_move_returncode"] = mutator_move.returncode
        if mutator_move.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Mutator move propagation failed with status {mutator_move.returncode}", artifacts=artifacts, details=details)

        validator_reconcile = self._run_phase(context, label="validator reconcile", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_validator, mode="download-only"), stdout_file=phase_files["validator_reconcile"][0], stderr_file=phase_files["validator_reconcile"][1])
        text_backups = self._safe_backup_files_for(validator_text_destination)
        xlsx_backups = self._safe_backup_files_for(validator_xlsx_destination)
        validator_xlsx_error = validate_xlsx(validator_xlsx_destination, REVISION_0) if validator_xlsx_destination.is_file() else "Moved canonical XLSX is missing"
        backup_xlsx_error = validate_xlsx(xlsx_backups[0], REVISION_1) if len(xlsx_backups) == 1 else "Expected exactly one XLSX safeBackup"
        details.update({
            "validator_reconcile_returncode": validator_reconcile.returncode,
            "text_source_exists_after_reconcile": (validator_root / text_source).exists(),
            "xlsx_source_exists_after_reconcile": (validator_root / xlsx_source).exists(),
            "text_destination_content_after_reconcile": self._text_if_file(validator_text_destination),
            "xlsx_destination_validation_error": validator_xlsx_error,
            "text_safe_backup_files": [str(p.relative_to(validator_root)) for p in text_backups],
            "xlsx_safe_backup_files": [str(p.relative_to(validator_root)) for p in xlsx_backups],
            "text_occupant_hash": text_occupant_hash,
            "xlsx_occupant_hash": xlsx_occupant_hash,
            "xlsx_safe_backup_validation_error": backup_xlsx_error,
        })

        verify = self._run_phase(context, label="verify remote move", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True), stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1])
        verify_xlsx_error = validate_xlsx(verify_root / xlsx_destination, REVISION_0) if (verify_root / xlsx_destination).is_file() else "Verification destination XLSX is missing"
        details.update({
            "verify_returncode": verify.returncode,
            "verify_text_source_exists": (verify_root / text_source).exists(),
            "verify_xlsx_source_exists": (verify_root / xlsx_source).exists(),
            "verify_text_destination_content": self._text_if_file(verify_root / text_destination),
            "verify_xlsx_destination_validation_error": verify_xlsx_error,
        })
        self._write_metadata(metadata_file, details)

        if validator_reconcile.returncode != 0:
            return self.fail_result(reason=f"Validator reconciliation failed with status {validator_reconcile.returncode}", artifacts=artifacts, details=details)
        if (validator_root / text_source).exists() or (validator_root / xlsx_source).exists():
            return self.fail_result(reason="One or more stale source paths remained after remote move reconciliation", artifacts=artifacts, details=details)
        if self._text_if_file(validator_text_destination) != moved_text:
            return self.fail_result(reason="Moved remote TXT file did not take the occupied canonical destination pathname", artifacts=artifacts, details=details)
        if validator_xlsx_error:
            return self.fail_result(reason=f"Moved remote XLSX did not take the occupied canonical destination pathname: {validator_xlsx_error}", artifacts=artifacts, details=details)
        if len(text_backups) != 1 or self._hash_if_file(text_backups[0]) != text_occupant_hash or self._text_if_file(text_backups[0]) != occupant_text:
            return self.fail_result(reason="Occupied TXT destination was not preserved exactly once as safeBackup", artifacts=artifacts, details=details)
        if len(xlsx_backups) != 1 or self._hash_if_file(xlsx_backups[0]) != xlsx_occupant_hash or backup_xlsx_error:
            return self.fail_result(reason=f"Occupied XLSX destination was not preserved exactly once as a valid safeBackup: {backup_xlsx_error}", artifacts=artifacts, details=details)
        if verify.returncode != 0 or (verify_root / text_source).exists() or (verify_root / xlsx_source).exists() or self._text_if_file(verify_root / text_destination) != moved_text or verify_xlsx_error:
            return self.fail_result(reason=f"Fresh verification did not confirm the TXT/XLSX remote move result: {verify_xlsx_error}", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
