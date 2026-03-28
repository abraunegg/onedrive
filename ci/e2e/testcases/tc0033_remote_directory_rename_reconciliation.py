from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0033SeederDirectoryRenameOnlineTruth(E2ETestCase):
    case_id = "0033"
    name = "seeder directory rename online truth"
    description = (
        "Validate that a single syncing client can rename a directory locally, "
        "propagate that change online, and that a fresh download sees only the renamed tree"
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
        verify_root = case_work_dir / "verify-root"

        conf_seeder = case_work_dir / "conf-seeder"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(seeder_root)
        reset_directory(verify_root)

        context.prepare_minimal_config_dir(conf_seeder, self._config_text(seeder_root))
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

        verify_original_dir = verify_root / original_dir_relative
        verify_renamed_dir = verify_root / renamed_dir_relative

        verify_original_top_file = verify_root / original_top_file_relative
        verify_original_nested_file = verify_root / original_nested_file_relative
        verify_renamed_top_file = verify_root / renamed_top_file_relative
        verify_renamed_nested_file = verify_root / renamed_nested_file_relative

        top_level_content = (
            "TC0033 seeder-only directory rename verification\n"
            "Top-level file content must be preserved.\n"
        )
        nested_content = (
            "TC0033 seeder-only directory rename verification\n"
            "Nested file content must be preserved.\n"
        )

        seed_stdout = case_log_dir / "phase1_seed_stdout.log"
        seed_stderr = case_log_dir / "phase1_seed_stderr.log"
        rename_sync_stdout = case_log_dir / "phase2_rename_sync_stdout.log"
        rename_sync_stderr = case_log_dir / "phase2_rename_sync_stderr.log"
        verify_stdout = case_log_dir / "phase3_verify_stdout.log"
        verify_stderr = case_log_dir / "phase3_verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(rename_sync_stdout),
            str(rename_sync_stderr),
            str(verify_stdout),
            str(verify_stderr),
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
            "verify_conf_dir": str(conf_verify),
            "seeder_root": str(seeder_root),
            "verify_root": str(verify_root),
        }

        # Phase 1: create original tree and sync it online
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

        # Phase 2: rename locally and sync the rename online
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

        rename_sync_command = [
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
            f"Executing Test Case {self.case_id} phase2 rename sync: {command_to_string(rename_sync_command)}"
        )
        rename_sync_result = run_command(rename_sync_command, cwd=context.repo_root)
        write_text_file(rename_sync_stdout, rename_sync_result.stdout)
        write_text_file(rename_sync_stderr, rename_sync_result.stderr)
        details["phase2_rename_sync_returncode"] = rename_sync_result.returncode

        if rename_sync_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"rename sync phase failed with status {rename_sync_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: fresh verify client downloads current remote truth
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
        context.log(f"Executing Test Case {self.case_id} phase3 verify: {command_to_string(verify_command)}")
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["phase3_verify_returncode"] = verify_result.returncode

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

        verify_new_top_content = (
            verify_renamed_top_file.read_text(encoding="utf-8")
            if verify_renamed_top_file.is_file()
            else ""
        )
        verify_new_nested_content = (
            verify_renamed_nested_file.read_text(encoding="utf-8")
            if verify_renamed_nested_file.is_file()
            else ""
        )
        details["verify_renamed_top_file_content"] = verify_new_top_content
        details["verify_renamed_nested_file_content"] = verify_new_nested_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"verify phase failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        # Strict assertions: original tree must be gone
        if verify_original_dir.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification still contains old directory: {original_dir_relative}",
                artifacts,
                details,
            )

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
                f"fresh remote verification retained old files under original tree: {verify_old_tree_files}",
                artifacts,
                details,
            )

        if verify_old_tree_dirs:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification retained old directories under original tree: {verify_old_tree_dirs}",
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

        if verify_new_top_content != top_level_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification top-level file content did not match expected content",
                artifacts,
                details,
            )

        if verify_new_nested_content != nested_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification nested file content did not match expected content",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)