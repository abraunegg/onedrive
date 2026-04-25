from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0024BigDeleteSafeguardValidation(E2ETestCase):
    case_id = "0024"
    name = "big delete safeguard validation"
    description = "Validate classify_as_big_delete protection and forced acknowledgement via --force"

    def _write_config(
        self,
        config_path: Path,
        sync_dir: Path,
        classify_as_big_delete: int,
    ) -> None:
        config_lines = [
            "# tc0024 config",
            f'sync_dir = "{sync_dir}"',
            f'classify_as_big_delete = "{classify_as_big_delete}"',
        ]
        write_onedrive_config(config_path, "\n".join(config_lines) + "\n")

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
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0024",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        local_root = case_work_dir / "localroot"
        verify_root = case_work_dir / "verifyroot"

        conf_local = case_work_dir / "conf-local"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(local_root)
        reset_directory(verify_root)

        context.bootstrap_config_dir(conf_local)
        context.bootstrap_config_dir(conf_verify)

        parent_dir_name = "random_1K_files"
        initial_threshold = 1000
        classify_threshold = 5
        sibling_dir_count = 10
        files_per_dir = 10
        delete_dir_index = 2
        keep_dir_index = 7

        # Use deterministic random-looking directory names to mirror the proven manual workflow
        dir_names = [
            "q0NToXSgyrO8R5XO9t3jkzmVfEu4WCVh",
            "RlWYV0dKiI096pt5F9eXg6jGZGUejI30",
            "70M1EMwQUqzzQU4c8ua7C4DVvzo7KUWO",
            "9systOMPHWQ7TozssIbYZFPGgPhQA9vt",
            "ilmjoysWYI1EnbLscBmYxc5H9ikqLZ4Z",
            "ZNZnjOCA83dutD8d3SD6j87CGeYMnCMH",
            "qtkaQHpZcMbM7GJnNUBfBwJ4YLxfmxp3",
            "YwTfxsBmSgSaCS39vpgEswNU27wJcogI",
            "oWvTo5vd9rLJI3KB1RErqAH8fy4sjQjp",
            "aUmMwbQVWImEHEr555QyHqHveKMT0XGJ",
        ]

        delete_dir_name = dir_names[delete_dir_index]
        keep_dir_name = dir_names[keep_dir_index]

        delete_dir_relative = f"{parent_dir_name}/{delete_dir_name}"
        keep_file_relative = f"{parent_dir_name}/{keep_dir_name}/file0.data"

        remote_delete_dir = delete_dir_relative
        remote_deleted_probe_file = f"{delete_dir_relative}/file0.data"
        remote_keep_file = keep_file_relative

        delete_dir_local = local_root / parent_dir_name / delete_dir_name

        # Create 10 directories x 10 files = 100 files
        for dir_name in dir_names:
            child_dir = local_root / parent_dir_name / dir_name
            for file_index in range(files_per_dir):
                write_text_file(
                    child_dir / f"file{file_index}.data",
                    f"tc0024 dir={dir_name} file={file_index}\n",
                )

        self._write_config(conf_local / "config", local_root, initial_threshold)
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
        verify_retry_manifest_file = state_dir / "remote_verify_retry_manifest.txt"

        blocked_verify_manifest_file = state_dir / "blocked_verify_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        # Step 1: upload all data with a high threshold, matching the manual process
        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
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
            artifacts = [str(seed_stdout), str(seed_stderr)]
            details = {"seed_returncode": seed_result.returncode}
            return self.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        # Step 2: update config to enable big delete safeguard and run again with no changes
        self._write_config(conf_local / "config", local_root, classify_threshold)

        option_change_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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
            }
            return self.fail_result(
                self.case_id,
                self.name,
                f"option change validation phase failed with status {option_change_result.returncode}",
                artifacts,
                details,
            )

        # Step 3: remove one entire directory locally
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
                "delete_dir_local": str(delete_dir_local),
            }
            return self.fail_result(
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

        # Step 4: rerun with --force
        forced_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--force",
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

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--confdir",
            str(conf_verify),
        ]

        verify_attempts = 0
        verify_result = None
        remote_manifest: list[str] = []

        # Personal accounts can occasionally expose a short remote visibility lag after
        # a forced delete: child files are gone, but the now-empty parent directory can
        # still appear in the immediately-following verification sync. Retry only the
        # final remote verification step; do not retry command failures or weaken the
        # big-delete safeguard checks themselves.
        for attempt in range(1, 4):
            verify_attempts = attempt
            reset_directory(verify_root)
            self._write_config(conf_verify / "config", verify_root, classify_threshold)

            attempt_stdout = verify_stdout if attempt == 1 else case_log_dir / f"verify_retry_{attempt}_stdout.log"
            attempt_stderr = verify_stderr if attempt == 1 else case_log_dir / f"verify_retry_{attempt}_stderr.log"

            verify_result = self._run_and_capture(
                context,
                "verify" if attempt == 1 else f"verify retry {attempt}",
                verify_command,
                attempt_stdout,
                attempt_stderr,
            )

            remote_manifest = build_manifest(verify_root)
            if attempt == 1:
                write_manifest(remote_manifest_file, remote_manifest)
            else:
                write_manifest(verify_retry_manifest_file, remote_manifest)

            if verify_result.returncode != 0:
                break

            if remote_delete_dir not in remote_manifest and remote_deleted_probe_file not in remote_manifest:
                break

            if attempt < 3:
                context.log(
                    f"Test Case {self.case_id} final verify still sees deleted remote path "
                    f"after forced delete; retrying final verification in 30 seconds "
                    f"(attempt {attempt}/3)"
                )
                time.sleep(30)

        assert verify_result is not None

        # Preserve the final observed manifest at the primary artifact path so failure
        # diagnostics always reflect the state that drove the pass/fail decision.
        write_manifest(remote_manifest_file, remote_manifest)

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"local_root={local_root}",
                    f"verify_root={verify_root}",
                    f"local_confdir={conf_local}",
                    f"verify_confdir={conf_verify}",
                    f"initial_threshold={initial_threshold}",
                    f"classify_as_big_delete={classify_threshold}",
                    f"parent_dir_name={parent_dir_name}",
                    f"sibling_dir_count={sibling_dir_count}",
                    f"files_per_dir={files_per_dir}",
                    f"delete_dir_relative={delete_dir_relative}",
                    f"keep_file_relative={keep_file_relative}",
                    f"remote_delete_dir={remote_delete_dir}",
                    f"remote_deleted_probe_file={remote_deleted_probe_file}",
                    f"remote_keep_file={remote_keep_file}",
                    f"seed_returncode={seed_result.returncode}",
                    f"option_change_returncode={option_change_result.returncode}",
                    f"blocked_returncode={blocked_result.returncode}",
                    f"blocked_verify_returncode={blocked_verify_result.returncode}",
                    f"forced_returncode={forced_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"verify_attempts={verify_attempts}",
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
            str(verify_retry_manifest_file),
            str(metadata_file),
        ]
        details = {
            "seed_returncode": seed_result.returncode,
            "option_change_returncode": option_change_result.returncode,
            "blocked_returncode": blocked_result.returncode,
            "blocked_verify_returncode": blocked_verify_result.returncode,
            "forced_returncode": forced_result.returncode,
            "verify_returncode": verify_result.returncode,
            "verify_attempts": verify_attempts,
        }

        for label, rc in [
            ("blocked verify", blocked_verify_result.returncode),
            ("forced sync", forced_result.returncode),
            ("verify", verify_result.returncode),
        ]:
            if rc != 0:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} phase failed with status {rc}",
                    artifacts,
                    details,
                )

        safeguard_markers = [
            "ERROR: An attempt to remove a large volume of data from OneDrive has been detected",
            "ERROR: The total number of items being deleted is:",
            "ERROR: To delete a large volume of data use --force",
        ]
        if not all(marker in blocked_output for marker in safeguard_markers):
            return self.fail_result(
                self.case_id,
                self.name,
                "Blocked sync did not emit the expected big delete safeguard warning",
                artifacts,
                details,
            )

        # Before --force, the deleted directory and probe file must still exist remotely
        if remote_delete_dir not in blocked_remote_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote delete directory was modified before forced acknowledgement",
                artifacts,
                details,
            )

        if remote_deleted_probe_file not in blocked_remote_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{remote_deleted_probe_file} was modified before forced acknowledgement",
                artifacts,
                details,
            )

        if remote_keep_file not in blocked_remote_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                "Keep content disappeared during blocked safeguard processing",
                artifacts,
                details,
            )

        # After --force, deleted directory must be gone, sibling content must remain
        if remote_delete_dir in remote_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                "Delete directory still exists online after acknowledged forced delete",
                artifacts,
                details,
            )

        if remote_deleted_probe_file in remote_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{remote_deleted_probe_file} still exists online after acknowledged forced delete",
                artifacts,
                details,
            )

        if remote_keep_file not in remote_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                "Keep content disappeared during big delete safeguard processing",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)