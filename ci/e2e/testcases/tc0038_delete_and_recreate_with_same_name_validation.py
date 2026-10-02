from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx_pair, validate_xlsx_pair, unlink_xlsx_pair, large_xlsx_relative, xlsx_pair_any_exists, xlsx_pair_all_files
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)


class TestCase0038DeleteAndRecreateWithSameNameValidation(E2ETestCase):
    case_id = "0038"
    name = "delete and recreate with same name validation"
    description = (
        "Validate that deleting passive TXT and real XLSX files, syncing those deletions, then "
        "recreating different files with the same names correctly results in the final remote "
        "and local state without stale item-id or state database issues"
    )

    XLSX_PAYLOAD_ROWS = 32

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0038 config\n"
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
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0038",
            ensure_refresh_token=False,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

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

        root_name = f"ZZ_E2E_TC0038_{context.run_id}_{os.getpid()}"
        target_relative = f"{root_name}/same-name-target.txt"
        xlsx_relative = f"{root_name}/same-name-target.xlsx"
        anchor_relative = f"{root_name}/anchor.txt"

        local_target_path = local_root / target_relative
        local_xlsx_path = local_root / xlsx_relative
        local_anchor_path = local_root / anchor_relative

        verify_target_path = verify_root / target_relative
        verify_xlsx_path = verify_root / xlsx_relative
        verify_anchor_path = verify_root / anchor_relative

        initial_content = (
            "TC0038 delete and recreate with same name validation\n"
            "INITIAL VERSION\n"
            "This file must be deleted and removed from remote state.\n"
        )
        recreated_content = (
            "TC0038 delete and recreate with same name validation\n"
            "RECREATED VERSION\n"
            "This is a different file with the same name and must be the final state.\n"
        )
        anchor_content = (
            "TC0038 anchor file\n"
            "This file keeps the directory present throughout the delete/recreate cycle.\n"
        )
        initial_xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0038:initial:{os.getpid()}"
        recreated_xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0038:recreated:{os.getpid()}"

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_delete_stdout.log"
        phase2_stderr = case_log_dir / "phase2_delete_stderr.log"
        phase3_stdout = case_log_dir / "phase3_recreate_stdout.log"
        phase3_stderr = case_log_dir / "phase3_recreate_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(phase3_stdout),
            str(phase3_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "target_relative": target_relative,
            "xlsx_relative": xlsx_relative,
            "anchor_relative": anchor_relative,
            "initial_xlsx_seed": initial_xlsx_seed,
            "recreated_xlsx_seed": recreated_xlsx_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
        }

        # Phase 1: seed initial remote state with passive TXT + real XLSX targets and anchor file
        write_text_file(local_target_path, initial_content)
        initial_xlsx = create_random_xlsx_pair(
            local_xlsx_path,
            initial_xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0038 initial delete/recreate workbook",
        )
        details["initial_xlsx_generated_size"] = int(initial_xlsx["size_bytes"])
        details["initial_xlsx_validation_error"] = validate_xlsx_pair(local_xlsx_path, REVISION_0)
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
        context.log(
            f"Executing Test Case {self.case_id} phase1: {command_to_string(phase1_command)}"
        )
        phase1_result = run_command(phase1_command, cwd=context.repo_root)
        write_text_file(phase1_stdout, phase1_result.stdout)
        write_text_file(phase1_stderr, phase1_result.stderr)
        details["phase1_returncode"] = phase1_result.returncode

        if phase1_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {phase1_result.returncode}",
                artifacts,
                details,
            )

        # Phase 2: delete both target files and sync the deletions
        if local_target_path.exists():
            local_target_path.unlink()
        if xlsx_pair_any_exists(local_xlsx_path):
            unlink_xlsx_pair(local_xlsx_path)

        details["local_target_exists_after_delete"] = local_target_path.exists()
        details["local_xlsx_exists_after_delete"] = xlsx_pair_any_exists(local_xlsx_path)
        details["local_anchor_exists_after_delete"] = local_anchor_path.is_file()

        if local_target_path.exists():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "local passive TXT target still exists immediately after delete",
                artifacts,
                details,
            )

        if local_xlsx_path.exists():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "local XLSX target still exists immediately after delete",
                artifacts,
                details,
            )

        if not local_anchor_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "local anchor file is missing immediately after delete phase preparation",
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
        context.log(
            f"Executing Test Case {self.case_id} phase2: {command_to_string(phase2_command)}"
        )
        phase2_result = run_command(phase2_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)
        details["phase2_returncode"] = phase2_result.returncode

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"delete propagation phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: recreate different files with the same names and sync again
        write_text_file(local_target_path, recreated_content)
        recreated_xlsx = create_random_xlsx_pair(
            local_xlsx_path,
            recreated_xlsx_seed,
            revision=REVISION_1,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0038 recreated delete/recreate workbook",
        )
        details["recreated_xlsx_generated_size"] = int(recreated_xlsx["size_bytes"])
        details["recreated_xlsx_validation_error"] = validate_xlsx_pair(local_xlsx_path, REVISION_1)

        details["local_target_exists_after_recreate"] = local_target_path.is_file()
        details["local_xlsx_exists_after_recreate"] = xlsx_pair_all_files(local_xlsx_path)
        details["local_target_size_after_recreate"] = (
            local_target_path.stat().st_size if local_target_path.is_file() else -1
        )
        details["local_anchor_exists_after_recreate"] = local_anchor_path.is_file()

        if not local_target_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "local passive TXT target does not exist immediately after recreate",
                artifacts,
                details,
            )
        if not xlsx_pair_all_files(local_xlsx_path):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "local XLSX target does not exist immediately after recreate",
                artifacts,
                details,
            )

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase3: {command_to_string(phase3_command)}"
        )
        phase3_result = run_command(phase3_command, cwd=context.repo_root)
        write_text_file(phase3_stdout, phase3_result.stdout)
        write_text_file(phase3_stderr, phase3_result.stderr)
        details["phase3_returncode"] = phase3_result.returncode

        if phase3_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"recreate propagation phase failed with status {phase3_result.returncode}",
                artifacts,
                details,
            )

        # Phase 4: verify remote truth from a fresh client
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
        context.log(
            f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}"
        )
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)

        details["verify_manifest"] = verify_manifest
        details["verified_target_exists"] = verify_target_path.is_file()
        details["verified_xlsx_exists"] = xlsx_pair_all_files(verify_xlsx_path)
        details["verified_anchor_exists"] = verify_anchor_path.is_file()

        verified_target_content = (
            verify_target_path.read_text(encoding="utf-8")
            if verify_target_path.is_file()
            else ""
        )
        details["verified_target_content"] = verified_target_content
        verified_xlsx_validation_error = validate_xlsx_pair(verify_xlsx_path, REVISION_1)
        details["verified_xlsx_validation_error"] = verified_xlsx_validation_error

        expected_manifest = sorted([
            root_name,
            anchor_relative,
            target_relative,
            xlsx_relative,
            large_xlsx_relative(xlsx_relative),
        ])
        details["expected_manifest"] = expected_manifest

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if not verify_anchor_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing anchor file: {anchor_relative}",
                artifacts,
                details,
            )

        if not verify_target_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing recreated file: {target_relative}",
                artifacts,
                details,
            )

        if not xlsx_pair_all_files(verify_xlsx_path):
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing recreated XLSX file: {xlsx_relative}",
                artifacts,
                details,
            )

        if verified_target_content != recreated_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "verified file content did not match the recreated content after delete/recreate cycle",
                artifacts,
                details,
            )

        if verified_xlsx_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"verified XLSX file is invalid or does not contain recreated revision {REVISION_1}: {verified_xlsx_validation_error}",
                artifacts,
                details,
            )

        if verified_target_content == initial_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "verified file content still matches the initial content after delete/recreate cycle",
                artifacts,
                details,
            )

        if verify_manifest != expected_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                "remote verification manifest did not match the expected final structure after delete/recreate cycle",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)