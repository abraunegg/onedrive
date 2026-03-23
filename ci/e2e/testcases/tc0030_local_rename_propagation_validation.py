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


class TestCase0030LocalRenamePropagationValidation(E2ETestCase):
    case_id = "0030"
    name = "local rename propagation validation"
    description = "Validate that renaming a local file is correctly propagated to remote state"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(
            config_path,
            (
                "# tc0030 config\n"
                'bypass_data_preservation = "true"\n'
            ),
        )

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0030"
        case_log_dir = context.logs_dir / "tc0030"
        state_dir = context.state_dir / "tc0030"

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

        root_name = f"ZZ_E2E_TC0030_{context.run_id}_{os.getpid()}"
        old_relative = f"{root_name}/original-name.txt"
        new_relative = f"{root_name}/renamed-file.txt"

        old_local_path = local_root / old_relative
        new_local_path = local_root / new_relative

        initial_content = (
            "TC0030 local rename propagation validation\n"
            "This content must survive the rename operation unchanged.\n"
        )

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_rename_stdout.log"
        phase2_stderr = case_log_dir / "phase2_rename_stderr.log"
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
            "old_relative": old_relative,
            "new_relative": new_relative,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
        }

        write_text_file(old_local_path, initial_content)

        phase1_command = [
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

        if not old_local_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "initial local file is missing after seed phase",
                artifacts,
                details,
            )

        old_local_path.rename(new_local_path)

        if old_local_path.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local old filename still exists immediately after rename",
                artifacts,
                details,
            )

        if not new_local_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local renamed file does not exist immediately after rename",
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
                f"rename propagation phase failed with status {phase2_result.returncode}",
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

        verified_old_path = verify_root / old_relative
        verified_new_path = verify_root / new_relative

        details["verified_old_exists"] = verified_old_path.exists()
        details["verified_new_exists"] = verified_new_path.exists()

        verified_content = ""
        if verified_new_path.is_file():
            verified_content = verified_new_path.read_text(encoding="utf-8")
        details["verified_content"] = verified_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if verified_old_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification still contains old filename: {old_relative}",
                artifacts,
                details,
            )

        if not verified_new_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing renamed file: {new_relative}",
                artifacts,
                details,
            )

        if verified_content != initial_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "renamed file content did not match the original content after remote verification",
                artifacts,
                details,
            )

        return TestResult.pass_result(
            self.case_id,
            self.name,
            artifacts,
            details,
        )