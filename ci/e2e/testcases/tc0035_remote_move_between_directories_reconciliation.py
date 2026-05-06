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


class TestCase0035RemoteMoveBetweenDirectoriesReconciliation(E2ETestCase):
    case_id = "0035"
    name = "remote move between directories reconciliation"
    description = (
        "Validate that a stale local client correctly reconciles a remote-side "
        "file move between directories without leaving stale local file leftovers"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0035 config\n"
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

    def _list_files_under(self, root: Path) -> list[str]:
        if not root.exists():
            return []
        return sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_file())

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0035",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

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

        root_name = f"ZZ_E2E_TC0035_{context.run_id}_{os.getpid()}"

        source_relative = f"{root_name}/SourceDirectory/move-me.txt"
        destination_relative = f"{root_name}/DestinationDirectory/move-me.txt"
        anchor_relative = f"{root_name}/DestinationDirectory/anchor.txt"

        seed_source_path = seed_root / source_relative
        seed_destination_path = seed_root / destination_relative
        seed_anchor_path = seed_root / anchor_relative

        stale_source_path = stale_root / source_relative
        stale_destination_path = stale_root / destination_relative
        stale_anchor_path = stale_root / anchor_relative

        verify_source_path = verify_root / source_relative
        verify_destination_path = verify_root / destination_relative
        verify_anchor_path = verify_root / anchor_relative

        stale_source_dir = stale_root / f"{root_name}/SourceDirectory"
        verify_source_dir = verify_root / f"{root_name}/SourceDirectory"

        initial_content = (
            "TC0035 remote move between directories reconciliation\n"
            "This file is moved remotely and must reconcile locally.\n"
        )
        anchor_content = (
            "TC0035 destination directory anchor\n"
            "This ensures the destination directory exists before the move.\n"
        )

        seed_stdout = case_log_dir / "phase1_seed_stdout.log"
        seed_stderr = case_log_dir / "phase1_seed_stderr.log"
        remote_move_stdout = case_log_dir / "phase2_remote_move_stdout.log"
        remote_move_stderr = case_log_dir / "phase2_remote_move_stderr.log"
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
            str(remote_move_stdout),
            str(remote_move_stderr),
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
            "source_relative": source_relative,
            "destination_relative": destination_relative,
            "anchor_relative": anchor_relative,
            "seed_root": str(seed_root),
            "stale_root": str(stale_root),
            "verify_root": str(verify_root),
            "seed_conf_dir": str(conf_seed),
            "stale_conf_dir": str(conf_stale),
            "verify_conf_dir": str(conf_verify),
        }

        # Phase 1: seed original remote state
        write_text_file(seed_source_path, initial_content)
        write_text_file(seed_anchor_path, anchor_content)

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
            return self.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        # Snapshot synchronised local + config/db state to create a stale client.
        # This stale client represents a second machine that has not yet seen the move.
        if conf_stale.exists():
            shutil.rmtree(conf_stale)
        if stale_root.exists():
            shutil.rmtree(stale_root)

        shutil.copytree(conf_seed, conf_stale)
        shutil.copytree(seed_root, stale_root)

        # Rewrite stale runtime config so it points at stale_root while preserving DB state.
        self._write_config(conf_stale, stale_root)

        details["stale_snapshot_source_exists_before_reconcile"] = stale_source_path.is_file()
        details["stale_snapshot_destination_exists_before_reconcile"] = stale_destination_path.exists()
        details["stale_snapshot_anchor_exists_before_reconcile"] = stale_anchor_path.is_file()

        if not stale_source_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "stale snapshot did not preserve original source file before reconciliation",
                artifacts,
                details,
            )

        # Phase 2: perform the move through the seed client.
        # This is our remote-side move mechanism.
        seed_destination_path.parent.mkdir(parents=True, exist_ok=True)
        seed_source_path.rename(seed_destination_path)

        details["seed_source_exists_after_local_move"] = seed_source_path.exists()
        details["seed_destination_exists_after_local_move"] = seed_destination_path.is_file()
        details["seed_anchor_exists_after_local_move"] = seed_anchor_path.is_file()

        if seed_source_path.exists():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "seed local source path still exists immediately after move",
                artifacts,
                details,
            )

        if not seed_destination_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "seed local destination path does not exist immediately after move",
                artifacts,
                details,
            )

        remote_move_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seed),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2 remote move: {command_to_string(remote_move_command)}")
        remote_move_result = run_command(remote_move_command, cwd=context.repo_root)
        write_text_file(remote_move_stdout, remote_move_result.stdout)
        write_text_file(remote_move_stderr, remote_move_result.stderr)
        details["remote_move_returncode"] = remote_move_result.returncode

        if remote_move_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote move propagation phase failed with status {remote_move_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: stale client reconciles the remote move using existing DB/local state.
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

        details["stale_source_exists_after_reconcile"] = stale_source_path.exists()
        details["stale_destination_exists_after_reconcile"] = stale_destination_path.is_file()
        details["stale_anchor_exists_after_reconcile"] = stale_anchor_path.is_file()
        details["stale_source_dir_files_after_reconcile"] = self._list_files_under(stale_source_dir)

        stale_destination_content = (
            stale_destination_path.read_text(encoding="utf-8")
            if stale_destination_path.is_file()
            else ""
        )
        details["stale_destination_content"] = stale_destination_content

        if stale_sync_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
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

        details["verify_source_exists"] = verify_source_path.exists()
        details["verify_destination_exists"] = verify_destination_path.is_file()
        details["verify_anchor_exists"] = verify_anchor_path.is_file()
        details["verify_source_dir_files"] = self._list_files_under(verify_source_dir)

        verify_destination_content = (
            verify_destination_path.read_text(encoding="utf-8")
            if verify_destination_path.is_file()
            else ""
        )
        details["verify_destination_content"] = verify_destination_content

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        # Stale client assertions: existing-state client must reconcile cleanly.
        if stale_source_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"stale client still contains original source file after reconciliation: {source_relative}",
                artifacts,
                details,
            )

        if details["stale_source_dir_files_after_reconcile"]:
            return self.fail_result(
                self.case_id,
                self.name,
                f"stale client retained old files under source directory after reconciliation: {details['stale_source_dir_files_after_reconcile']}",
                artifacts,
                details,
            )

        if not stale_destination_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"stale client is missing moved file after reconciliation: {destination_relative}",
                artifacts,
                details,
            )

        if stale_destination_content != initial_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "stale client moved file content did not match expected content after reconciliation",
                artifacts,
                details,
            )

        if not stale_anchor_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"stale client is missing destination anchor after reconciliation: {anchor_relative}",
                artifacts,
                details,
            )

        # Verify assertions: fresh remote truth must also be correct.
        if verify_source_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification still contains original source file path: {source_relative}",
                artifacts,
                details,
            )

        if details["verify_source_dir_files"]:
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification retained old files under source directory: {details['verify_source_dir_files']}",
                artifacts,
                details,
            )

        if not verify_destination_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing moved file at destination path: {destination_relative}",
                artifacts,
                details,
            )

        if verify_destination_content != initial_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "remote verification moved file content did not match expected content",
                artifacts,
                details,
            )

        if not verify_anchor_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing destination anchor file: {anchor_relative}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)