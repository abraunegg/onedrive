from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0075SafeBackupRemoteDeleteLocalModifyValidation(SafeBackupCaseBase):
    case_id = "0075"
    name = "safeBackup remote-delete local-modification validation"
    description = (
        "Validate the intentional destructive safeBackup workflow where a tracked file is deleted online "
        "after being independently modified locally"
    )

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
        relative = f"{root_name}/deleted-online.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        deleter_file = deleter_root / relative
        verify_file = verify_root / relative
        baseline = "TC0075 baseline content before remote deletion\n"
        local_modified = "TC0075 locally modified content that must survive the remote deletion\n"
        write_text_file(seed_file, baseline)

        phase_names = ("seed", "local_baseline", "deleter_baseline", "remote_delete", "reconcile", "verify")
        phase_files = {name: (logs / f"{name}_stdout.log", logs / f"{name}_stderr.log") for name in phase_names}
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

        seed = self._run_phase(
            context, label="seed remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1],
        )
        if seed.returncode != 0:
            details["seed_returncode"] = seed.returncode
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote seed failed with status {seed.returncode}", artifacts=artifacts, details=details)

        local_baseline = self._run_phase(
            context, label="establish local tracked baseline",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True),
            stdout_file=phase_files["local_baseline"][0], stderr_file=phase_files["local_baseline"][1],
        )
        deleter_baseline = self._run_phase(
            context, label="establish deleter tracked baseline",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_deleter, mode="download-only", resync=True),
            stdout_file=phase_files["deleter_baseline"][0], stderr_file=phase_files["deleter_baseline"][1],
        )
        details.update({"local_baseline_returncode": local_baseline.returncode, "deleter_baseline_returncode": deleter_baseline.returncode})
        if local_baseline.returncode != 0 or deleter_baseline.returncode != 0 or self._text_if_file(local_file) != baseline or self._text_if_file(deleter_file) != baseline:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason="Failed to establish tracked baselines before remote-delete conflict", artifacts=artifacts, details=details)

        write_text_file(local_file, local_modified)
        local_modified_hash = self._hash_if_file(local_file)

        deleter_file.unlink()
        remote_delete = self._run_phase(
            context, label="propagate remote delete",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_deleter, mode="sync"),
            stdout_file=phase_files["remote_delete"][0], stderr_file=phase_files["remote_delete"][1],
        )
        details["remote_delete_returncode"] = remote_delete.returncode
        if remote_delete.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote delete propagation failed with status {remote_delete.returncode}", artifacts=artifacts, details=details)

        reconcile = self._run_phase(
            context, label="reconcile remote deletion against locally modified file",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="sync", verbose_count=2),
            stdout_file=phase_files["reconcile"][0], stderr_file=phase_files["reconcile"][1],
        )

        backups = self._safe_backup_files_for(local_file)
        partials = self._partial_files_under(local_root / root_name)
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "canonical_exists_after_reconcile": local_file.exists(),
                "local_modified_hash": local_modified_hash,
                "safe_backup_files": [str(p.relative_to(local_root)) for p in backups],
                "safe_backup_hashes": [self._hash_if_file(p) for p in backups],
                "partial_files": [str(p.relative_to(local_root)) for p in partials],
            }
        )

        verify = self._run_phase(
            context, label="verify remote deletion",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1],
        )
        remote_backups = self._safe_backup_files_for(verify_file)
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_canonical_exists": verify_file.exists(),
                "verify_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_backups],
                "verify_safe_backup_hashes": [self._hash_if_file(p) for p in remote_backups],
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(reason=f"Remote-delete reconciliation failed with status {reconcile.returncode}", artifacts=artifacts, details=details)
        if local_file.exists():
            return self.fail_result(reason="Canonical local file remained present even though the authoritative online item was deleted", artifacts=artifacts, details=details)
        if len(backups) != 1 or self._text_if_file(backups[0]) != local_modified or self._hash_if_file(backups[0]) != local_modified_hash:
            return self.fail_result(reason="Remote-delete conflict did not preserve exactly one safeBackup containing the locally modified bytes", artifacts=artifacts, details=details)
        if partials:
            return self.fail_result(reason="Remote-delete conflict left an unexpected .partial file", artifacts=artifacts, details=details)
        if verify.returncode != 0 or verify_file.exists():
            return self.fail_result(reason="Fresh verification did not confirm that the canonical online file remains deleted", artifacts=artifacts, details=details)
        if len(remote_backups) != 1 or self._hash_if_file(remote_backups[0]) != local_modified_hash:
            return self.fail_result(reason="Fresh verification did not confirm that the preserved local safeBackup was uploaded", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
