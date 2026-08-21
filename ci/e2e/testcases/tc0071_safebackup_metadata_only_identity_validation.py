from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0071SafeBackupMetadataOnlyIdentityValidation(SafeBackupCaseBase):
    case_id = "0071"
    name = "safeBackup metadata-only identity validation"
    description = (
        "Validate that identical local and online content with different local metadata is reconciled "
        "without creating a safeBackup or treating the file as a content conflict"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0071", ensure_refresh_token=True)
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

        root_name = f"ZZ_E2E_TC0071_{context.run_id}_{os.getpid()}"
        relative = f"{root_name}/metadata-only.txt"
        seed_file = seed_root / relative
        local_file = local_root / relative
        verify_file = verify_root / relative
        content = "TC0071 content is identical; only local mtime starts different\n"
        write_text_file(seed_file, content)

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        reconcile_stdout, reconcile_stderr = logs / "reconcile_stdout.log", logs / "reconcile_stderr.log"
        verify_stdout, verify_stderr = logs / "verify_stdout.log", logs / "verify_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [str(seed_stdout), str(seed_stderr), str(reconcile_stdout), str(reconcile_stderr), str(verify_stdout), str(verify_stderr), str(metadata_file)]
        details: dict[str, object] = {"root_name": root_name, "relative": relative}

        seed = self._run_phase(
            context, label="seed remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True),
            stdout_file=seed_stdout, stderr_file=seed_stderr,
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote seed failed with status {seed.returncode}", artifacts=artifacts, details=details)

        write_text_file(local_file, content)
        deliberately_different_mtime = int(time.time()) + 7200
        os.utime(local_file, (deliberately_different_mtime, deliberately_different_mtime))
        initial_hash = self._hash_if_file(local_file)

        reconcile = self._run_phase(
            context, label="metadata-only reconcile",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, resync=True, verbose_count=2),
            stdout_file=reconcile_stdout, stderr_file=reconcile_stderr,
        )
        details["reconcile_returncode"] = reconcile.returncode
        backups = self._safe_backup_files_for(local_file)
        details.update(
            {
                "deliberately_different_mtime": deliberately_different_mtime,
                "canonical_exists": local_file.is_file(),
                "canonical_content": self._text_if_file(local_file),
                "canonical_hash": self._hash_if_file(local_file),
                "canonical_mtime_after_reconcile": int(local_file.stat().st_mtime) if local_file.is_file() else -1,
                "initial_hash": initial_hash,
                "safe_backup_files": [str(p.relative_to(local_root)) for p in backups],
                "partial_files": [str(p.relative_to(local_root)) for p in self._partial_files_under(local_root / root_name)],
            }
        )

        verify = self._run_phase(
            context, label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=verify_stdout, stderr_file=verify_stderr,
        )
        details.update(
            {
                "verify_returncode": verify.returncode,
                "verify_content": self._text_if_file(verify_file),
                "verify_hash": self._hash_if_file(verify_file),
                "verify_mtime": int(verify_file.stat().st_mtime) if verify_file.is_file() else -1,
            }
        )
        self._write_metadata(metadata_file, details)

        if reconcile.returncode != 0:
            return self.fail_result(reason=f"Metadata-only reconciliation failed with status {reconcile.returncode}", artifacts=artifacts, details=details)
        if not local_file.is_file() or self._hash_if_file(local_file) != initial_hash or self._text_if_file(local_file) != content:
            return self.fail_result(reason="Metadata-only reconciliation changed canonical file content", artifacts=artifacts, details=details)
        if backups:
            return self.fail_result(reason="Metadata-only reconciliation incorrectly created a safeBackup for identical content", artifacts=artifacts, details=details)
        if self._partial_files_under(local_root / root_name):
            return self.fail_result(reason="Metadata-only reconciliation left an unexpected .partial file", artifacts=artifacts, details=details)
        if verify.returncode != 0 or self._hash_if_file(verify_file) != initial_hash:
            return self.fail_result(reason="Fresh verification did not confirm unchanged online content", artifacts=artifacts, details=details)
        if int(local_file.stat().st_mtime) == deliberately_different_mtime:
            return self.fail_result(reason="Metadata-only reconciliation did not correct the deliberately divergent local mtime", artifacts=artifacts, details=details)
        if int(local_file.stat().st_mtime) != int(verify_file.stat().st_mtime):
            return self.fail_result(reason="Local mtime after metadata-only reconciliation does not match authoritative downloaded metadata", artifacts=artifacts, details=details)

        return self.pass_result(artifacts=artifacts, details=details)
