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

        seed_root = case_work_dir / "seedroot"
        local_root = case_work_dir / "localroot"
        verify_root = case_work_dir / "verifyroot"

        conf_seed = case_work_dir / "conf-seed"
        conf_local = case_work_dir / "conf-local"
        conf_verify = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0024_{context.run_id}_{os.getpid()}"
        delete_dir_name = "DeleteDirectory"
        keep_dir_name = "KeepDirectory"
        classify_threshold = 5
        delete_file_count = 10

        delete_dir_relative = f"{root_name}/{delete_dir_name}"
        keep_file_relative = f"{root_name}/{keep_dir_name}/keep.txt"
        delete_dir_local = local_root / root_name / delete_dir_name

        reset_directory(seed_root)
        reset_directory(local_root)
        reset_directory(verify_root)

        # Seed content:
        # - one populated directory that will later be removed entirely
        # - one separate keep directory that must remain untouched
        for index in range(delete_file_count):
            write_text_file(
                seed_root / root_name / delete_dir_name / f"file{index}.data",
                f"delete-candidate-{index}\n",
            )

        write_text_file(
            seed_root / root_name / keep_dir_name / "keep.txt",
            "keep\n",
        )

        context.bootstrap_config_dir(conf_seed)
        self._write_config(conf_seed / "config", seed_root, None)

        context.bootstrap_config_dir(conf_local)
        self._write_config(conf_local / "config", local_root, classify_threshold)

        context.bootstrap_config_dir(conf_verify)
        self._write_config(conf_verify / "config", verify_root, classify_threshold)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"

        download_stdout = case_log_dir / "download_stdout.log"
        download_stderr = case_log_dir / "download_stderr.log"

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

        # Step 1:
        # Upload the baseline content without relying on the safeguard setting.
        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seed),
        ]
        seed_result = self._run_and_capture(
            context,
            "seed",
            seed_command,
            seed_stdout,
            seed_stderr,
        )

        # Step 2:
        # Download to a separate working tree using a config that has
        # classify_as_big_delete enabled at a low threshold.
        download_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        download_result = self._run_and_capture(
            context,
            "download",
            download_command,
            download_stdout,
            download_stderr,
        )

        # Step 2b:
        # Perform a normal sync with the updated config before any deletion,
        # mirroring the manual validation sequence where the option change is
        # applied and confirmed before removing data.
        option_change_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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

        # Confirm the local working copy contains the populated delete directory
        # and the keep content before removing anything.
        missing_local_items: list[str] = []

        if not delete_dir_local.is_dir():
            missing_local_items.append(delete_dir_relative)

        for index in range(delete_file_count):
            candidate = delete_dir_local / f"file{index}.data"
            if not candidate.is_file():
                missing_local_items.append(f"{delete_dir_relative}/file{index}.data")

        if not (local_root / root_name / keep_dir_name / "keep.txt").is_file():
            missing_local_items.append(keep_file_relative)

        if missing_local_items:
            write_text_file(
                metadata_file,
                "\n".join(
                    [
                        f"case_id={self.case_id}",
                        f"root_name={root_name}",
                        f"seed_returncode={seed_result.returncode}",
                        f"download_returncode={download_result.returncode}",
                        f"option_change_returncode={option_change_result.returncode}",
                        f"missing_local_items={missing_local_items!r}",
                    ]
                )
                + "\n",
            )

            artifacts = [
                str(seed_stdout),
                str(seed_stderr),
                str(download_stdout),
                str(download_stderr),
                str(option_change_stdout),
                str(option_change_stderr),
                str(metadata_file),
            ]
            details = {
                "seed_returncode": seed_result.returncode,
                "download_returncode": download_result.returncode,
                "option_change_returncode": option_change_result.returncode,
                "root_name": root_name,
            }

            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Expected local baseline content was not downloaded before delete phase",
                artifacts,
                details,
            )

        # Step 3:
        # Remove the entire populated directory locally. This matches the
        # proven working application path for classify_as_big_delete.
        if delete_dir_local.exists():
            shutil.rmtree(delete_dir_local)

        blocked_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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

        blocked_output = (blocked_result.stdout + "\n" + blocked_result.stderr).lower()

        # Verify that the remote directory still exists after the blocked sync.
        reset_directory(verify_root)
        blocked_verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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

        # Step 4:
        # Re-run with --force and confirm the deletion is then allowed.
        forced_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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
        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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
                    f"seed_root={seed_root}",
                    f"local_root={local_root}",
                    f"verify_root={verify_root}",
                    f"seed_confdir={conf_seed}",
                    f"local_confdir={conf_local}",
                    f"verify_confdir={conf_verify}",
                    f"classify_as_big_delete={classify_threshold}",
                    f"delete_dir_relative={delete_dir_relative}",
                    f"delete_file_count={delete_file_count}",
                    f"keep_file_relative={keep_file_relative}",
                    f"seed_returncode={seed_result.returncode}",
                    f"download_returncode={download_result.returncode}",
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
            str(download_stdout),
            str(download_stderr),
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
            "download_returncode": download_result.returncode,
            "option_change_returncode": option_change_result.returncode,
            "blocked_returncode": blocked_result.returncode,
            "blocked_verify_returncode": blocked_verify_result.returncode,
            "forced_returncode": forced_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        for label, rc in [
            ("seed", seed_result.returncode),
            ("download", download_result.returncode),
            ("option change validation", option_change_result.returncode),
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

        # The blocked sync must emit the safeguard warning / forced acknowledgement requirement.
        safeguard_markers = [
            "large volume of data",
            "the total number of items being deleted is",
            "classify_as_big_delete",
            "--force",
        ]
        if not any(marker in blocked_output for marker in safeguard_markers):
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Blocked sync did not emit a big delete safeguard warning",
                artifacts,
                details,
            )

        # Before --force, the remotely seeded delete directory must still exist.
        if delete_dir_relative not in blocked_remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Remote delete directory was modified before forced acknowledgement",
                artifacts,
                details,
            )

        for index in range(delete_file_count):
            relative_path = f"{delete_dir_relative}/file{index}.data"
            if relative_path not in blocked_remote_manifest:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{relative_path} was modified before forced acknowledgement",
                    artifacts,
                    details,
                )

        if keep_file_relative not in blocked_remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Keep content disappeared during blocked safeguard processing",
                artifacts,
                details,
            )

        # After --force, the entire delete directory must be gone remotely.
        if delete_dir_relative in remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Delete directory still exists online after acknowledged forced delete",
                artifacts,
                details,
            )

        for index in range(delete_file_count):
            relative_path = f"{delete_dir_relative}/file{index}.data"
            if relative_path in remote_manifest:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{relative_path} still exists online after acknowledged forced delete",
                    artifacts,
                    details,
                )

        if keep_file_relative not in remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Keep content disappeared during big delete safeguard processing",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)