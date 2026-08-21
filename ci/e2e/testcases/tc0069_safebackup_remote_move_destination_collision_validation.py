from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0069SafeBackupRemoteMoveDestinationCollisionValidation(SafeBackupCaseBase):
    case_id = "0069"
    name = "safeBackup remote move destination collision validation"
    description = (
        "Validate that reconciling a remote move into an occupied local destination preserves "
        "the displaced local file as safeBackup while the moved remote file takes the canonical name"
    )

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
        for conf, root in (
            (conf_seed, seed_root),
            (conf_validator, validator_root),
            (conf_mutator, mutator_root),
            (conf_verify, verify_root),
        ):
            self._prepare_config(context, conf, root)

        root_name = f"ZZ_E2E_TC0069_{context.run_id}_{os.getpid()}"
        source_relative = f"{root_name}/source/move-me.txt"
        destination_relative = f"{root_name}/destination/move-me.txt"
        control_relative = f"{root_name}/destination/control.txt"
        moved_content = "TC0069 remote item that will be moved\n"
        occupant_content = "TC0069 unsynchronised local destination occupant that must be preserved\n"
        control_content = "TC0069 destination directory control file\n"

        write_text_file(seed_root / source_relative, moved_content)
        write_text_file(seed_root / control_relative, control_content)

        phase_files = {
            label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log")
            for label in ("seed", "validator_initial", "mutator_initial", "mutator_move", "validator_reconcile", "verify")
        }
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {
            "root_name": root_name,
            "source_relative": source_relative,
            "destination_relative": destination_relative,
        }

        seed = self._run_phase(
            context, label="seed",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1],
        )
        validator_initial = self._run_phase(
            context, label="validator initial",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_validator, mode="download-only", resync=True),
            stdout_file=phase_files["validator_initial"][0], stderr_file=phase_files["validator_initial"][1],
        )
        mutator_initial = self._run_phase(
            context, label="mutator initial",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_mutator, mode="download-only", resync=True),
            stdout_file=phase_files["mutator_initial"][0], stderr_file=phase_files["mutator_initial"][1],
        )
        details.update(
            {
                "seed_returncode": seed.returncode,
                "validator_initial_returncode": validator_initial.returncode,
                "mutator_initial_returncode": mutator_initial.returncode,
            }
        )
        if any(result.returncode != 0 for result in (seed, validator_initial, mutator_initial)):
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Failed to establish remote-move baseline clients", artifacts=artifacts, details=details)

        validator_destination = validator_root / destination_relative
        write_text_file(validator_destination, occupant_content)
        occupant_hash = self._hash_if_file(validator_destination)

        mutator_source = mutator_root / source_relative
        mutator_destination = mutator_root / destination_relative
        mutator_destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(mutator_source, mutator_destination)

        mutator_move = self._run_phase(
            context, label="mutator remote move",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_mutator),
            stdout_file=phase_files["mutator_move"][0], stderr_file=phase_files["mutator_move"][1],
        )
        details["mutator_move_returncode"] = mutator_move.returncode
        if mutator_move.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Mutator move propagation failed with status {mutator_move.returncode}", artifacts=artifacts, details=details)

        validator_reconcile = self._run_phase(
            context, label="validator reconcile",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_validator, mode="download-only"),
            stdout_file=phase_files["validator_reconcile"][0], stderr_file=phase_files["validator_reconcile"][1],
        )
        details["validator_reconcile_returncode"] = validator_reconcile.returncode

        validator_source = validator_root / source_relative
        backups = self._safe_backup_files_for(validator_destination)
        details.update(
            {
                "source_exists_after_reconcile": validator_source.exists(),
                "destination_exists_after_reconcile": validator_destination.is_file(),
                "destination_content_after_reconcile": self._text_if_file(validator_destination),
                "safe_backup_files": [str(p.relative_to(validator_root)) for p in backups],
                "safe_backup_hashes": [self._hash_if_file(p) for p in backups],
                "occupant_hash": occupant_hash,
            }
        )

        verify = self._run_phase(
            context, label="verify remote move",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1],
        )
        verify_source = verify_root / source_relative
        verify_destination = verify_root / destination_relative
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_source_exists": verify_source.exists(),
                "verify_destination_content": self._text_if_file(verify_destination),
            }
        )
        self._write_metadata(metadata_file, details)

        if validator_reconcile.returncode != 0:
            return self.fail_result(reason=f"Validator reconciliation failed with status {validator_reconcile.returncode}", artifacts=artifacts, details=details)
        if validator_source.exists():
            return self.fail_result(reason="Stale source path remained after remote move reconciliation", artifacts=artifacts, details=details)
        if not validator_destination.is_file() or self._text_if_file(validator_destination) != moved_content:
            return self.fail_result(reason="Moved remote file did not take the occupied canonical destination pathname", artifacts=artifacts, details=details)
        if len(backups) != 1 or self._hash_if_file(backups[0]) != occupant_hash or self._text_if_file(backups[0]) != occupant_content:
            return self.fail_result(reason="Occupied destination was not preserved exactly once as safeBackup", artifacts=artifacts, details=details)
        if verify.returncode != 0 or verify_source.exists() or self._text_if_file(verify_destination) != moved_content:
            return self.fail_result(reason="Fresh verification did not confirm the remote move result", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
