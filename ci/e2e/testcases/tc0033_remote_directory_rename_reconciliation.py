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


class TestCase0033RemoteDirectoryRenameReconciliation(E2ETestCase):
    case_id = "0033"
    name = "remote directory rename reconciliation"
    description = (
        "Validate that a second client with existing local and database state correctly "
        "reconciles a remote directory rename propagated by another synchronising client"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0033 config\n"
            f'sync_dir = "{sync_dir}"\n'
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

    def _list_files_under(self, root: Path) -> list[str]:
        if not root.exists():
            return []
        return sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_file())

    def _list_dirs_under(self, root: Path) -> list[str]:
        if not root.exists():
            return []
        return sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_dir())

    def _extract_deleted_remote_paths(self, stdout: str) -> list[str]:
        prefix = "Deleting item from Microsoft OneDrive: "
        deleted_paths: list[str] = []

        for line in stdout.splitlines():
            line = line.strip()
            if line.startswith(prefix):
                deleted_paths.append(line[len(prefix):].strip())

        return deleted_paths

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0033"
        case_log_dir = context.logs_dir / "tc0033"
        state_dir = context.state_dir / "tc0033"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        seeder_root = case_work_dir / "seeder-root"
        validator_root = case_work_dir / "validator-root"
        verify_root = case_work_dir / "verify-root"

        conf_seeder = case_work_dir / "conf-seeder"
        conf_validator = case_work_dir / "conf-validator"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(seeder_root)
        reset_directory(validator_root)
        reset_directory(verify_root)

        context.prepare_minimal_config_dir(conf_seeder, "")
        context.prepare_minimal_config_dir(conf_validator, "")
        context.prepare_minimal_config_dir(conf_verify, "")

        self._write_config(conf_seeder, seeder_root)
        self._write_config(conf_validator, validator_root)
        self._write_config(conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0033_{context.run_id}_{os.getpid()}"
        source_dir_relative = f"{root_name}/SourceDirectory"
        renamed_dir_relative = f"{root_name}/RenamedDirectory"

        source_file_1_relative = f"{source_dir_relative}/top-level.txt"
        source_file_2_relative = f"{source_dir_relative}/Nested/child.txt"
        renamed_file_1_relative = f"{renamed_dir_relative}/top-level.txt"
        renamed_file_2_relative = f"{renamed_dir_relative}/Nested/child.txt"

        seeder_source_dir = seeder_root / source_dir_relative
        seeder_renamed_dir = seeder_root / renamed_dir_relative

        validator_source_dir = validator_root / source_dir_relative
        validator_renamed_dir = validator_root / renamed_dir_relative

        verify_source_dir = verify_root / source_dir_relative
        verify_renamed_dir = verify_root / renamed_dir_relative

        validator_source_file_1 = validator_root / source_file_1_relative
        validator_source_file_2 = validator_root / source_file_2_relative
        validator_renamed_file_1 = validator_root / renamed_file_1_relative
        validator_renamed_file_2 = validator_root / renamed_file_2_relative

        verify_source_file_1 = verify_root / source_file_1_relative
        verify_source_file_2 = verify_root / source_file_2_relative
        verify_renamed_file_1 = verify_root / renamed_file_1_relative
        verify_renamed_file_2 = verify_root / renamed_file_2_relative

        file1_content = "top\n"
        file2_content = "child\n"

        phase1_seed_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_seed_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_validator_initial_stdout = case_log_dir / "phase2_validator_initial_stdout.log"
        phase2_validator_initial_stderr = case_log_dir / "phase2_validator_initial_stderr.log"
        phase3_rename_stdout = case_log_dir / "phase3_directory_rename_stdout.log"
        phase3_rename_stderr = case_log_dir / "phase3_directory_rename_stderr.log"
        phase3_converge_stdout = case_log_dir / "phase3_converge_stdout.log"
        phase3_converge_stderr = case_log_dir / "phase3_converge_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        phase4_validator_reconcile_stdout = case_log_dir / "phase4_validator_reconcile_stdout.log"
        phase4_validator_reconcile_stderr = case_log_dir / "phase4_validator_reconcile_stderr.log"
        validator_manifest_file = state_dir / "validator_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_seed_stdout),
            str(phase1_seed_stderr),
            str(phase2_validator_initial_stdout),
            str(phase2_validator_initial_stderr),
            str(phase3_rename_stdout),
            str(phase3_rename_stderr),
            str(phase3_converge_stdout),
            str(phase3_converge_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(phase4_validator_reconcile_stdout),
            str(phase4_validator_reconcile_stderr),
            str(validator_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "source_dir_relative": source_dir_relative,
            "renamed_dir_relative": renamed_dir_relative,
            "source_file_1_relative": source_file_1_relative,
            "source_file_2_relative": source_file_2_relative,
            "renamed_file_1_relative": renamed_file_1_relative,
            "renamed_file_2_relative": renamed_file_2_relative,
            "seeder_conf_dir": str(conf_seeder),
            "validator_conf_dir": str(conf_validator),
            "verify_conf_dir": str(conf_verify),
            "seeder_root": str(seeder_root),
            "validator_root": str(validator_root),
            "verify_root": str(verify_root),
        }

        # Phase 1: Seeder creates the original local directory tree and syncs it online.
        write_text_file(seeder_root / source_file_1_relative, file1_content)
        write_text_file(seeder_root / source_file_2_relative, file2_content)

        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--confdir",
            str(conf_seeder),
        ]
        context.log(f"Executing Test Case {self.case_id} phase1 seed: {command_to_string(phase1_command)}")
        phase1_result = run_command(phase1_command, cwd=context.repo_root)
        write_text_file(phase1_seed_stdout, phase1_result.stdout)
        write_text_file(phase1_seed_stderr, phase1_result.stderr)
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

        # Phase 2: Validator downloads the original tree into its own local/database state.
        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_validator),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase2 validator initial download: "
            f"{command_to_string(phase2_command)}"
        )
        phase2_result = run_command(phase2_command, cwd=context.repo_root)
        write_text_file(phase2_validator_initial_stdout, phase2_result.stdout)
        write_text_file(phase2_validator_initial_stderr, phase2_result.stderr)
        details["phase2_returncode"] = phase2_result.returncode

        details["validator_initial_source_dir_exists"] = validator_source_dir.is_dir()
        details["validator_initial_source_file_1_exists"] = validator_source_file_1.is_file()
        details["validator_initial_source_file_2_exists"] = validator_source_file_2.is_file()
        details["validator_initial_renamed_dir_exists"] = validator_renamed_dir.exists()

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator initial download phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if not validator_source_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator failed to download original directory: {source_dir_relative}",
                artifacts,
                details,
            )

        if not validator_source_file_1.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator failed to download original top-level file: {source_file_1_relative}",
                artifacts,
                details,
            )

        if not validator_source_file_2.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator failed to download original nested file: {source_file_2_relative}",
                artifacts,
                details,
            )

        # Phase 3: Seeder renames the directory locally and syncs the change online.
        seeder_source_dir.rename(seeder_renamed_dir)

        details["seeder_source_dir_exists_after_local_rename"] = seeder_source_dir.exists()
        details["seeder_renamed_dir_exists_after_local_rename"] = seeder_renamed_dir.is_dir()

        if seeder_source_dir.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seeder original directory still exists immediately after rename",
                artifacts,
                details,
            )

        if not seeder_renamed_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seeder renamed directory does not exist immediately after rename",
                artifacts,
                details,
            )

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--confdir",
            str(conf_seeder),
        ]
        context.log(f"Executing Test Case {self.case_id} phase3 rename sync: {command_to_string(phase3_command)}")
        phase3_result = run_command(phase3_command, cwd=context.repo_root)
        write_text_file(phase3_rename_stdout, phase3_result.stdout)
        write_text_file(phase3_rename_stderr, phase3_result.stderr)
        details["phase3_returncode"] = phase3_result.returncode

        phase3_deleted_paths = self._extract_deleted_remote_paths(phase3_result.stdout)
        details["phase3_deleted_remote_paths"] = phase3_deleted_paths
        details["phase3_deleted_old_root_exact"] = source_dir_relative in phase3_deleted_paths
        details["phase3_deleted_old_nested_exact"] = f"{source_dir_relative}/Nested" in phase3_deleted_paths
        details["phase3_deleted_old_file_1_exact"] = source_file_1_relative in phase3_deleted_paths
        details["phase3_deleted_old_file_2_exact"] = source_file_2_relative in phase3_deleted_paths

        if phase3_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"directory rename propagation phase failed with status {phase3_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3b: Run a second seeder sync pass to converge any residual remote state.
        phase3_converge_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--confdir",
            str(conf_seeder),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase3 converge sync: "
            f"{command_to_string(phase3_converge_command)}"
        )
        phase3_converge_result = run_command(phase3_converge_command, cwd=context.repo_root)
        write_text_file(phase3_converge_stdout, phase3_converge_result.stdout)
        write_text_file(phase3_converge_stderr, phase3_converge_result.stderr)
        details["phase3_converge_returncode"] = phase3_converge_result.returncode

        phase3_converge_deleted_paths = self._extract_deleted_remote_paths(phase3_converge_result.stdout)
        details["phase3_converge_deleted_remote_paths"] = phase3_converge_deleted_paths
        details["phase3_converge_deleted_old_root_exact"] = source_dir_relative in phase3_converge_deleted_paths
        details["phase3_converge_deleted_old_nested_exact"] = (
            f"{source_dir_relative}/Nested" in phase3_converge_deleted_paths
        )

        if phase3_converge_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"directory rename convergence phase failed with status {phase3_converge_result.returncode}",
                artifacts,
                details,
            )

        # Verify remote truth independently before judging validator reconciliation.
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
        context.log(f"Executing Test Case {self.case_id} verify remote truth: {command_to_string(verify_command)}")
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)

        details["verify_source_dir_exists"] = verify_source_dir.exists()
        details["verify_renamed_dir_exists"] = verify_renamed_dir.exists()
        details["verify_source_file_1_exists"] = verify_source_file_1.exists()
        details["verify_source_file_2_exists"] = verify_source_file_2.exists()
        details["verify_renamed_file_1_exists"] = verify_renamed_file_1.exists()
        details["verify_renamed_file_2_exists"] = verify_renamed_file_2.exists()

        verify_old_tree_files = self._list_files_under(verify_source_dir)
        verify_old_tree_dirs = self._list_dirs_under(verify_source_dir)
        details["verify_old_tree_files"] = verify_old_tree_files
        details["verify_old_tree_dirs"] = verify_old_tree_dirs

        verify_new_file_1_content = (
            verify_renamed_file_1.read_text(encoding="utf-8")
            if verify_renamed_file_1.is_file()
            else ""
        )
        verify_new_file_2_content = (
            verify_renamed_file_2.read_text(encoding="utf-8")
            if verify_renamed_file_2.is_file()
            else ""
        )
        details["verify_renamed_file_1_content"] = verify_new_file_1_content
        details["verify_renamed_file_2_content"] = verify_new_file_2_content

        if verify_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        # Remote truth assertions: the old tree must be fully absent before validator is judged.
        if verify_source_dir.exists() or verify_source_file_1.exists() or verify_source_file_2.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote rename propagation incomplete: original directory tree still exists online: {source_dir_relative}",
                artifacts,
                details,
            )

        if verify_old_tree_files:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote rename propagation incomplete: old files still exist online under original directory tree: {verify_old_tree_files}",
                artifacts,
                details,
            )

        if verify_old_tree_dirs:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote rename propagation incomplete: old directories still exist online under original directory tree: {verify_old_tree_dirs}",
                artifacts,
                details,
            )

        if not verify_renamed_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing renamed directory: {renamed_dir_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_file_1.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing renamed top-level file: {renamed_file_1_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_file_2.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing renamed nested file: {renamed_file_2_relative}",
                artifacts,
                details,
            )

        if verify_new_file_1_content != file1_content:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "remote verification renamed top-level file content did not match expected content",
                artifacts,
                details,
            )

        if verify_new_file_2_content != file2_content:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "remote verification renamed nested file content did not match expected content",
                artifacts,
                details,
            )

        # Phase 4: Validator re-runs download-only against its existing local/database state,
        # but only after remote truth has been proven clean.
        phase4_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_validator),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase4 validator reconcile: "
            f"{command_to_string(phase4_command)}"
        )
        phase4_result = run_command(phase4_command, cwd=context.repo_root)
        write_text_file(phase4_validator_reconcile_stdout, phase4_result.stdout)
        write_text_file(phase4_validator_reconcile_stderr, phase4_result.stderr)
        details["phase4_returncode"] = phase4_result.returncode

        validator_manifest = build_manifest(validator_root)
        write_manifest(validator_manifest_file, validator_manifest)

        details["validator_source_dir_exists_after_reconcile"] = validator_source_dir.exists()
        details["validator_renamed_dir_exists_after_reconcile"] = validator_renamed_dir.exists()
        details["validator_source_file_1_exists_after_reconcile"] = validator_source_file_1.exists()
        details["validator_source_file_2_exists_after_reconcile"] = validator_source_file_2.exists()
        details["validator_renamed_file_1_exists_after_reconcile"] = validator_renamed_file_1.exists()
        details["validator_renamed_file_2_exists_after_reconcile"] = validator_renamed_file_2.exists()

        validator_old_tree_files = self._list_files_under(validator_source_dir)
        validator_old_tree_dirs = self._list_dirs_under(validator_source_dir)
        details["validator_old_tree_files_after_reconcile"] = validator_old_tree_files
        details["validator_old_tree_dirs_after_reconcile"] = validator_old_tree_dirs

        validator_new_file_1_content = (
            validator_renamed_file_1.read_text(encoding="utf-8")
            if validator_renamed_file_1.is_file()
            else ""
        )
        validator_new_file_2_content = (
            validator_renamed_file_2.read_text(encoding="utf-8")
            if validator_renamed_file_2.is_file()
            else ""
        )
        details["validator_renamed_file_1_content"] = validator_new_file_1_content
        details["validator_renamed_file_2_content"] = validator_new_file_2_content

        self._write_metadata(metadata_file, details)

        if phase4_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator reconcile phase failed with status {phase4_result.returncode}",
                artifacts,
                details,
            )

        if validator_source_dir.exists() or validator_source_file_1.exists() or validator_source_file_2.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator still contains original directory tree after reconciliation: {source_dir_relative}",
                artifacts,
                details,
            )

        if validator_old_tree_files:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator retained old files under original directory tree after reconciliation: {validator_old_tree_files}",
                artifacts,
                details,
            )

        if validator_old_tree_dirs:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator retained old directories under original directory tree after reconciliation: {validator_old_tree_dirs}",
                artifacts,
                details,
            )

        if not validator_renamed_dir.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator is missing renamed directory after reconciliation: {renamed_dir_relative}",
                artifacts,
                details,
            )

        if not validator_renamed_file_1.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator is missing renamed top-level file after reconciliation: {renamed_file_1_relative}",
                artifacts,
                details,
            )

        if not validator_renamed_file_2.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validator is missing renamed nested file after reconciliation: {renamed_file_2_relative}",
                artifacts,
                details,
            )

        if validator_new_file_1_content != file1_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "validator renamed top-level file content did not match expected content",
                artifacts,
                details,
            )

        if validator_new_file_2_content != file2_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "validator renamed nested file content did not match expected content",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)