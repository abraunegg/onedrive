from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0024BigDeleteSafeguardValidation(E2ETestCase):
    case_id = "0024"
    name = "big delete safeguard validation"
    description = "Validate classify_as_big_delete protection and forced acknowledgement via --force"

    def _write_config(
        self,
        config_path: Path,
        sync_dir: Path,
        classify_as_big_delete: int | None = None,
    ) -> None:
        config_lines = [
            "# tc0024 config",
            f'sync_dir = "{sync_dir}"',
            'bypass_data_preservation = "true"',
        ]

        if classify_as_big_delete is not None:
            config_lines.append(f'classify_as_big_delete = "{classify_as_big_delete}"')

        write_text_file(config_path, "\n".join(config_lines) + "\n")

    def _run_and_capture(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0024"
        case_log_dir = context.logs_dir / "tc0024"
        state_dir = context.state_dir / "tc0024"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        local_root = case_work_dir / "localroot"
        verify_root = case_work_dir / "verifyroot"

        conf_local = case_work_dir / "conf-local"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(local_root)
        reset_directory(verify_root)

        context.bootstrap_config_dir(conf_local)
        context.bootstrap_config_dir(conf_verify)

        root_name = f"ZZ_E2E_TC0024_{context.run_id}_{os.getpid()}"

        parent_dir_name = "random_1K_files"
        classify_threshold = 5
        sibling_dir_count = 10
        files_per_dir = 10
        delete_dir_index = 3
        keep_dir_index = 7

        delete_dir_name = f"dir_{delete_dir_index:02d}"
        keep_dir_name = f"dir_{keep_dir_index:02d}"

        delete_dir_relative = f"{parent_dir_name}/{delete_dir_name}"
        keep_file_relative = f"{parent_dir_name}/{keep_dir_name}/file0.data"

        remote_delete_dir = f"{root_name}/{delete_dir_relative}"
        remote_keep_file = f"{root_name}/{keep_file_relative}"

        delete_dir_local = local_root / root_name / parent_dir_name / delete_dir_name

        # Create test content
        for dir_index in range(sibling_dir_count):
            child_dir = local_root / root_name / parent_dir_name / f"dir_{dir_index:02d}"
            for file_index in range(files_per_dir):
                write_text_file(
                    child_dir / f"file{file_index}.data",
                    f"tc0024 root={root_name} dir={dir_index} file={file_index}\n",
                )

        self._write_config(conf_local / "config", local_root, None)
        self._write_config(conf_verify / "config", verify_root, classify_threshold)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"

        option_change_stdout = case_log_dir / "option_change_stdout.log"
        option_change_stderr = case_log_dir / "option_change_stderr.log"

        blocked_stdout = case_log_dir / "blocked_stdout.log"
        blocked_stderr = case_log_dir / "blocked_stderr.log"

        blocked_verify_stdout = case_log_dir / "blocked_verify_stdout.log"
        blocked_verify_stderr = case_log_dir / "blocked_verify_stderr.log"

        forced_stdout = case_log_dir / "forced_stdout.log"
        forced_stderr = case_log_dir / "forced_stderr.log"

        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"

        blocked_verify_manifest_file = state_dir / "blocked_verify_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        seed_result = self._run_and_capture(
            context,
            "seed",
            seed_command,
            seed_stdout,
            seed_stderr,
        )

        if seed_result.returncode != 0:
            artifacts = [
                str(seed_stdout),
                str(seed_stderr),
            ]
            details = {
                "seed_returncode": seed_result.returncode,
                "root_name": root_name,
            }
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        # Update config to enable big delete safeguard
        self._write_config(conf_local / "config", local_root, classify_threshold)

        option_change_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        option_change_result = self._run_and_capture(
            context,
            "option change validation",
            option_change_command,
            option_change_stdout,
            option_change_stderr,
        )

        if option_change_result.returncode != 0:
            artifacts = [
                str(seed_stdout),
                str(seed_stderr),
                str(option_change_stdout),
                str(option_change_stderr),
            ]
            details = {
                "seed_returncode": seed_result.returncode,
                "option_change_returncode": option_change_result.returncode,
                "root_name": root_name,
            }
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"option change validation phase failed with status {option_change_result.returncode}",
                artifacts,
                details,
            )

        # Delete just the directory locally. The client handles the contained file deletions.
        if not delete_dir_local.is_dir():
            artifacts = [
                str(seed_stdout),
                str(seed_stderr),
                str(option_change_stdout),
                str(option_change_stderr),
            ]
            details = {
                "seed_returncode": seed_result.returncode,
                "option_change_returncode": option_change_result.returncode,
                "root_name": root_name,
                "delete_dir_local": str(delete_dir_local),
            }
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Expected local delete directory was not present before delete phase",
                artifacts,
                details,
            )

        shutil.rmtree(delete_dir_local)

        blocked_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        blocked_result = self._run_and_capture(
            context,
            "blocked sync",
            blocked_command,
            blocked_stdout,
            blocked_stderr,
        )

        blocked_output = blocked_result.stdout + "\n" + blocked_result.stderr

        # Verify remote state after blocked sync
        reset_directory(verify_root)
        self._write_config(conf_verify / "config", verify_root, classify_threshold)

        blocked_verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify),
        ]
        blocked_verify_result = self._run_and_capture(
            context,
            "blocked verify",
            blocked_verify_command,
            blocked_verify_stdout,
            blocked_verify_stderr,
        )

        blocked_remote_manifest = build_manifest(verify_root)
        write_manifest(blocked_verify_manifest_file, blocked_remote_manifest)

        # Force acknowledgement and retry
        forced_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--force",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        forced_result = self._run_and_capture(
            context,
            "forced sync",
            forced_command,
            forced_stdout,
            forced_stderr,
        )

        reset_directory(verify_root)
        self._write_config(conf_verify / "config", verify_root, classify_threshold)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify),
        ]
        verify_result = self._run_and_capture(
            context,
            "verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"local_root={local_root}",
                    f"verify_root={verify_root}",
                    f"local_confdir={conf_local}",
                    f"verify_confdir={conf_verify}",
                    f"classify_as_big_delete={classify_threshold}",
                    f"parent_dir_name={parent_dir_name}",
                    f"sibling_dir_count={sibling_dir_count}",
                    f"files_per_dir={files_per_dir}",
                    f"delete_dir_relative={delete_dir_relative}",
                    f"keep_file_relative={keep_file_relative}",
                    f"remote_delete_dir={remote_delete_dir}",
                    f"remote_keep_file={remote_keep_file}",
                    f"seed_returncode={seed_result.returncode}",
                    f"option_change_returncode={option_change_result.returncode}",
                    f"blocked_returncode={blocked_result.returncode}",
                    f"blocked_verify_returncode={blocked_verify_result.returncode}",
                    f"forced_returncode={forced_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(option_change_stdout),
            str(option_change_stderr),
            str(blocked_stdout),
            str(blocked_stderr),
            str(blocked_verify_stdout),
            str(blocked_verify_stderr),
            str(forced_stdout),
            str(forced_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(blocked_verify_manifest_file),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details = {
            "seed_returncode": seed_result.returncode,
            "option_change_returncode": option_change_result.returncode,
            "blocked_returncode": blocked_result.returncode,
            "blocked_verify_returncode": blocked_verify_result.returncode,
            "forced_returncode": forced_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        for label, rc in [
            ("blocked verify", blocked_verify_result.returncode),
            ("forced sync", forced_result.returncode),
            ("verify", verify_result.returncode),
        ]:
            if rc != 0:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} phase failed with status {rc}",
                    artifacts,
                    details,
                )

        primary_safeguard_marker = (
            "ERROR: An attempt to remove a large volume of data from OneDrive has been detected"
        )
        if primary_safeguard_marker not in blocked_output:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Blocked sync did not emit the expected big delete safeguard warning",
                artifacts,
                details,
            )

        # Before --force, deleted directory must still exist remotely and sibling content must remain.
        if remote_delete_dir not in blocked_remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Remote delete directory was modified before forced acknowledgement",
                artifacts,
                details,
            )

        if remote_keep_file not in blocked_remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Keep content disappeared during blocked safeguard processing",
                artifacts,
                details,
            )

        # After --force, the deleted directory must be gone remotely, but sibling content must remain.
        if remote_delete_dir in remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Delete directory still exists online after acknowledged forced delete",
                artifacts,
                details,
            )

        if remote_keep_file not in remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Keep content disappeared during big delete safeguard processing",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)