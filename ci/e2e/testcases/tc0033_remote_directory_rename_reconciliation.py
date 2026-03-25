from __future__ import annotations

import os
import shutil
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
        "Validate that a stale local client correctly reconciles a remote-side "
        "directory rename without leaving stale local leftovers"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0033 config\n"
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
        case_work_dir = context.work_root / "tc0033"
        case_log_dir = context.logs_dir / "tc0033"
        state_dir = context.state_dir / "tc0033"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        seed_root = case_work_dir / "seedroot"
        stale_root = case_work_dir / "staleroot"
        verify_root = case_work_dir / "verifyroot"

        conf_seed = case_work_dir / "conf-seed"
        conf_stale = case_work_dir / "conf-stale"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(seed_root)
        reset_directory(verify_root)

        context.prepare_minimal_config_dir(conf_seed, "")
        context.prepare_minimal_config_dir(conf_verify, "")

        self._write_config(conf_seed, seed_root)
        self._write_config(conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0033_{context.run_id}_{os.getpid()}"
        old_dir_relative = f"{root_name}/OriginalDirectory"
        new_dir_relative = f"{root_name}/RenamedDirectory"

        old_top_file_relative = f"{old_dir_relative}/top-level.txt"
        old_nested_file_relative = f"{old_dir_relative}/Nested/child.txt"

        new_top_file_relative = f"{new_dir_relative}/top-level.txt"
        new_nested_file_relative = f"{new_dir_relative}/Nested/child.txt"

        seed_old_dir = seed_root / old_dir_relative
        seed_new_dir = seed_root / new_dir_relative

        stale_old_dir = stale_root / old_dir_relative
        stale_new_dir = stale_root / new_dir_relative

        verify_old_dir = verify_root / old_dir_relative
        verify_new_dir = verify_root / new_dir_relative

        stale_old_top_file = stale_root / old_top_file_relative
        stale_old_nested_file = stale_root / old_nested_file_relative
        stale_new_top_file = stale_root / new_top_file_relative
        stale_new_nested_file = stale_root / new_nested_file_relative

        verify_old_top_file = verify_root / old_top_file_relative
        verify_old_nested_file = verify_root / old_nested_file_relative
        verify_new_top_file = verify_root / new_top_file_relative
        verify_new_nested_file = verify_root / new_nested_file_relative

        top_level_content = (
            "TC0033 remote directory rename reconciliation\n"
            "Top-level file content must be preserved.\n"
        )
        nested_content = (
            "TC0033 remote directory rename reconciliation\n"
            "Nested file content must be preserved.\n"
        )

        seed_stdout = case_log_dir / "phase1_seed_stdout.log"
        seed_stderr = case_log_dir / "phase1_seed_stderr.log"
        remote_rename_stdout = case_log_dir / "phase2_remote_rename_stdout.log"
        remote_rename_stderr = case_log_dir / "phase2_remote_rename_stderr.log"
        stale_sync_stdout = case_log_dir / "phase3_stale_reconcile_stdout.log"
        stale_sync_stderr = case_log_dir / "phase3_stale_reconcile_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        stale_manifest_file = state_dir / "stale_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(remote_rename_stdout),
            str(remote_rename_stderr),
            str(stale_sync_stdout),
            str(stale_sync_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(stale_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "old_dir_relative": old_dir_relative,
            "new_dir_relative": new_dir_relative,
            "old_top_file_relative": old_top_file_relative,
            "old_nested_file_relative": old_nested_file_relative,
            "new_top_file_relative": new_top_file_relative,
            "new_nested_file_relative": new_nested_file_relative,
            "seed_root": str(seed_root),
            "stale_root": str(stale_root),
            "verify_root": str(verify_root),
            "seed_conf_dir": str(conf_seed),
            "stale_conf_dir": str(conf_stale),
            "verify_conf_dir": str(conf_verify),
        }

        # Phase 1: seed original remote state.
        (seed_root / old_top_file_relative).parent.mkdir(parents=True, exist_ok=True)
        (seed_root / old_nested_file_relative).parent.mkdir(parents=True, exist_ok=True)
        write_text_file(seed_root / old_top_file_relative, top_level_content)
        write_text_file(seed_root / old_nested_file_relative, nested_content)

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seed),
        ]
        context.log(f"Executing Test Case {self.case_id} phase1 seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode

        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        # Snapshot the synchronised local + config/db state to create a stale client.
        if conf_stale.exists():
            shutil.rmtree(conf_stale)
        if stale_root.exists():
            shutil.rmtree(stale_root)

        shutil.copytree(conf_seed, conf_stale)
        shutil.copytree(seed_root, stale_root)

        # Rewrite stale runtime config so it points at stale_root while preserving DB state.
        self._write_config(conf_stale, stale_root)

        details["stale_snapshot_old_dir_exists_before_reconcile"] = stale_old_dir.is_dir()
        details["stale_snapshot_new_dir_exists_before_reconcile"] = stale_new_dir.exists()
        details["stale_snapshot_old_top_file_exists_before_reconcile"] = stale_old_top_file.is_file()
        details["stale_snapshot_old_nested_file_exists_before_reconcile"] = stale_old_nested_file.is_file()

        if not stale_old_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "stale snapshot did not preserve original local directory before reconciliation",
                artifacts,
                details,
            )

        if not stale_old_top_file.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "stale snapshot did not preserve original top-level file before reconciliation",
                artifacts,
                details,
            )

        if not stale_old_nested_file.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "stale snapshot did not preserve original nested file before reconciliation",
                artifacts,
                details,
            )

        # Phase 2: perform the rename through the seed client.
        # This is our remote-side directory rename mechanism.
        seed_old_dir.rename(seed_new_dir)

        details["seed_old_dir_exists_immediately_after_rename"] = seed_old_dir.exists()
        details["seed_new_dir_exists_immediately_after_rename"] = seed_new_dir.is_dir()

        if seed_old_dir.exists():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seed local old directory still exists immediately after rename",
                artifacts,
                details,
            )

        if not seed_new_dir.is_dir():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seed local renamed directory does not exist immediately after rename",
                artifacts,
                details,
            )

        if not (seed_new_dir / "top-level.txt").is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seed local renamed directory is missing top-level file immediately after rename",
                artifacts,
                details,
            )

        if not (seed_new_dir / "Nested" / "child.txt").is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "seed local renamed directory is missing nested file immediately after rename",
                artifacts,
                details,
            )

        remote_rename_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seed),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2 remote rename: {command_to_string(remote_rename_command)}")
        remote_rename_result = run_command(remote_rename_command, cwd=context.repo_root)
        write_text_file(remote_rename_stdout, remote_rename_result.stdout)
        write_text_file(remote_rename_stderr, remote_rename_result.stderr)
        details["remote_rename_returncode"] = remote_rename_result.returncode

        if remote_rename_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote rename propagation phase failed with status {remote_rename_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: stale client reconciles the remote rename using existing DB/local state.
        # No --resync here, because this is specifically a reconciliation test.
        stale_sync_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_stale),
        ]
        context.log(f"Executing Test Case {self.case_id} phase3 stale reconcile: {command_to_string(stale_sync_command)}")
        stale_sync_result = run_command(stale_sync_command, cwd=context.repo_root)
        write_text_file(stale_sync_stdout, stale_sync_result.stdout)
        write_text_file(stale_sync_stderr, stale_sync_result.stderr)
        details["stale_reconcile_returncode"] = stale_sync_result.returncode

        stale_manifest = build_manifest(stale_root)
        write_manifest(stale_manifest_file, stale_manifest)

        details["stale_old_dir_exists_after_reconcile"] = stale_old_dir.exists()
        details["stale_new_dir_exists_after_reconcile"] = stale_new_dir.is_dir()
        details["stale_old_top_file_exists_after_reconcile"] = stale_old_top_file.exists()
        details["stale_old_nested_file_exists_after_reconcile"] = stale_old_nested_file.exists()
        details["stale_new_top_file_exists_after_reconcile"] = stale_new_top_file.is_file()
        details["stale_new_nested_file_exists_after_reconcile"] = stale_new_nested_file.is_file()

        stale_new_top_content = (
            stale_new_top_file.read_text(encoding="utf-8") if stale_new_top_file.is_file() else ""
        )
        stale_new_nested_content = (
            stale_new_nested_file.read_text(encoding="utf-8") if stale_new_nested_file.is_file() else ""
        )
        details["stale_new_top_content"] = stale_new_top_content
        details["stale_new_nested_content"] = stale_new_nested_content

        if stale_sync_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"stale reconciliation phase failed with status {stale_sync_result.returncode}",
                artifacts,
                details,
            )

        # Final clean remote verification from scratch.
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

        details["verify_old_dir_exists"] = verify_old_dir.exists()
        details["verify_new_dir_exists"] = verify_new_dir.is_dir()
        details["verify_old_top_file_exists"] = verify_old_top_file.exists()
        details["verify_old_nested_file_exists"] = verify_old_nested_file.exists()
        details["verify_new_top_file_exists"] = verify_new_top_file.is_file()
        details["verify_new_nested_file_exists"] = verify_new_nested_file.is_file()

        verify_new_top_content = (
            verify_new_top_file.read_text(encoding="utf-8") if verify_new_top_file.is_file() else ""
        )
        verify_new_nested_content = (
            verify_new_nested_file.read_text(encoding="utf-8") if verify_new_nested_file.is_file() else ""
        )
        details["verify_new_top_content"] = verify_new_top_content
        details["verify_new_nested_content"] = verify_new_nested_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if stale_old_dir.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"stale client still contains old directory after reconciliation: {old_dir_relative}",
                artifacts,
                details,
            )

        if stale_old_top_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"stale client still contains old top-level file after reconciliation: {old_top_file_relative}",
                artifacts,
                details,
            )

        if stale_old_nested_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"stale client still contains old nested file after reconciliation: {old_nested_file_relative}",
                artifacts,
                details,
            )

        if not stale_new_dir.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"stale client is missing renamed directory after reconciliation: {new_dir_relative}",
                artifacts,
                details,
            )

        if not stale_new_top_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"stale client is missing renamed top-level file after reconciliation: {new_top_file_relative}",
                artifacts,
                details,
            )

        if not stale_new_nested_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"stale client is missing renamed nested file after reconciliation: {new_nested_file_relative}",
                artifacts,
                details,
            )

        if stale_new_top_content != top_level_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "stale client renamed top-level file content did not match expected content",
                artifacts,
                details,
            )

        if stale_new_nested_content != nested_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "stale client renamed nested file content did not match expected content",
                artifacts,
                details,
            )

        if verify_old_dir.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification still contains old directory: {old_dir_relative}",
                artifacts,
                details,
            )

        if verify_old_top_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification still contains old top-level file: {old_top_file_relative}",
                artifacts,
                details,
            )

        if verify_old_nested_file.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification still contains old nested file: {old_nested_file_relative}",
                artifacts,
                details,
            )

        if not verify_new_dir.is_dir():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification is missing renamed directory: {new_dir_relative}",
                artifacts,
                details,
            )

        if not verify_new_top_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification is missing renamed top-level file: {new_top_file_relative}",
                artifacts,
                details,
            )

        if not verify_new_nested_file.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification is missing renamed nested file: {new_nested_file_relative}",
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