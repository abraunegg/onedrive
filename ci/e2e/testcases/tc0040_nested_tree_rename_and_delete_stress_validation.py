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


class TestCase0040NestedTreeRenameAndDeleteStressValidation(E2ETestCase):
    case_id = "0040"
    name = "nested tree rename and delete stress validation"
    description = (
        "Validate a combined nested-tree mutation scenario involving multiple renames, "
        "one deletion, and one new file creation before a single sync, ensuring the "
        "final remote and fresh-download state is correct with no stale paths left behind"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0040 config\n"
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
        case_work_dir = context.work_root / "tc0040"
        case_log_dir = context.logs_dir / "tc0040"
        state_dir = context.state_dir / "tc0040"

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

        root_name = f"ZZ_E2E_TC0040_{context.run_id}_{os.getpid()}"

        anchor_relative = f"{root_name}/anchor.txt"

        original_parent_dir_relative = f"{root_name}/TreeAlpha"
        original_nested_dir_relative = f"{root_name}/TreeAlpha/Level1A"
        original_file_alpha_relative = f"{root_name}/TreeAlpha/Level1A/Level2A/file-alpha.txt"
        original_file_beta_relative = f"{root_name}/TreeAlpha/Level1A/Level2B/file-beta.txt"
        original_file_gamma_relative = f"{root_name}/TreeAlpha/Level1B/file-gamma.txt"

        renamed_parent_dir_relative = f"{root_name}/TreeOmega"
        renamed_nested_dir_relative = f"{root_name}/TreeOmega/Level1A_Renamed"
        renamed_file_alpha_relative = f"{root_name}/TreeOmega/Level1A_Renamed/Level2A/file-alpha.txt"
        deleted_file_beta_relative = f"{root_name}/TreeOmega/Level1A_Renamed/Level2B/file-beta.txt"
        renamed_file_gamma_relative = f"{root_name}/TreeOmega/Level1B/file-gamma-renamed.txt"
        new_file_delta_relative = f"{root_name}/TreeOmega/Level1A_Renamed/Level2B/new-delta.txt"

        local_anchor_path = local_root / anchor_relative
        local_original_parent_dir_path = local_root / original_parent_dir_relative
        local_original_nested_dir_path = local_root / original_nested_dir_relative
        local_original_file_alpha_path = local_root / original_file_alpha_relative
        local_original_file_beta_path = local_root / original_file_beta_relative
        local_original_file_gamma_path = local_root / original_file_gamma_relative

        local_renamed_parent_dir_path = local_root / renamed_parent_dir_relative
        local_renamed_nested_dir_path = local_root / renamed_nested_dir_relative
        local_renamed_file_alpha_path = local_root / renamed_file_alpha_relative
        local_deleted_file_beta_path = local_root / deleted_file_beta_relative
        local_renamed_file_gamma_path = local_root / renamed_file_gamma_relative
        local_new_file_delta_path = local_root / new_file_delta_relative

        verify_anchor_path = verify_root / anchor_relative
        verify_original_parent_dir_path = verify_root / original_parent_dir_relative
        verify_original_nested_dir_path = verify_root / original_nested_dir_relative
        verify_original_file_alpha_path = verify_root / original_file_alpha_relative
        verify_original_file_beta_path = verify_root / original_file_beta_relative
        verify_original_file_gamma_path = verify_root / original_file_gamma_relative

        verify_renamed_parent_dir_path = verify_root / renamed_parent_dir_relative
        verify_renamed_nested_dir_path = verify_root / renamed_nested_dir_relative
        verify_renamed_file_alpha_path = verify_root / renamed_file_alpha_relative
        verify_deleted_file_beta_path = verify_root / deleted_file_beta_relative
        verify_renamed_file_gamma_path = verify_root / renamed_file_gamma_relative
        verify_new_file_delta_path = verify_root / new_file_delta_relative

        anchor_content = (
            "TC0040 anchor file\n"
            "This file keeps the testcase root stable while nested tree mutations occur.\n"
        )
        file_alpha_content = (
            "TC0040 nested tree rename and delete stress validation\n"
            "FILE ALPHA\n"
            "This file should survive parent and nested directory renames unchanged.\n"
        )
        file_beta_content = (
            "TC0040 nested tree rename and delete stress validation\n"
            "FILE BETA\n"
            "This file should be deleted before the second sync.\n"
        )
        file_gamma_content = (
            "TC0040 nested tree rename and delete stress validation\n"
            "FILE GAMMA\n"
            "This file should be renamed before the second sync.\n"
        )
        new_file_delta_content = (
            "TC0040 nested tree rename and delete stress validation\n"
            "FILE DELTA\n"
            "This file is newly created inside the renamed nested directory before the second sync.\n"
        )

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_mutation_stdout.log"
        phase2_stderr = case_log_dir / "phase2_mutation_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"

        local_manifest_before_phase2_file = state_dir / "local_manifest_before_phase2.txt"
        local_manifest_after_mutation_file = state_dir / "local_manifest_after_mutation.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_manifest_before_phase2_file),
            str(local_manifest_after_mutation_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "anchor_relative": anchor_relative,
            "original_parent_dir_relative": original_parent_dir_relative,
            "original_nested_dir_relative": original_nested_dir_relative,
            "original_file_alpha_relative": original_file_alpha_relative,
            "original_file_beta_relative": original_file_beta_relative,
            "original_file_gamma_relative": original_file_gamma_relative,
            "renamed_parent_dir_relative": renamed_parent_dir_relative,
            "renamed_nested_dir_relative": renamed_nested_dir_relative,
            "renamed_file_alpha_relative": renamed_file_alpha_relative,
            "deleted_file_beta_relative": deleted_file_beta_relative,
            "renamed_file_gamma_relative": renamed_file_gamma_relative,
            "new_file_delta_relative": new_file_delta_relative,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
        }

        # Phase 1: seed the original nested tree
        write_text_file(local_anchor_path, anchor_content)
        write_text_file(local_original_file_alpha_path, file_alpha_content)
        write_text_file(local_original_file_beta_path, file_beta_content)
        write_text_file(local_original_file_gamma_path, file_gamma_content)

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
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {phase1_result.returncode}",
                artifacts,
                details,
            )

        local_manifest_before_phase2 = build_manifest(local_root)
        write_manifest(local_manifest_before_phase2_file, local_manifest_before_phase2)

        # Phase 2 preparation: perform all local mutations before a single sync
        local_original_parent_dir_path.rename(local_renamed_parent_dir_path)
        local_renamed_parent_dir_path.joinpath("Level1A").rename(local_renamed_nested_dir_path)
        local_renamed_parent_dir_path.joinpath("Level1B", "file-gamma.txt").rename(local_renamed_file_gamma_path)

        if local_deleted_file_beta_path.exists():
            local_deleted_file_beta_path.unlink()

        write_text_file(local_new_file_delta_path, new_file_delta_content)

        local_manifest_after_mutation = build_manifest(local_root)
        write_manifest(local_manifest_after_mutation_file, local_manifest_after_mutation)

        details["local_original_parent_dir_exists_after_mutation"] = local_original_parent_dir_path.exists()
        details["local_original_nested_dir_exists_after_mutation"] = local_original_nested_dir_path.exists()
        details["local_original_file_alpha_exists_after_mutation"] = local_original_file_alpha_path.exists()
        details["local_original_file_beta_exists_after_mutation"] = local_original_file_beta_path.exists()
        details["local_original_file_gamma_exists_after_mutation"] = local_original_file_gamma_path.exists()

        details["local_renamed_parent_dir_exists_after_mutation"] = local_renamed_parent_dir_path.is_dir()
        details["local_renamed_nested_dir_exists_after_mutation"] = local_renamed_nested_dir_path.is_dir()
        details["local_renamed_file_alpha_exists_after_mutation"] = local_renamed_file_alpha_path.is_file()
        details["local_deleted_file_beta_exists_after_mutation"] = local_deleted_file_beta_path.exists()
        details["local_renamed_file_gamma_exists_after_mutation"] = local_renamed_file_gamma_path.is_file()
        details["local_new_file_delta_exists_after_mutation"] = local_new_file_delta_path.is_file()

        if local_original_parent_dir_path.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local original parent directory still exists immediately after mutation",
                artifacts,
                details,
            )

        if local_original_nested_dir_path.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local original nested directory still exists immediately after mutation",
                artifacts,
                details,
            )

        if local_original_file_gamma_path.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local original gamma filename still exists immediately after mutation",
                artifacts,
                details,
            )

        if local_deleted_file_beta_path.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local beta file still exists immediately after delete mutation",
                artifacts,
                details,
            )

        if not local_renamed_parent_dir_path.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local renamed parent directory is missing immediately after mutation",
                artifacts,
                details,
            )

        if not local_renamed_nested_dir_path.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local renamed nested directory is missing immediately after mutation",
                artifacts,
                details,
            )

        if not local_renamed_file_alpha_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local alpha file is missing after parent and nested directory renames",
                artifacts,
                details,
            )

        if not local_renamed_file_gamma_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local renamed gamma file is missing immediately after mutation",
                artifacts,
                details,
            )

        if not local_new_file_delta_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local new delta file is missing immediately after mutation",
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
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"mutation propagation phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: verify the final remote truth from a fresh client
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

        details["verify_anchor_exists"] = verify_anchor_path.is_file()

        details["verify_original_parent_dir_exists"] = verify_original_parent_dir_path.exists()
        details["verify_original_nested_dir_exists"] = verify_original_nested_dir_path.exists()
        details["verify_original_file_alpha_exists"] = verify_original_file_alpha_path.exists()
        details["verify_original_file_beta_exists"] = verify_original_file_beta_path.exists()
        details["verify_original_file_gamma_exists"] = verify_original_file_gamma_path.exists()

        details["verify_renamed_parent_dir_exists"] = verify_renamed_parent_dir_path.is_dir()
        details["verify_renamed_nested_dir_exists"] = verify_renamed_nested_dir_path.is_dir()
        details["verify_renamed_file_alpha_exists"] = verify_renamed_file_alpha_path.is_file()
        details["verify_deleted_file_beta_exists"] = verify_deleted_file_beta_path.exists()
        details["verify_renamed_file_gamma_exists"] = verify_renamed_file_gamma_path.is_file()
        details["verify_new_file_delta_exists"] = verify_new_file_delta_path.is_file()

        verify_renamed_file_alpha_content = (
            verify_renamed_file_alpha_path.read_text(encoding="utf-8")
            if verify_renamed_file_alpha_path.is_file()
            else ""
        )
        verify_renamed_file_gamma_content = (
            verify_renamed_file_gamma_path.read_text(encoding="utf-8")
            if verify_renamed_file_gamma_path.is_file()
            else ""
        )
        verify_new_file_delta_content = (
            verify_new_file_delta_path.read_text(encoding="utf-8")
            if verify_new_file_delta_path.is_file()
            else ""
        )

        details["verify_renamed_file_alpha_content"] = verify_renamed_file_alpha_content
        details["verify_renamed_file_gamma_content"] = verify_renamed_file_gamma_content
        details["verify_new_file_delta_content"] = verify_new_file_delta_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if not verify_anchor_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification is missing anchor file: {anchor_relative}",
                artifacts,
                details,
            )

        if verify_original_parent_dir_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification still contains original parent directory: {original_parent_dir_relative}",
                artifacts,
                details,
            )

        if verify_original_nested_dir_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification still contains original nested directory: {original_nested_dir_relative}",
                artifacts,
                details,
            )

        if verify_original_file_alpha_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification still contains original alpha path: {original_file_alpha_relative}",
                artifacts,
                details,
            )

        if verify_original_file_beta_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification still contains deleted beta path: {original_file_beta_relative}",
                artifacts,
                details,
            )

        if verify_original_file_gamma_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification still contains original gamma path: {original_file_gamma_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_parent_dir_path.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification is missing renamed parent directory: {renamed_parent_dir_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_nested_dir_path.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification is missing renamed nested directory: {renamed_nested_dir_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_file_alpha_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification is missing alpha file at renamed path: {renamed_file_alpha_relative}",
                artifacts,
                details,
            )

        if verify_deleted_file_beta_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification still contains deleted beta file: {deleted_file_beta_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_file_gamma_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification is missing renamed gamma file: {renamed_file_gamma_relative}",
                artifacts,
                details,
            )

        if not verify_new_file_delta_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verification is missing new delta file: {new_file_delta_relative}",
                artifacts,
                details,
            )

        if verify_renamed_file_alpha_content != file_alpha_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "alpha file content did not survive nested directory renames unchanged",
                artifacts,
                details,
            )

        if verify_renamed_file_gamma_content != file_gamma_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "renamed gamma file content did not match the original content",
                artifacts,
                details,
            )

        if verify_new_file_delta_content != new_file_delta_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "new delta file content did not match the created content",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)