from __future__ import annotations

import os
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


class TestCase0034LocalMoveBetweenDirectoriesValidation(E2ETestCase):
    case_id = "0034"
    name = "local move between directories validation"
    description = (
        "Validate that moving a local file from one directory to another "
        "is correctly propagated to remote state"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0034 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

        write_onedrive_config(config_path, config_text)
        write_onedrive_config(backup_path, config_text)
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(config_path, 0o600)
        os.chmod(backup_path, 0o600)
        os.chmod(hash_path, 0o600)

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0034"
        case_log_dir = context.logs_dir / "tc0034"
        state_dir = context.state_dir / "tc0034"

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

        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify, "")

        self._write_config(conf_main, local_root)
        self._write_config(conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0034_{context.run_id}_{os.getpid()}"
        source_relative = f"{root_name}/SourceDirectory/move-me.txt"
        destination_relative = f"{root_name}/DestinationDirectory/move-me.txt"
        anchor_relative = f"{root_name}/DestinationDirectory/anchor.txt"

        local_source_path = local_root / source_relative
        local_destination_path = local_root / destination_relative
        local_anchor_path = local_root / anchor_relative

        verify_source_path = verify_root / source_relative
        verify_destination_path = verify_root / destination_relative
        verify_anchor_path = verify_root / anchor_relative

        initial_content = (
            "TC0034 local move between directories validation\n"
            "This content must survive the directory move unchanged.\n"
        )
        anchor_content = (
            "TC0034 destination directory anchor\n"
            "This ensures the destination directory exists before the move.\n"
        )

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_move_stdout.log"
        phase2_stderr = case_log_dir / "phase2_move_stderr.log"
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
            "source_relative": source_relative,
            "destination_relative": destination_relative,
            "anchor_relative": anchor_relative,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
        }

        # Phase 1: seed original state with source file and destination anchor
        write_text_file(local_source_path, initial_content)
        write_text_file(local_anchor_path, anchor_content)

        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
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

        # Phase 2: move the file locally between directories without renaming it
        local_destination_path.parent.mkdir(parents=True, exist_ok=True)
        local_source_path.rename(local_destination_path)

        details["local_source_exists_after_move"] = local_source_path.exists()
        details["local_destination_exists_after_move"] = local_destination_path.is_file()
        details["local_anchor_exists_after_move"] = local_anchor_path.is_file()

        if local_source_path.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local source file still exists immediately after move",
                artifacts,
                details,
            )

        if not local_destination_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local destination file does not exist immediately after move",
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
                f"move propagation phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: verify remote truth from a fresh client
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

        details["verify_source_exists"] = verify_source_path.exists()
        details["verify_destination_exists"] = verify_destination_path.is_file()
        details["verify_anchor_exists"] = verify_anchor_path.is_file()

        verify_destination_content = (
            verify_destination_path.read_text(encoding="utf-8")
            if verify_destination_path.is_file()
            else ""
        )
        details["verify_destination_content"] = verify_destination_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if verify_source_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification still contains source file path: {source_relative}",
                artifacts,
                details,
            )

        if not verify_destination_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing moved file at destination path: {destination_relative}",
                artifacts,
                details,
            )

        if verify_destination_content != initial_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "moved file content did not match the original content after remote verification",
                artifacts,
                details,
            )

        if not verify_anchor_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing destination anchor file: {anchor_relative}",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)