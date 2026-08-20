from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0066SafeBackupTransactionalReplacementValidation(SafeBackupCaseBase):
    case_id = "0066"
    name = "safeBackup transactional replacement validation"
    description = (
        "Validate that a remote-newer/local-modified conflict completes with the authoritative "
        "remote file at the canonical pathname and the prior local bytes preserved as safeBackup"
    )

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
        relative = f"{root_name}/conflict.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        updater_file = updater_root / relative
        verify_file = verify_root / relative

        baseline = "TC0066 baseline remote content\n"
        local_conflict = "TC0066 locally modified content that must be preserved\n"
        remote_replacement = "TC0066 newer authoritative remote replacement\n"
        write_text_file(seed_file, baseline)

        phase_files = {
            label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log")
            for label in ("seed", "initial_download", "remote_update", "reconcile", "verify")
        }
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

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
        if initial.returncode != 0 or self._text_if_file(local_file) != baseline:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Initial local baseline download failed", artifacts=artifacts, details=details)

        time.sleep(2)
        write_text_file(local_file, local_conflict)
        local_conflict_hash = self._hash_if_file(local_file)
        local_conflict_mtime = int(local_file.stat().st_mtime)

        time.sleep(2)
        write_text_file(updater_file, remote_replacement)
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

        backups = self._safe_backup_files_for(local_file)
        partials = self._partial_files_under(local_root / root_name)
        details.update(
            {
                "canonical_exists": local_file.is_file(),
                "canonical_content": self._text_if_file(local_file),
                "canonical_hash": self._hash_if_file(local_file),
                "local_conflict_hash": local_conflict_hash,
                "local_conflict_mtime": local_conflict_mtime,
                "safe_backup_files": [str(p.relative_to(local_root)) for p in backups],
                "safe_backup_hashes": [self._hash_if_file(p) for p in backups],
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
        details["verify_returncode"] = verify.returncode
        details["verify_content"] = self._text_if_file(verify_file)
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(reason=f"Conflict reconciliation failed with status {reconcile.returncode}", artifacts=artifacts, details=details)
        if not local_file.is_file():
            return self.fail_result(reason="Canonical filename is missing after successful replacement conflict resolution", artifacts=artifacts, details=details)
        if self._text_if_file(local_file) != remote_replacement:
            return self.fail_result(reason="Canonical filename does not contain the authoritative remote replacement", artifacts=artifacts, details=details)
        if len(backups) != 1:
            return self.fail_result(reason=f"Expected exactly one safeBackup for the displaced local version, found {len(backups)}", artifacts=artifacts, details=details)
        if self._text_if_file(backups[0]) != local_conflict or self._hash_if_file(backups[0]) != local_conflict_hash:
            return self.fail_result(reason="safeBackup does not contain the exact pre-replacement local bytes", artifacts=artifacts, details=details)
        if partials:
            return self.fail_result(reason="Completed replacement left unexpected .partial files behind", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._text_if_file(verify_file) != remote_replacement:
            return self.fail_result(reason="Fresh client verification did not confirm the authoritative remote replacement", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
