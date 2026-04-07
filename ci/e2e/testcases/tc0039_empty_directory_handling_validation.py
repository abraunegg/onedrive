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


class TestCase0039EmptyDirectoryHandling(E2ETestCase):
    case_id = "0039"
    name = "empty directory handling"
    description = (
        "Validate creation, sync, verification, and cleanup behaviour for "
        "empty directories so that directory-only state is handled correctly "
        "without leaving stale folders behind"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0039 config\n"
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
        case_work_dir = context.work_root / "tc0039"
        case_log_dir = context.logs_dir / "tc0039"
        state_dir = context.state_dir / "tc0039"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)

        context.ensure_refresh_token_available()

        local_root = case_work_dir / "syncroot"
        verify_create_root = case_work_dir / "verify-create-root"
        verify_cleanup_root = case_work_dir / "verify-cleanup-root"

        conf_main = case_work_dir / "conf-main"
        conf_verify_create = case_work_dir / "conf-verify-create"
        conf_verify_cleanup = case_work_dir / "conf-verify-cleanup"

        reset_directory(local_root)
        reset_directory(verify_create_root)
        reset_directory(verify_cleanup_root)

        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify_create, "")
        context.prepare_minimal_config_dir(conf_verify_cleanup, "")

        self._write_config(conf_main, local_root)
        self._write_config(conf_verify_create, verify_create_root)
        self._write_config(conf_verify_cleanup, verify_cleanup_root)

        root_name = f"ZZ_E2E_TC0039_{context.run_id}_{os.getpid()}"

        anchor_relative = f"{root_name}/anchor.txt"
        empty_dir_relative = f"{root_name}/EmptyDirectory"
        nested_parent_relative = f"{root_name}/NestedParent"
        nested_empty_relative = f"{root_name}/NestedParent/ChildEmptyDirectory"

        local_anchor_path = local_root / anchor_relative
        local_empty_dir_path = local_root / empty_dir_relative
        local_nested_parent_path = local_root / nested_parent_relative
        local_nested_empty_path = local_root / nested_empty_relative

        verify_create_anchor_path = verify_create_root / anchor_relative
        verify_create_empty_dir_path = verify_create_root / empty_dir_relative
        verify_create_nested_parent_path = verify_create_root / nested_parent_relative
        verify_create_nested_empty_path = verify_create_root / nested_empty_relative

        verify_cleanup_anchor_path = verify_cleanup_root / anchor_relative
        verify_cleanup_empty_dir_path = verify_cleanup_root / empty_dir_relative
        verify_cleanup_nested_parent_path = verify_cleanup_root / nested_parent_relative
        verify_cleanup_nested_empty_path = verify_cleanup_root / nested_empty_relative

        anchor_content = (
            "TC0039 anchor file\n"
            "This file keeps the testcase root present while validating empty directory handling.\n"
        )

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_verify_creation_stdout.log"
        phase2_stderr = case_log_dir / "phase2_verify_creation_stderr.log"
        phase3_stdout = case_log_dir / "phase3_cleanup_stdout.log"
        phase3_stderr = case_log_dir / "phase3_cleanup_stderr.log"
        phase4_stdout = case_log_dir / "phase4_verify_cleanup_stdout.log"
        phase4_stderr = case_log_dir / "phase4_verify_cleanup_stderr.log"

        verify_create_manifest_file = state_dir / "verify_create_manifest.txt"
        verify_cleanup_manifest_file = state_dir / "verify_cleanup_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(phase3_stdout),
            str(phase3_stderr),
            str(phase4_stdout),
            str(phase4_stderr),
            str(verify_create_manifest_file),
            str(verify_cleanup_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "anchor_relative": anchor_relative,
            "empty_dir_relative": empty_dir_relative,
            "nested_parent_relative": nested_parent_relative,
            "nested_empty_relative": nested_empty_relative,
            "main_conf_dir": str(conf_main),
            "verify_create_conf_dir": str(conf_verify_create),
            "verify_cleanup_conf_dir": str(conf_verify_cleanup),
            "local_root": str(local_root),
            "verify_create_root": str(verify_create_root),
            "verify_cleanup_root": str(verify_cleanup_root),
        }

        # Phase 1: create anchor file and empty directories, then sync
        write_text_file(local_anchor_path, anchor_content)
        local_empty_dir_path.mkdir(parents=True, exist_ok=True)
        local_nested_empty_path.mkdir(parents=True, exist_ok=True)

        details["local_anchor_exists_before_seed"] = local_anchor_path.is_file()
        details["local_empty_dir_exists_before_seed"] = local_empty_dir_path.is_dir()
        details["local_nested_parent_exists_before_seed"] = local_nested_parent_path.is_dir()
        details["local_nested_empty_exists_before_seed"] = local_nested_empty_path.is_dir()

        expected_creation_manifest = [
            root_name,
            anchor_relative,
            empty_dir_relative,
            nested_parent_relative,
            nested_empty_relative,
        ]
        details["expected_creation_manifest"] = expected_creation_manifest

        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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

        # Phase 2: verify remote creation with a fresh client
        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify_create),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase2: {command_to_string(phase2_command)}"
        )
        phase2_result = run_command(phase2_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)
        details["phase2_returncode"] = phase2_result.returncode

        verify_create_manifest = build_manifest(verify_create_root)
        write_manifest(verify_create_manifest_file, verify_create_manifest)
        details["verify_create_manifest"] = verify_create_manifest
        details["verify_create_anchor_exists"] = verify_create_anchor_path.is_file()
        details["verify_create_empty_dir_exists"] = verify_create_empty_dir_path.is_dir()
        details["verify_create_nested_parent_exists"] = verify_create_nested_parent_path.is_dir()
        details["verify_create_nested_empty_exists"] = verify_create_nested_empty_path.is_dir()

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"creation verification failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if not verify_create_anchor_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"creation verification is missing anchor file: {anchor_relative}",
                artifacts,
                details,
            )

        if not verify_create_empty_dir_path.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"creation verification is missing empty directory: {empty_dir_relative}",
                artifacts,
                details,
            )

        if not verify_create_nested_parent_path.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"creation verification is missing nested parent directory: {nested_parent_relative}",
                artifacts,
                details,
            )

        if not verify_create_nested_empty_path.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"creation verification is missing nested empty directory: {nested_empty_relative}",
                artifacts,
                details,
            )

        if verify_create_manifest != expected_creation_manifest:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "creation verification manifest did not match expected structure",
                artifacts,
                details,
            )

        # Phase 3: remove the empty directories locally and sync cleanup
        if local_nested_empty_path.exists():
            local_nested_empty_path.rmdir()
        if local_empty_dir_path.exists():
            local_empty_dir_path.rmdir()
        if local_nested_parent_path.exists():
            local_nested_parent_path.rmdir()

        details["local_empty_dir_exists_after_cleanup_prep"] = local_empty_dir_path.exists()
        details["local_nested_parent_exists_after_cleanup_prep"] = local_nested_parent_path.exists()
        details["local_nested_empty_exists_after_cleanup_prep"] = local_nested_empty_path.exists()
        details["local_anchor_exists_after_cleanup_prep"] = local_anchor_path.is_file()

        if local_empty_dir_path.exists() or local_nested_parent_path.exists() or local_nested_empty_path.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local empty directory cleanup preparation failed before sync",
                artifacts,
                details,
            )

        if not local_anchor_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local anchor file is missing before cleanup sync",
                artifacts,
                details,
            )

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"cleanup propagation phase failed with status {phase3_result.returncode}",
                artifacts,
                details,
            )

        # Phase 4: verify remote cleanup with a fresh client
        expected_cleanup_manifest = [
            root_name,
            anchor_relative,
        ]
        details["expected_cleanup_manifest"] = expected_cleanup_manifest

        phase4_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify_cleanup),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase4: {command_to_string(phase4_command)}"
        )
        phase4_result = run_command(phase4_command, cwd=context.repo_root)
        write_text_file(phase4_stdout, phase4_result.stdout)
        write_text_file(phase4_stderr, phase4_result.stderr)
        details["phase4_returncode"] = phase4_result.returncode

        verify_cleanup_manifest = build_manifest(verify_cleanup_root)
        write_manifest(verify_cleanup_manifest_file, verify_cleanup_manifest)
        details["verify_cleanup_manifest"] = verify_cleanup_manifest
        details["verify_cleanup_anchor_exists"] = verify_cleanup_anchor_path.is_file()
        details["verify_cleanup_empty_dir_exists"] = verify_cleanup_empty_dir_path.exists()
        details["verify_cleanup_nested_parent_exists"] = verify_cleanup_nested_parent_path.exists()
        details["verify_cleanup_nested_empty_exists"] = verify_cleanup_nested_empty_path.exists()

        self._write_metadata(metadata_file, details)

        if phase4_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"cleanup verification failed with status {phase4_result.returncode}",
                artifacts,
                details,
            )

        if not verify_cleanup_anchor_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"cleanup verification is missing anchor file: {anchor_relative}",
                artifacts,
                details,
            )

        if verify_cleanup_empty_dir_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"cleanup verification still contains removed empty directory: {empty_dir_relative}",
                artifacts,
                details,
            )

        if verify_cleanup_nested_parent_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"cleanup verification still contains removed nested parent directory: {nested_parent_relative}",
                artifacts,
                details,
            )

        if verify_cleanup_nested_empty_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"cleanup verification still contains removed nested empty directory: {nested_empty_relative}",
                artifacts,
                details,
            )

        if verify_cleanup_manifest != expected_cleanup_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "cleanup verification manifest did not match expected final structure",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)