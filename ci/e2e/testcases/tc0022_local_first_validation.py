from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)
from framework.xlsx import REVISION_0, REVISION_1, REVISION_2, create_random_xlsx, mutate_xlsx_revision, validate_xlsx


class TestCase0022LocalFirstValidation(E2ETestCase):
    case_id = "0022"
    name = "local_first validation"
    description = (
        "Validate with a real XLSX workbook that local_first treats local content as the source of truth during a conflict"
    )

    XLSX_PAYLOAD_ROWS = 32

    def _write_config(self, config_path: Path, sync_dir: Path, local_first: bool = False) -> None:
        content = (
            "# tc0022 config\n"
            f'sync_dir = "{sync_dir}"\n'
        )
        if local_first:
            content += 'local_first = "true"\n'
        write_onedrive_config(config_path, content)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0022",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        seed_root = case_work_dir / "seedroot"
        local_root = case_work_dir / "localroot"
        remote_update_root = case_work_dir / "remoteupdateroot"
        verify_root = case_work_dir / "verifyroot"

        conf_seed = case_work_dir / "conf-seed"
        conf_local = case_work_dir / "conf-local"
        conf_remote = case_work_dir / "conf-remote"
        conf_verify = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0022_{context.run_id}_{os.getpid()}"
        relative_file = f"{root_name}/conflict.xlsx"
        seed_file = seed_root / relative_file
        local_file = local_root / relative_file
        remote_update_file = remote_update_root / relative_file
        verify_file = verify_root / relative_file
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0022:{os.getpid()}"

        reset_directory(seed_root)
        reset_directory(local_root)
        reset_directory(remote_update_root)
        reset_directory(verify_root)

        generated_seed = create_random_xlsx(
            seed_file,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0022 local_first baseline workbook",
        )
        generated_remote = create_random_xlsx(
            remote_update_file,
            xlsx_seed,
            revision=REVISION_1,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0022 local_first baseline workbook",
        )

        context.bootstrap_config_dir(conf_seed)
        self._write_config(conf_seed / "config", seed_root)

        context.bootstrap_config_dir(conf_local)
        self._write_config(conf_local / "config", local_root)

        context.bootstrap_config_dir(conf_remote)
        self._write_config(conf_remote / "config", remote_update_root)

        context.bootstrap_config_dir(conf_verify)
        self._write_config(conf_verify / "config", verify_root)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        download_stdout = case_log_dir / "download_stdout.log"
        download_stderr = case_log_dir / "download_stderr.log"
        remote_stdout = case_log_dir / "remote_update_stdout.log"
        remote_stderr = case_log_dir / "remote_update_stderr.log"
        final_stdout = case_log_dir / "final_sync_stdout.log"
        final_stderr = case_log_dir / "final_sync_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(download_stdout),
            str(download_stderr),
            str(remote_stdout),
            str(remote_stderr),
            str(final_stdout),
            str(final_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "root_name": root_name,
            "relative_file": relative_file,
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_seed_size": int(generated_seed["size_bytes"]),
            "generated_remote_update_size": int(generated_remote["size_bytes"]),
        }

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seed),
        ]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)

        download_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} download: {command_to_string(download_command)}")
        download_result = run_command(download_command, cwd=context.repo_root)
        write_text_file(download_stdout, download_result.stdout)
        write_text_file(download_stderr, download_result.stderr)

        baseline_validation_error = validate_xlsx(local_file, REVISION_0) if local_file.is_file() else "Local baseline XLSX is missing"
        details["baseline_validation_error"] = baseline_validation_error
        if local_file.is_file():
            details["baseline_hash"] = compute_quickxor_hash_file(local_file)
            details["baseline_size"] = local_file.stat().st_size

        remote_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_remote),
        ]
        context.log(f"Executing Test Case {self.case_id} remote update: {command_to_string(remote_command)}")
        remote_result = run_command(remote_command, cwd=context.repo_root)
        write_text_file(remote_stdout, remote_result.stdout)
        write_text_file(remote_stderr, remote_result.stderr)

        # Ensure the local edit is definitively later than the remote update.
        # This is critical so the final sync actually exercises local_first.
        time.sleep(2)

        local_revision_error = ""
        expected_hash = ""
        if local_file.is_file() and not baseline_validation_error:
            mutate_xlsx_revision(local_file, REVISION_0, REVISION_2)
            local_revision_error = validate_xlsx(local_file, REVISION_2)
            expected_hash = compute_quickxor_hash_file(local_file)
            now = time.time()
            os.utime(local_file, (now, now))
        else:
            local_revision_error = baseline_validation_error or "Unable to mutate missing local XLSX"

        details["local_revision_error"] = local_revision_error
        details["expected_local_hash"] = expected_hash
        details["local_mtime_before_final_sync"] = local_file.stat().st_mtime if local_file.exists() else 0

        # Reuse the same local DB / delta state, but enable local_first.
        self._write_config(conf_local / "config", local_root, local_first=True)

        final_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} final sync: {command_to_string(final_command)}")
        final_result = run_command(final_command, cwd=context.repo_root)
        write_text_file(final_stdout, final_result.stdout)
        write_text_file(final_stderr, final_result.stderr)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify),
        ]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        local_validation_error = validate_xlsx(local_file, REVISION_2) if local_file.is_file() else "Local XLSX is missing"
        remote_validation_error = validate_xlsx(verify_file, REVISION_2) if verify_file.is_file() else "Remote verification XLSX is missing"
        local_hash = compute_quickxor_hash_file(local_file) if local_file.is_file() else ""
        remote_hash = compute_quickxor_hash_file(verify_file) if verify_file.is_file() else ""

        details.update(
            {
                "seed_returncode": seed_result.returncode,
                "download_returncode": download_result.returncode,
                "remote_returncode": remote_result.returncode,
                "final_returncode": final_result.returncode,
                "verify_returncode": verify_result.returncode,
                "local_validation_error": local_validation_error,
                "remote_validation_error": remote_validation_error,
                "local_hash": local_hash,
                "remote_hash": remote_hash,
                "local_mtime": local_file.stat().st_mtime if local_file.exists() else 0,
            }
        )

        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

        for label, rc in [
            ("seed", seed_result.returncode),
            ("download", download_result.returncode),
            ("remote update", remote_result.returncode),
            ("final sync", final_result.returncode),
            ("verify", verify_result.returncode),
        ]:
            if rc != 0:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} phase failed with status {rc}",
                    artifacts,
                    details,
                )

        if baseline_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Downloaded baseline is not a valid revision-0 XLSX workbook: {baseline_validation_error}",
                artifacts,
                details,
            )

        if local_revision_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Unable to establish the local revision-2 XLSX conflict payload: {local_revision_error}",
                artifacts,
                details,
            )

        if local_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Local XLSX was not retained after conflict resolution with local_first enabled: {local_validation_error}",
                artifacts,
                details,
            )

        if remote_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote XLSX did not converge to the local source-of-truth revision: {remote_validation_error}",
                artifacts,
                details,
            )

        if not expected_hash or local_hash != expected_hash:
            return self.fail_result(
                self.case_id,
                self.name,
                "Local XLSX content was not retained after conflict resolution with local_first enabled",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
