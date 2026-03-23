from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)


class TestCase0031LocalDirectoryRenamePropagationValidation(E2ETestCase):
    case_id = "0031"
    name = "local directory rename propagation validation"
    description = "Validate that renaming a local directory tree is correctly propagated to remote state"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(
            config_path,
            (
                "# tc0031 config\n"
                'bypass_data_preservation = "true"\n'
            ),
        )

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0031"
        case_log_dir = context.logs_dir / "tc0031"
        state_dir = context.state_dir / "tc0031"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        local_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(local_root)
        reset_directory(verify_root)

        context.bootstrap_config_dir(conf_main)
        context.bootstrap_config_dir(conf_verify)

        self._write_config(conf_main / "config")
        self._write_config(conf_verify / "config")

        root_name = f"ZZ_E2E_TC0031_{context.run_id}_{os.getpid()}"
        source_dir_relative = f"{root_name}/SourceDirectory"
        renamed_dir_relative = f"{root_name}/RenamedDirectory"

        source_dir = local_root / source_dir_relative
        renamed_dir = local_root / renamed_dir_relative

        source_file_1_relative = f"{source_dir_relative}/top-level.txt"
        source_file_2_relative = f"{source_dir_relative}/Nested/child.txt"

        renamed_file_1_relative = f"{renamed_dir_relative}/top-level.txt"
        renamed_file_2_relative = f"{renamed_dir_relative}/Nested/child.txt"

        source_file_1 = local_root / source_file_1_relative
        source_file_2 = local_root / source_file_2_relative

        file1_content = "TC0031 top level file\n"
        file2_content = "TC0031 nested child file\n"

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_directory_rename_stdout.log"
        phase2_stderr = case_log_dir / "phase2_directory_rename_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "source_dir_relative": source_dir_relative,
            "renamed_dir_relative": renamed_dir_relative,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
        }

        write_text_file(source_file_1, file1_content)
        write_text_file(source_file_2, file2_content)

        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(local_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} phase1: {command_to_string(phase1_command)}")
        phase1_result = run_command(phase1_command, cwd=context.repo_root)
        write_text_file(phase1_stdout, phase1_result.stdout)
        write_text_file(phase1_stderr, phase1_result.stderr)
        details["phase1_returncode"] = phase1_result.returncode

        if phase1_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {phase1_result.returncode}",
                artifacts,
                details,
            )

        if not source_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "initial local source directory is missing after seed phase",
                artifacts,
                details,
            )

        source_dir.rename(renamed_dir)

        if source_dir.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local original directory still exists immediately after rename",
                artifacts,
                details,
            )

        if not renamed_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local renamed directory does not exist immediately after rename",
                artifacts,
                details,
            )

        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(local_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2: {command_to_string(phase2_command)}")
        phase2_result = run_command(phase2_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)
        details["phase2_returncode"] = phase2_result.returncode

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"directory rename propagation phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(conf_verify),
        ]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)

        verify_old_dir = verify_root / source_dir_relative
        verify_new_dir = verify_root / renamed_dir_relative
        verify_old_file_1 = verify_root / source_file_1_relative
        verify_old_file_2 = verify_root / source_file_2_relative
        verify_new_file_1 = verify_root / renamed_file_1_relative
        verify_new_file_2 = verify_root / renamed_file_2_relative

        details["verify_old_dir_exists"] = verify_old_dir.exists()
        details["verify_new_dir_exists"] = verify_new_dir.exists()
        details["verify_old_file_1_exists"] = verify_old_file_1.exists()
        details["verify_old_file_2_exists"] = verify_old_file_2.exists()
        details["verify_new_file_1_exists"] = verify_new_file_1.exists()
        details["verify_new_file_2_exists"] = verify_new_file_2.exists()

        verify_new_file_1_content = ""
        verify_new_file_2_content = ""
        if verify_new_file_1.is_file():
            verify_new_file_1_content = verify_new_file_1.read_text(encoding="utf-8")
        if verify_new_file_2.is_file():
            verify_new_file_2_content = verify_new_file_2.read_text(encoding="utf-8")

        details["verify_new_file_1_content"] = verify_new_file_1_content
        details["verify_new_file_2_content"] = verify_new_file_2_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if verify_old_dir.exists() or verify_old_file_1.exists() or verify_old_file_2.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification still contains original directory tree: {source_dir_relative}",
                artifacts,
                details,
            )

        if not verify_new_dir.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing renamed directory: {renamed_dir_relative}",
                artifacts,
                details,
            )

        if not verify_new_file_1.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing renamed top-level file: {renamed_file_1_relative}",
                artifacts,
                details,
            )

        if not verify_new_file_2.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing renamed nested file: {renamed_file_2_relative}",
                artifacts,
                details,
            )

        if verify_new_file_1_content != file1_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "renamed top-level file content did not match expected content",
                artifacts,
                details,
            )

        if verify_new_file_2_content != file2_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "renamed nested file content did not match expected content",
                artifacts,
                details,
            )

        return TestResult.pass_result(
            self.case_id,
            self.name,
            artifacts,
            details,
        )