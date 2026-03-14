from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0018RecycleBinValidation(E2ETestCase):
    case_id = "0018"
    name = "recycle bin validation"
    description = "Validate that online deletions are moved into a FreeDesktop-compliant recycle bin when enabled"

    def _write_runtime_base_config(self, config_path: Path, sync_dir: Path) -> None:
        write_text_file(
            config_path,
            "# tc0018 runtime base config\n"
            f'sync_dir = "{sync_dir}"\n',
        )

    def _write_runtime_cleanup_config(self, config_path: Path, sync_dir: Path, recycle_bin_path: Path) -> None:
        write_text_file(
            config_path,
            "# tc0018 runtime cleanup config\n"
            f'sync_dir = "{sync_dir}"\n'
            'cleanup_local_files = "true"\n'
            'download_only = "true"\n'
            'use_recycle_bin = "true"\n'
            f'recycle_bin_path = "{recycle_bin_path}"\n',
        )

    def _write_verify_config(self, config_path: Path, sync_dir: Path) -> None:
        write_text_file(
            config_path,
            "# tc0018 verify config\n"
            f'sync_dir = "{sync_dir}"\n',
        )

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0018"
        case_log_dir = context.logs_dir / "tc0018"
        state_dir = context.state_dir / "tc0018"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        recycle_bin_root = case_work_dir / "RecycleBin"

        conf_runtime = case_work_dir / "conf-runtime"
        conf_verify = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0018_{context.run_id}_{os.getpid()}"

        reset_directory(sync_root)
        reset_directory(verify_root)
        reset_directory(recycle_bin_root)

        # Create initial local content to seed remotely
        write_text_file(sync_root / root_name / "Keep" / "keep.txt", "keep\n")
        write_text_file(sync_root / root_name / "OldData" / "old.txt", "old\n")

        # Shared runtime config for seed -> remove -> cleanup
        context.bootstrap_config_dir(conf_runtime)
        self._write_runtime_base_config(conf_runtime / "config", sync_root)

        # Fresh verify config for clean remote validation
        context.bootstrap_config_dir(conf_verify)
        self._write_verify_config(conf_verify / "config", verify_root)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        remove_stdout = case_log_dir / "remove_stdout.log"
        remove_stderr = case_log_dir / "remove_stderr.log"
        cleanup_stdout = case_log_dir / "cleanup_stdout.log"
        cleanup_stderr = case_log_dir / "cleanup_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"

        recycle_manifest_file = state_dir / "recycle_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        local_manifest_file = state_dir / "local_manifest_after_cleanup.txt"
        metadata_file = state_dir / "metadata.txt"

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_runtime),
        ]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)

        remove_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--verbose",
            "--verbose",
            "--remove-directory",
            f"{root_name}/OldData",
            "--confdir",
            str(conf_runtime),
        ]
        context.log(f"Executing Test Case {self.case_id} remove: {command_to_string(remove_command)}")
        remove_result = run_command(remove_command, cwd=context.repo_root)
        write_text_file(remove_stdout, remove_result.stdout)
        write_text_file(remove_stderr, remove_result.stderr)

        # Rewrite the same runtime config so cleanup reuses the same DB / delta state
        self._write_runtime_cleanup_config(conf_runtime / "config", sync_root, recycle_bin_root)

        cleanup_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--cleanup-local-files",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_runtime),
        ]
        context.log(f"Executing Test Case {self.case_id} cleanup: {command_to_string(cleanup_command)}")
        cleanup_result = run_command(cleanup_command, cwd=context.repo_root)
        write_text_file(cleanup_stdout, cleanup_result.stdout)
        write_text_file(cleanup_stderr, cleanup_result.stderr)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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

        recycle_manifest = build_manifest(recycle_bin_root)
        remote_manifest = build_manifest(verify_root)
        local_manifest = build_manifest(sync_root)

        write_manifest(recycle_manifest_file, recycle_manifest)
        write_manifest(remote_manifest_file, remote_manifest)
        write_manifest(local_manifest_file, local_manifest)

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"sync_root={sync_root}",
                    f"verify_root={verify_root}",
                    f"recycle_bin_root={recycle_bin_root}",
                    f"runtime_confdir={conf_runtime}",
                    f"verify_confdir={conf_verify}",
                    f"seed_returncode={seed_result.returncode}",
                    f"remove_returncode={remove_result.returncode}",
                    f"cleanup_returncode={cleanup_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(remove_stdout),
            str(remove_stderr),
            str(cleanup_stdout),
            str(cleanup_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(recycle_manifest_file),
            str(remote_manifest_file),
            str(local_manifest_file),
            str(metadata_file),
        ]
        details = {
            "seed_returncode": seed_result.returncode,
            "remove_returncode": remove_result.returncode,
            "cleanup_returncode": cleanup_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        if seed_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Remote seed failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        if remove_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Online directory removal failed with status {remove_result.returncode}",
                artifacts,
                details,
            )

        if cleanup_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Recycle bin cleanup sync failed with status {cleanup_result.returncode}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if (sync_root / root_name / "OldData").exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "OldData still exists locally after online deletion cleanup",
                artifacts,
                details,
            )

        if not (sync_root / root_name / "Keep" / "keep.txt").is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Keep file is missing locally after recycle bin processing",
                artifacts,
                details,
            )

        recycle_has_file = any(path.endswith("old.txt") for path in recycle_manifest)
        recycle_has_info = any(path.endswith(".trashinfo") for path in recycle_manifest)

        if not recycle_has_file:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Deleted content was not moved into the configured recycle bin",
                artifacts,
                details,
            )

        if not recycle_has_info:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Recycle bin metadata .trashinfo file was not created",
                artifacts,
                details,
            )

        if f"{root_name}/Keep/keep.txt" not in remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Keep file is missing online after recycle bin processing",
                artifacts,
                details,
            )

        if any(entry == f"{root_name}/OldData" or entry.startswith(f"{root_name}/OldData/") for entry in remote_manifest):
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "OldData still exists online after explicit online removal",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)