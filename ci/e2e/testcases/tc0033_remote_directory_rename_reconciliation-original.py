from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0033RemoteDirectoryRenameReconciliation(E2ETestCase):
    case_id = "0033"
    name = "remote directory rename reconciliation"
    description = (
        "Validate that a second client with existing local and database state correctly "
        "reconciles a remotely observed directory rename performed by another synchronising client"
    )

    def _config_text(self, sync_dir: Path) -> str:
        return (
            "# tc0033 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

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

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0033"
        case_log_dir = context.logs_dir / "tc0033"
        state_dir = context.state_dir / "tc0033"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        seeder_root = case_work_dir / "seeder-root"
        validation_root = case_work_dir / "validation-root"
        verify_root = case_work_dir / "verify-root"

        conf_seeder = case_work_dir / "conf-seeder"
        conf_validation = case_work_dir / "conf-validation"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(seeder_root)
        reset_directory(validation_root)
        reset_directory(verify_root)

        context.prepare_minimal_config_dir(conf_seeder, self._config_text(seeder_root))
        context.prepare_minimal_config_dir(conf_validation, self._config_text(validation_root))
        context.prepare_minimal_config_dir(conf_verify, self._config_text(verify_root))

        root_name = f"ZZ_E2E_TC0033_{context.run_id}_{os.getpid()}"

        original_dir_relative = f"{root_name}/OriginalDirectory"
        renamed_dir_relative = f"{root_name}/RenamedDirectory"

        original_top_file_relative = f"{original_dir_relative}/top-level.txt"
        original_nested_file_relative = f"{original_dir_relative}/Nested/child.txt"

        renamed_top_file_relative = f"{renamed_dir_relative}/top-level.txt"
        renamed_nested_file_relative = f"{renamed_dir_relative}/Nested/child.txt"

        seeder_original_dir = seeder_root / original_dir_relative
        seeder_renamed_dir = seeder_root / renamed_dir_relative

        validation_original_dir = validation_root / original_dir_relative
        validation_renamed_dir = validation_root / renamed_dir_relative

        verify_original_dir = verify_root / original_dir_relative
        verify_renamed_dir = verify_root / renamed_dir_relative

        validation_original_top_file = validation_root / original_top_file_relative
        validation_original_nested_file = validation_root / original_nested_file_relative
        validation_renamed_top_file = validation_root / renamed_top_file_relative
        validation_renamed_nested_file = validation_root / renamed_nested_file_relative

        verify_original_top_file = verify_root / original_top_file_relative
        verify_original_nested_file = verify_root / original_nested_file_relative
        verify_renamed_top_file = verify_root / renamed_top_file_relative
        verify_renamed_nested_file = verify_root / renamed_nested_file_relative

        top_level_content = "tc0033 top level file\n"
        nested_content = "tc0033 nested child file\n"

        seed_stdout = case_log_dir / "phase1_seed_stdout.log"
        seed_stderr = case_log_dir / "phase1_seed_stderr.log"
        validation_initial_stdout = case_log_dir / "phase2_validation_initial_stdout.log"
        validation_initial_stderr = case_log_dir / "phase2_validation_initial_stderr.log"
        seeder_rename_stdout = case_log_dir / "phase3_seeder_rename_stdout.log"
        seeder_rename_stderr = case_log_dir / "phase3_seeder_rename_stderr.log"
        validation_reconcile_stdout = case_log_dir / "phase4_validation_reconcile_stdout.log"
        validation_reconcile_stderr = case_log_dir / "phase4_validation_reconcile_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"

        validation_manifest_file = state_dir / "validation_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(validation_initial_stdout),
            str(validation_initial_stderr),
            str(seeder_rename_stdout),
            str(seeder_rename_stderr),
            str(validation_reconcile_stdout),
            str(validation_reconcile_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(validation_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "original_dir_relative": original_dir_relative,
            "renamed_dir_relative": renamed_dir_relative,
            "original_top_file_relative": original_top_file_relative,
            "original_nested_file_relative": original_nested_file_relative,
            "renamed_top_file_relative": renamed_top_file_relative,
            "renamed_nested_file_relative": renamed_nested_file_relative,
            "seeder_conf_dir": str(conf_seeder),
            "validation_conf_dir": str(conf_validation),
            "verify_conf_dir": str(conf_verify),
            "seeder_root": str(seeder_root),
            "validation_root": str(validation_root),
            "verify_root": str(verify_root),
        }

        # Phase 1: Seeder creates the original directory tree locally and syncs it.
        write_text_file(seeder_root / original_top_file_relative, top_level_content)
        write_text_file(seeder_root / original_nested_file_relative, nested_content)

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seeder),
        ]
        context.log(f"Executing Test Case {self.case_id} phase1 seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["phase1_seed_returncode"] = seed_result.returncode

        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        # Phase 2: Validation client downloads the initial original directory tree.
        validation_initial_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_validation),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase2 validation initial download: "
            f"{command_to_string(validation_initial_command)}"
        )
        validation_initial_result = run_command(validation_initial_command, cwd=context.repo_root)
        write_text_file(validation_initial_stdout, validation_initial_result.stdout)
        write_text_file(validation_initial_stderr, validation_initial_result.stderr)
        details["phase2_validation_initial_returncode"] = validation_initial_result.returncode

        details["validation_initial_original_dir_exists"] = validation_original_dir.is_dir()
        details["validation_initial_original_top_file_exists"] = validation_original_top_file.is_file()
        details["validation_initial_original_nested_file_exists"] = validation_original_nested_file.is_file()
        details["validation_initial_renamed_dir_exists"] = validation_renamed_dir.exists()

        if validation_initial_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation initial download phase failed with status {validation_initial_result.returncode}",
                artifacts,
                details,
            )

        if not validation_original_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client failed to download original directory: {original_dir_relative}",
                artifacts,
                details,
            )

        if not validation_original_top_file.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client failed to download original top-level file: {original_top_file_relative}",
                artifacts,
                details,
            )

        if not validation_original_nested_file.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client failed to download original nested file: {original_nested_file_relative}",
                artifacts,
                details,
            )

        # Phase 3: Seeder renames the directory locally and performs a normal sync.
        seeder_original_dir.rename(seeder_renamed_dir)

        details["seeder_original_dir_exists_after_local_rename"] = seeder_original_dir.exists()
        details["seeder_renamed_dir_exists_after_local_rename"] = seeder_renamed_dir.is_dir()

        if seeder_original_dir.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seeder original directory still exists immediately after local rename",
                artifacts,
                details,
            )

        if not seeder_renamed_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seeder renamed directory does not exist immediately after local rename",
                artifacts,
                details,
            )

        seeder_rename_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seeder),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase3 seeder rename sync: "
            f"{command_to_string(seeder_rename_command)}"
        )
        seeder_rename_result = run_command(seeder_rename_command, cwd=context.repo_root)
        write_text_file(seeder_rename_stdout, seeder_rename_result.stdout)
        write_text_file(seeder_rename_stderr, seeder_rename_result.stderr)
        details["phase3_seeder_rename_returncode"] = seeder_rename_result.returncode

        if seeder_rename_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"seeder rename sync phase failed with status {seeder_rename_result.returncode}",
                artifacts,
                details,
            )

        # Phase 4: Validation client re-runs download-only using its existing local/database state.
        validation_reconcile_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_validation),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase4 validation reconcile: "
            f"{command_to_string(validation_reconcile_command)}"
        )
        validation_reconcile_result = run_command(validation_reconcile_command, cwd=context.repo_root)
        write_text_file(validation_reconcile_stdout, validation_reconcile_result.stdout)
        write_text_file(validation_reconcile_stderr, validation_reconcile_result.stderr)
        details["phase4_validation_reconcile_returncode"] = validation_reconcile_result.returncode

        validation_manifest = build_manifest(validation_root)
        write_manifest(validation_manifest_file, validation_manifest)

        details["validation_original_dir_exists_after_reconcile"] = validation_original_dir.exists()
        details["validation_renamed_dir_exists_after_reconcile"] = validation_renamed_dir.is_dir()
        details["validation_original_top_file_exists_after_reconcile"] = validation_original_top_file.exists()
        details["validation_original_nested_file_exists_after_reconcile"] = validation_original_nested_file.exists()
        details["validation_renamed_top_file_exists_after_reconcile"] = validation_renamed_top_file.is_file()
        details["validation_renamed_nested_file_exists_after_reconcile"] = validation_renamed_nested_file.is_file()

        validation_old_tree_files = self._list_files_under(validation_original_dir)
        validation_old_tree_dirs = self._list_dirs_under(validation_original_dir)
        details["validation_old_tree_files_after_reconcile"] = validation_old_tree_files
        details["validation_old_tree_dirs_after_reconcile"] = validation_old_tree_dirs

        validation_renamed_top_file_content = (
            validation_renamed_top_file.read_text(encoding="utf-8")
            if validation_renamed_top_file.is_file()
            else ""
        )
        validation_renamed_nested_file_content = (
            validation_renamed_nested_file.read_text(encoding="utf-8")
            if validation_renamed_nested_file.is_file()
            else ""
        )
        details["validation_renamed_top_file_content"] = validation_renamed_top_file_content
        details["validation_renamed_nested_file_content"] = validation_renamed_nested_file_content

        if validation_reconcile_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation reconcile phase failed with status {validation_reconcile_result.returncode}",
                artifacts,
                details,
            )

        # Final verification from scratch against current remote truth.
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

        details["verify_original_dir_exists"] = verify_original_dir.exists()
        details["verify_renamed_dir_exists"] = verify_renamed_dir.is_dir()
        details["verify_original_top_file_exists"] = verify_original_top_file.exists()
        details["verify_original_nested_file_exists"] = verify_original_nested_file.exists()
        details["verify_renamed_top_file_exists"] = verify_renamed_top_file.is_file()
        details["verify_renamed_nested_file_exists"] = verify_renamed_nested_file.is_file()

        verify_old_tree_files = self._list_files_under(verify_original_dir)
        verify_old_tree_dirs = self._list_dirs_under(verify_original_dir)
        details["verify_old_tree_files"] = verify_old_tree_files
        details["verify_old_tree_dirs"] = verify_old_tree_dirs

        verify_renamed_top_file_content = (
            verify_renamed_top_file.read_text(encoding="utf-8")
            if verify_renamed_top_file.is_file()
            else ""
        )
        verify_renamed_nested_file_content = (
            verify_renamed_nested_file.read_text(encoding="utf-8")
            if verify_renamed_nested_file.is_file()
            else ""
        )
        details["verify_renamed_top_file_content"] = verify_renamed_top_file_content
        details["verify_renamed_nested_file_content"] = verify_renamed_nested_file_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        # Validation client must not retain any old payload files under the original tree.
        if validation_original_top_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client still contains old top-level file after reconciliation: {original_top_file_relative}",
                artifacts,
                details,
            )

        if validation_original_nested_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client still contains old nested file after reconciliation: {original_nested_file_relative}",
                artifacts,
                details,
            )

        if validation_old_tree_files:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "validation client retained old payload files somewhere under the original directory tree "
                f"after reconciliation: {validation_old_tree_files}",
                artifacts,
                details,
            )

        if not validation_renamed_dir.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client is missing renamed directory after reconciliation: {renamed_dir_relative}",
                artifacts,
                details,
            )

        if not validation_renamed_top_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client is missing renamed top-level file after reconciliation: {renamed_top_file_relative}",
                artifacts,
                details,
            )

        if not validation_renamed_nested_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"validation client is missing renamed nested file after reconciliation: {renamed_nested_file_relative}",
                artifacts,
                details,
            )

        if validation_renamed_top_file_content != top_level_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "validation client renamed top-level file content did not match expected content",
                artifacts,
                details,
            )

        if validation_renamed_nested_file_content != nested_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "validation client renamed nested file content did not match expected content",
                artifacts,
                details,
            )

        # Fresh verification must also show no old payload files anywhere under the original tree.
        if verify_original_top_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification still contains old top-level file: {original_top_file_relative}",
                artifacts,
                details,
            )

        if verify_original_nested_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification still contains old nested file: {original_nested_file_relative}",
                artifacts,
                details,
            )

        if verify_old_tree_files:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification retained old payload files somewhere under the original "
                f"directory tree: {verify_old_tree_files}",
                artifacts,
                details,
            )

        if not verify_renamed_dir.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification is missing renamed directory: {renamed_dir_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_top_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification is missing renamed top-level file: {renamed_top_file_relative}",
                artifacts,
                details,
            )

        if not verify_renamed_nested_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification is missing renamed nested file: {renamed_nested_file_relative}",
                artifacts,
                details,
            )

        if verify_renamed_top_file_content != top_level_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification top-level file content did not match expected content",
                artifacts,
                details,
            )

        if verify_renamed_nested_file_content != nested_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification nested file content did not match expected content",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)