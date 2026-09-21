from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, rename_xlsx_pair, xlsx_pair_any_exists, xlsx_pair_all_files
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)


class TestCase0032RemoteRenameReconciliation(E2ETestCase):
    case_id = "0032"
    name = "remote rename reconciliation"
    description = (
        "Validate that a stale local client correctly reconciles remote-side passive TXT and real XLSX file renames "
        "without leaving stale local leftovers"
    )

    XLSX_PAYLOAD_ROWS = 32

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0032 config\n"
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
            case_dir_name="tc0032",
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

        root_name = f"ZZ_E2E_TC0032_{context.run_id}_{os.getpid()}"
        old_txt_relative = f"{root_name}/remote-original-name.txt"
        new_txt_relative = f"{root_name}/remote-renamed-name.txt"
        old_xlsx_relative = f"{root_name}/remote-original-name.xlsx"
        new_xlsx_relative = f"{root_name}/remote-renamed-name.xlsx"

        seed_old_txt_path = seed_root / old_txt_relative
        seed_new_txt_path = seed_root / new_txt_relative
        seed_old_xlsx_path = seed_root / old_xlsx_relative
        seed_new_xlsx_path = seed_root / new_xlsx_relative

        stale_old_txt_path = stale_root / old_txt_relative
        stale_new_txt_path = stale_root / new_txt_relative
        stale_old_xlsx_path = stale_root / old_xlsx_relative
        stale_new_xlsx_path = stale_root / new_xlsx_relative

        verify_old_txt_path = verify_root / old_txt_relative
        verify_new_txt_path = verify_root / new_txt_relative
        verify_old_xlsx_path = verify_root / old_xlsx_relative
        verify_new_xlsx_path = verify_root / new_xlsx_relative

        txt_content = (
            "TC0032 remote rename reconciliation\n"
            "This passive text file is renamed remotely and must reconcile locally.\n"
        )
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0032:{os.getpid()}"

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
            "old_txt_relative": old_txt_relative,
            "new_txt_relative": new_txt_relative,
            "old_xlsx_relative": old_xlsx_relative,
            "new_xlsx_relative": new_xlsx_relative,
            "seed_root": str(seed_root),
            "stale_root": str(stale_root),
            "verify_root": str(verify_root),
            "seed_conf_dir": str(conf_seed),
            "stale_conf_dir": str(conf_stale),
            "verify_conf_dir": str(conf_verify),
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
        }

        # Phase 1: seed original remote state with both a passive and Microsoft-processed payload class.
        write_text_file(seed_old_txt_path, txt_content)
        generated = create_random_xlsx_pair(
            seed_old_xlsx_path,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0032 remote rename reconciliation workbook",
        )
        details["generated_xlsx_size"] = int(generated["size_bytes"])

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

        settled_txt_content = seed_old_txt_path.read_text(encoding="utf-8") if seed_old_txt_path.is_file() else ""
        settled_xlsx_validation_error = validate_xlsx_pair(seed_old_xlsx_path, REVISION_0)
        details["settled_txt_content"] = settled_txt_content
        details["settled_xlsx_validation_error"] = settled_xlsx_validation_error

        if settled_txt_content != txt_content:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "seeded passive TXT content changed during initial sync",
                artifacts,
                details,
            )

        if settled_xlsx_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"seeded XLSX was invalid after initial sync: {settled_xlsx_validation_error}",
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

        details["stale_snapshot_old_txt_exists_before_reconcile"] = stale_old_txt_path.is_file()
        details["stale_snapshot_new_txt_exists_before_reconcile"] = stale_new_txt_path.exists()
        details["stale_snapshot_old_xlsx_exists_before_reconcile"] = stale_old_xlsx_path.is_file()
        details["stale_snapshot_new_xlsx_exists_before_reconcile"] = stale_new_xlsx_path.exists()

        if not stale_old_txt_path.is_file() or not stale_old_xlsx_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "stale snapshot did not preserve both original local files before reconciliation",
                artifacts,
                details,
            )

        if stale_old_txt_path.read_text(encoding="utf-8") != txt_content:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "stale snapshot passive TXT content did not match expected content",
                artifacts,
                details,
            )

        stale_snapshot_xlsx_validation_error = validate_xlsx_pair(stale_old_xlsx_path, REVISION_0)
        details["stale_snapshot_xlsx_validation_error"] = stale_snapshot_xlsx_validation_error
        if stale_snapshot_xlsx_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"stale snapshot XLSX was invalid before reconciliation: {stale_snapshot_xlsx_validation_error}",
                artifacts,
                details,
            )

        # Phase 2: perform both renames through the seed client.
        seed_old_txt_path.rename(seed_new_txt_path)
        rename_xlsx_pair(seed_old_xlsx_path, seed_new_xlsx_path)

        if seed_old_txt_path.exists() or xlsx_pair_any_exists(seed_old_xlsx_path):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "one or more seed old filenames still exist immediately after rename",
                artifacts,
                details,
            )

        if not seed_new_txt_path.is_file() or not xlsx_pair_all_files(seed_new_xlsx_path):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "one or more seed renamed files are missing immediately after rename",
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
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote rename propagation phase failed with status {remote_rename_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: stale client reconciles both remote renames using existing DB/local state.
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

        details["stale_old_txt_exists_after_reconcile"] = stale_old_txt_path.exists()
        details["stale_new_txt_exists_after_reconcile"] = stale_new_txt_path.is_file()
        details["stale_old_xlsx_exists_after_reconcile"] = stale_old_xlsx_path.exists()
        details["stale_new_xlsx_exists_after_reconcile"] = stale_new_xlsx_path.is_file()
        stale_new_txt_content = stale_new_txt_path.read_text(encoding="utf-8") if stale_new_txt_path.is_file() else ""
        stale_new_xlsx_validation_error = (
            validate_xlsx_pair(stale_new_xlsx_path, REVISION_0)
            if stale_new_xlsx_path.is_file()
            else "Stale client XLSX is missing"
        )
        details["stale_new_txt_content"] = stale_new_txt_content
        details["stale_new_xlsx_validation_error"] = stale_new_xlsx_validation_error

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

        details["verify_old_txt_exists"] = verify_old_txt_path.exists()
        details["verify_new_txt_exists"] = verify_new_txt_path.is_file()
        details["verify_old_xlsx_exists"] = verify_old_xlsx_path.exists()
        details["verify_new_xlsx_exists"] = verify_new_xlsx_path.is_file()
        verify_new_txt_content = verify_new_txt_path.read_text(encoding="utf-8") if verify_new_txt_path.is_file() else ""
        verify_new_xlsx_validation_error = (
            validate_xlsx_pair(verify_new_xlsx_path, REVISION_0)
            if verify_new_xlsx_path.is_file()
            else "Verification XLSX is missing"
        )
        details["verify_new_txt_content"] = verify_new_txt_content
        details["verify_new_xlsx_validation_error"] = verify_new_xlsx_validation_error

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if stale_old_txt_path.exists() or xlsx_pair_any_exists(stale_old_xlsx_path):
            return self.fail_result(
                self.case_id,
                self.name,
                "stale client still contains one or more old filenames after reconciliation",
                artifacts,
                details,
            )

        if not stale_new_txt_path.is_file() or not xlsx_pair_all_files(stale_new_xlsx_path):
            return self.fail_result(
                self.case_id,
                self.name,
                "stale client is missing one or more renamed files after reconciliation",
                artifacts,
                details,
            )

        if stale_new_txt_content != txt_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "stale client renamed passive TXT content did not match expected content after reconciliation",
                artifacts,
                details,
            )

        if stale_new_xlsx_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"stale client renamed XLSX is invalid or stale after reconciliation: {stale_new_xlsx_validation_error}",
                artifacts,
                details,
            )

        if verify_old_txt_path.exists() or xlsx_pair_any_exists(verify_old_xlsx_path):
            return self.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification still contains one or more old filenames",
                artifacts,
                details,
            )

        if not verify_new_txt_path.is_file() or not xlsx_pair_all_files(verify_new_xlsx_path):
            return self.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification is missing one or more renamed files",
                artifacts,
                details,
            )

        if verify_new_txt_content != txt_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "fresh remote verification passive TXT content did not match expected content",
                artifacts,
                details,
            )

        if verify_new_xlsx_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"fresh remote verification returned an invalid or stale XLSX workbook: {verify_new_xlsx_validation_error}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
