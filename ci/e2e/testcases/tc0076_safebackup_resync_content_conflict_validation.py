from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0076SafeBackupResyncContentConflictValidation(SafeBackupCaseBase):
    case_id = "0076"
    name = "safeBackup resync content-conflict validation"
    description = (
        "Validate that --resync preserves a same-path local file as safeBackup when there is no usable DB identity "
        "and the local content genuinely differs from the authoritative online file"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0076", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, local_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_verify = work / "conf-verify"
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0076_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/resync-conflict.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        verify_file = verify_root / relative
        remote_content = "TC0076 authoritative online content\n"
        local_content = "TC0076 different local content with no usable DB identity\n"
        write_text_file(seed_file, remote_content)

        phase_names = ("seed", "reconcile", "verify")
        phase_files = {name: (logs / f"{name}_stdout.log", logs / f"{name}_stderr.log") for name in phase_names}
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

        seed = self._run_phase(
            context, label="seed remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1],
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote seed failed with status {seed.returncode}", artifacts=artifacts, details=details)

        write_text_file(local_file, local_content)
        local_hash = self._hash_if_file(local_file)

        reconcile = self._run_phase(
            context, label="resync content conflict",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="sync", resync=True, verbose_count=2),
            stdout_file=phase_files["reconcile"][0], stderr_file=phase_files["reconcile"][1],
        )
        backups = self._safe_backup_files_for(local_file)
        partials = self._partial_files_under(local_root / root_name)
        details.update(
            {
                "reconcile_returncode": reconcile.returncode,
                "canonical_exists": local_file.is_file(),
                "canonical_content": self._text_if_file(local_file),
                "canonical_hash": self._hash_if_file(local_file),
                "local_pre_resync_hash": local_hash,
                "safe_backup_files": [str(p.relative_to(local_root)) for p in backups],
                "safe_backup_hashes": [self._hash_if_file(p) for p in backups],
                "partial_files": [str(p.relative_to(local_root)) for p in partials],
            }
        )

        verify = self._run_phase(
            context, label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1],
        )
        remote_backups = self._safe_backup_files_for(verify_file)
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_content": self._text_if_file(verify_file),
                "verify_safe_backup_files": [str(p.relative_to(verify_root)) for p in remote_backups],
                "verify_safe_backup_hashes": [self._hash_if_file(p) for p in remote_backups],
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(reason=f"Resync content-conflict reconciliation failed with status {reconcile.returncode}", artifacts=artifacts, details=details)
        if not local_file.is_file() or self._text_if_file(local_file) != remote_content:
            return self.fail_result(reason="Resync content conflict did not leave the authoritative online content at the canonical pathname", artifacts=artifacts, details=details)
        if len(backups) != 1 or self._text_if_file(backups[0]) != local_content or self._hash_if_file(backups[0]) != local_hash:
            return self.fail_result(reason="Resync content conflict did not preserve exactly one safeBackup containing the pre-resync local bytes", artifacts=artifacts, details=details)
        if partials:
            return self.fail_result(reason="Resync content conflict left an unexpected .partial file", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._text_if_file(verify_file) != remote_content:
            return self.fail_result(reason="Fresh verification did not confirm the authoritative online canonical content", artifacts=artifacts, details=details)
        if len(remote_backups) != 1 or self._hash_if_file(remote_backups[0]) != local_hash:
            return self.fail_result(reason="Fresh verification did not confirm the resync-preserved safeBackup online", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
