from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, create_random_xlsx, validate_xlsx
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)


class TestCase0030LocalRenamePropagationValidation(E2ETestCase):
    case_id = "0030"
    name = "local rename propagation validation"
    description = (
        "Validate that renaming passive TXT and real XLSX files locally is correctly propagated to remote state"
    )

    XLSX_PAYLOAD_ROWS = 32

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0030 config\n"
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
            case_dir_name="tc0030",
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

        root_name = f"ZZ_E2E_TC0030_{context.run_id}_{os.getpid()}"
        old_txt_relative = f"{root_name}/original-name.txt"
        new_txt_relative = f"{root_name}/renamed-file.txt"
        old_xlsx_relative = f"{root_name}/original-name.xlsx"
        new_xlsx_relative = f"{root_name}/renamed-file.xlsx"

        old_txt_local_path = local_root / old_txt_relative
        new_txt_local_path = local_root / new_txt_relative
        old_xlsx_local_path = local_root / old_xlsx_relative
        new_xlsx_local_path = local_root / new_xlsx_relative

        txt_content = (
            "TC0030 local rename propagation validation\n"
            "This passive text content must survive the rename operation unchanged.\n"
        )
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0030:{os.getpid()}"

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_rename_stdout.log"
        phase2_stderr = case_log_dir / "phase2_rename_stderr.log"
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
            "old_txt_relative": old_txt_relative,
            "new_txt_relative": new_txt_relative,
            "old_xlsx_relative": old_xlsx_relative,
            "new_xlsx_relative": new_xlsx_relative,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
        }

        write_text_file(old_txt_local_path, txt_content)
        generated = create_random_xlsx(
            old_xlsx_local_path,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0030 local rename propagation workbook",
        )
        details["generated_xlsx_size"] = int(generated["size_bytes"])

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

        settled_xlsx_validation_error = validate_xlsx(old_xlsx_local_path, REVISION_0)
        details["settled_xlsx_validation_error"] = settled_xlsx_validation_error
        details["settled_txt_content"] = (
            old_txt_local_path.read_text(encoding="utf-8") if old_txt_local_path.is_file() else ""
        )

        if details["settled_txt_content"] != txt_content:
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

        old_txt_local_path.rename(new_txt_local_path)
        old_xlsx_local_path.rename(new_xlsx_local_path)

        details["old_txt_exists_after_local_rename"] = old_txt_local_path.exists()
        details["new_txt_exists_after_local_rename"] = new_txt_local_path.is_file()
        details["old_xlsx_exists_after_local_rename"] = old_xlsx_local_path.exists()
        details["new_xlsx_exists_after_local_rename"] = new_xlsx_local_path.is_file()

        if old_txt_local_path.exists() or old_xlsx_local_path.exists():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "one or more local old filenames still exist immediately after rename",
                artifacts,
                details,
            )

        if not new_txt_local_path.is_file() or not new_xlsx_local_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "one or more local renamed files are missing immediately after rename",
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
                f"rename propagation phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

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

        verify_old_txt_path = verify_root / old_txt_relative
        verify_new_txt_path = verify_root / new_txt_relative
        verify_old_xlsx_path = verify_root / old_xlsx_relative
        verify_new_xlsx_path = verify_root / new_xlsx_relative

        details["verify_old_txt_exists"] = verify_old_txt_path.exists()
        details["verify_new_txt_exists"] = verify_new_txt_path.is_file()
        details["verify_old_xlsx_exists"] = verify_old_xlsx_path.exists()
        details["verify_new_xlsx_exists"] = verify_new_xlsx_path.is_file()
        details["verify_new_txt_content"] = (
            verify_new_txt_path.read_text(encoding="utf-8") if verify_new_txt_path.is_file() else ""
        )
        verify_xlsx_validation_error = (
            validate_xlsx(verify_new_xlsx_path, REVISION_0)
            if verify_new_xlsx_path.is_file()
            else "Verification XLSX is missing"
        )
        details["verify_xlsx_validation_error"] = verify_xlsx_validation_error

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if verify_old_txt_path.exists() or verify_old_xlsx_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                "remote verification still contains one or more old filenames",
                artifacts,
                details,
            )

        if not verify_new_txt_path.is_file() or not verify_new_xlsx_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                "remote verification is missing one or more renamed files",
                artifacts,
                details,
            )

        if details["verify_new_txt_content"] != txt_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "renamed passive TXT content did not match the original content after remote verification",
                artifacts,
                details,
            )

        if verify_xlsx_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"remote verification returned an invalid or stale XLSX workbook: {verify_xlsx_validation_error}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
