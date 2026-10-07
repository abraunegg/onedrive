from __future__ import annotations

import os
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


class TestCase0034LocalMoveBetweenDirectoriesValidation(E2ETestCase):
    case_id = "0034"
    name = "local move between directories validation"
    description = (
        "Validate that moving passive TXT and real XLSX files from one directory to another "
        "is correctly propagated to remote state"
    )

    XLSX_PAYLOAD_ROWS = 32

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
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0034",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

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
        source_txt_relative = f"{root_name}/SourceDirectory/move-me.txt"
        destination_txt_relative = f"{root_name}/DestinationDirectory/move-me.txt"
        source_xlsx_relative = f"{root_name}/SourceDirectory/move-me.xlsx"
        destination_xlsx_relative = f"{root_name}/DestinationDirectory/move-me.xlsx"
        anchor_relative = f"{root_name}/DestinationDirectory/anchor.txt"

        local_source_txt_path = local_root / source_txt_relative
        local_destination_txt_path = local_root / destination_txt_relative
        local_source_xlsx_path = local_root / source_xlsx_relative
        local_destination_xlsx_path = local_root / destination_xlsx_relative
        local_anchor_path = local_root / anchor_relative

        verify_source_txt_path = verify_root / source_txt_relative
        verify_destination_txt_path = verify_root / destination_txt_relative
        verify_source_xlsx_path = verify_root / source_xlsx_relative
        verify_destination_xlsx_path = verify_root / destination_xlsx_relative
        verify_anchor_path = verify_root / anchor_relative

        initial_content = (
            "TC0034 local move between directories validation\n"
            "This content must survive the directory move unchanged.\n"
        )
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0034:{os.getpid()}"
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
            "source_txt_relative": source_txt_relative,
            "destination_txt_relative": destination_txt_relative,
            "source_xlsx_relative": source_xlsx_relative,
            "destination_xlsx_relative": destination_xlsx_relative,
            "anchor_relative": anchor_relative,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
        }

        # Phase 1: seed original state with passive TXT, real XLSX and destination anchor
        write_text_file(local_source_txt_path, initial_content)
        generated = create_random_xlsx_pair(
            local_source_xlsx_path,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0034 local move between directories workbook",
        )
        details["generated_size"] = int(generated["size_bytes"])
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
            return self.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {phase1_result.returncode}",
                artifacts,
                details,
            )

        settled_txt_content = (
            local_source_txt_path.read_text(encoding="utf-8")
            if local_source_txt_path.is_file()
            else ""
        )
        details["settled_txt_content"] = settled_txt_content
        if settled_txt_content != initial_content:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "seeded passive TXT content changed during initial sync",
                artifacts,
                details,
            )

        settled_validation_error = validate_xlsx_pair(local_source_xlsx_path, REVISION_0)
        details["settled_validation_error"] = settled_validation_error
        if settled_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"seeded XLSX was invalid after initial sync: {settled_validation_error}",
                artifacts,
                details,
            )

        # Phase 2: move both files locally between directories without renaming them.
        local_destination_txt_path.parent.mkdir(parents=True, exist_ok=True)
        local_source_txt_path.rename(local_destination_txt_path)
        rename_xlsx_pair(local_source_xlsx_path, local_destination_xlsx_path)

        details["local_source_txt_exists_after_move"] = local_source_txt_path.exists()
        details["local_destination_txt_exists_after_move"] = local_destination_txt_path.is_file()
        details["local_source_xlsx_exists_after_move"] = local_source_xlsx_path.exists()
        details["local_destination_xlsx_exists_after_move"] = local_destination_xlsx_path.is_file()
        details["local_anchor_exists_after_move"] = local_anchor_path.is_file()

        if local_source_txt_path.exists() or xlsx_pair_any_exists(local_source_xlsx_path):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "one or more local source files still exist immediately after move",
                artifacts,
                details,
            )

        if not local_destination_txt_path.is_file() or not xlsx_pair_all_files(local_destination_xlsx_path):
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "one or more local destination files do not exist immediately after move",
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
            return self.fail_result(
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

        details["verify_source_txt_exists"] = verify_source_txt_path.exists()
        details["verify_destination_txt_exists"] = verify_destination_txt_path.is_file()
        details["verify_source_xlsx_exists"] = xlsx_pair_any_exists(verify_source_xlsx_path)
        details["verify_destination_xlsx_exists"] = xlsx_pair_all_files(verify_destination_xlsx_path)
        details["verify_anchor_exists"] = verify_anchor_path.is_file()

        verify_destination_txt_content = (
            verify_destination_txt_path.read_text(encoding="utf-8")
            if verify_destination_txt_path.is_file()
            else ""
        )
        details["verify_destination_txt_content"] = verify_destination_txt_content

        verify_destination_validation_error = (
            validate_xlsx_pair(verify_destination_xlsx_path, REVISION_0)
            if xlsx_pair_all_files(verify_destination_xlsx_path)
            else "Verification XLSX is missing"
        )
        details["verify_destination_validation_error"] = verify_destination_validation_error

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if verify_source_txt_path.exists() or xlsx_pair_any_exists(verify_source_xlsx_path):
            return self.fail_result(
                self.case_id,
                self.name,
                "remote verification still contains one or more source file paths",
                artifacts,
                details,
            )

        if not verify_destination_txt_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing moved passive TXT at destination path: {destination_txt_relative}",
                artifacts,
                details,
            )

        if verify_destination_txt_content != initial_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "moved passive TXT content did not match the original content after remote verification",
                artifacts,
                details,
            )

        if not xlsx_pair_all_files(verify_destination_xlsx_path):
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing moved XLSX at destination path: {destination_xlsx_relative}",
                artifacts,
                details,
            )

        if verify_destination_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"moved XLSX is invalid or stale after remote verification: {verify_destination_validation_error}",
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