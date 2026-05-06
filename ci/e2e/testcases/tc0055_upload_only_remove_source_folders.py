from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0055UploadOnlyRemoveSourceFolders(E2ETestCase):
    case_id = "0055"
    name = "upload-only remove-source-folders"
    description = "Validate that remove_source_folders removes empty local directory structure after upload-only succeeds"

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(metadata_file, "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n")

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0055",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_upload = case_work_dir / "conf-upload"
        conf_verify = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0055_{context.run_id}_{os.getpid()}"
        top_dir_relative = f"{root_name}/payload"
        file_one_relative = f"{top_dir_relative}/alpha.txt"
        file_two_relative = f"{top_dir_relative}/nested/beta.txt"

        top_dir_local = sync_root / top_dir_relative
        file_one_local = sync_root / file_one_relative
        file_two_local = sync_root / file_two_relative
        file_one_verify = verify_root / file_one_relative
        file_two_verify = verify_root / file_two_relative

        file_one_content = "TC0055 remove_source_folders alpha\n"
        file_two_content = "TC0055 remove_source_folders beta\n"

        context.prepare_minimal_config_dir(
            conf_upload,
            (
                "# tc0055 upload\n"
                f'sync_dir = "{sync_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0055 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(file_one_local, file_one_content)
        write_text_file(file_two_local, file_two_content)

        upload_stdout = case_log_dir / "upload_stdout.log"
        upload_stderr = case_log_dir / "upload_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        local_manifest_file = state_dir / "local_manifest_after_upload.txt"
        remote_manifest_file = state_dir / "remote_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(upload_stdout),
            str(upload_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_manifest_file),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details = {
            "root_name": root_name,
            "top_dir_relative": top_dir_relative,
            "file_one_relative": file_one_relative,
            "file_two_relative": file_two_relative,
        }

        upload_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--upload-only",
            "--remove-source-files",
            "--remove-source-folders",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_upload),
        ]
        context.log(f"Executing Test Case {self.case_id} upload: {command_to_string(upload_command)}")
        upload_result = run_command(upload_command, cwd=context.repo_root)
        write_text_file(upload_stdout, upload_result.stdout)
        write_text_file(upload_stderr, upload_result.stderr)
        details["upload_returncode"] = upload_result.returncode

        local_manifest = build_manifest(sync_root)
        write_manifest(local_manifest_file, local_manifest)
        details["local_top_dir_exists_after_upload"] = top_dir_local.exists()
        details["local_file_one_exists_after_upload"] = file_one_local.exists()
        details["local_file_two_exists_after_upload"] = file_two_local.exists()

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(conf_verify),
        ]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)
        details["verify_file_one_exists"] = file_one_verify.is_file()
        details["verify_file_one_content"] = file_one_verify.read_text(encoding="utf-8") if file_one_verify.is_file() else ""
        details["verify_file_two_exists"] = file_two_verify.is_file()
        details["verify_file_two_content"] = file_two_verify.read_text(encoding="utf-8") if file_two_verify.is_file() else ""
        self._write_metadata(metadata_file, details)

        if upload_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"--upload-only with remove_source_folders failed with status {upload_result.returncode}",
                artifacts,
                details,
            )
        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )
        if top_dir_local.exists() or file_one_local.exists() or file_two_local.exists() or any(entry.startswith(f"{root_name}/") for entry in local_manifest):
            return self.fail_result(
                self.case_id,
                self.name,
                "Local directory structure still exists after remove_source_folders processing",
                artifacts,
                details,
            )
        if not file_one_verify.is_file() or details["verify_file_one_content"] != file_one_content:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification missing uploaded file state: {file_one_relative}",
                artifacts,
                details,
            )
        if not file_two_verify.is_file() or details["verify_file_two_content"] != file_two_content:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification missing uploaded file state: {file_two_relative}",
                artifacts,
                details,
            )
        return self.pass_result(self.case_id, self.name, artifacts, details)
