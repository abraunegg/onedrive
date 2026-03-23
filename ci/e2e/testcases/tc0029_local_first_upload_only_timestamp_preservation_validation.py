from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0029LocalFirstUploadOnlyTimestampPreservationValidation(E2ETestCase):
    case_id = "0029"
    name = "local_first upload_only timestamp preservation validation"
    description = (
        "Validate that --local-first --upload-only uploads local content without "
        "rewriting local file timestamps from Microsoft API response data"
    )

    FIXED_MTIME_INITIAL = 1577882096  # 2020-01-01 12:34:56 UTC
    FIXED_MTIME_UPDATED = 1577968496  # 2020-01-02 12:34:56 UTC

    def _write_config(self, config_path: Path, sync_dir: Path) -> None:
        content = (
            "# tc0029 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'upload_only = "true"\n'
            'local_first = "true"\n'
            'cleanup_local_files = "false"\n'
            'bypass_data_preservation = "false"\n'
        )
        write_text_file(config_path, content)

    def _set_file_mtime(self, path: Path, epoch_seconds: int) -> None:
        os.utime(path, (epoch_seconds, epoch_seconds))

    def _file_stat_snapshot(self, path: Path) -> dict[str, object]:
        stat_data = path.stat()
        return {
            "mtime": int(stat_data.st_mtime),
            "size": stat_data.st_size,
        }

    def _assert_local_file_state(
        self,
        path: Path,
        expected_content: str,
        expected_mtime: int,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        if not path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} did not leave the expected local file in place",
                artifacts,
                details,
            )

        actual_content = path.read_text(encoding="utf-8")
        actual_mtime = int(path.stat().st_mtime)

        details[f"{phase_name}_actual_content"] = actual_content
        details[f"{phase_name}_actual_mtime"] = actual_mtime
        details[f"{phase_name}_expected_content"] = expected_content
        details[f"{phase_name}_expected_mtime"] = expected_mtime

        if actual_content != expected_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local file content unexpectedly",
                artifacts,
                details,
            )

        if actual_mtime != expected_mtime:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local file timestamp unexpectedly",
                artifacts,
                details,
            )

        return None

    def _assert_no_download_activity(
        self,
        stdout_text: str,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        unexpected_markers = [
            "Downloading file:",
            "Creating local directory",
        ]
        for marker in unexpected_markers:
            if marker in stdout_text:
                details[f"{phase_name}_unexpected_download_marker"] = marker
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{phase_name} showed unexpected download-side local reconciliation activity in upload-only mode",
                    artifacts,
                    details,
                )
        return None

    def _assert_no_upload_activity(
        self,
        stdout_text: str,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        unexpected_markers = [
            "Uploading new file:",
            "Uploading modified file:",
            "Uploading file:",
        ]
        for marker in unexpected_markers:
            if marker in stdout_text:
                details[f"{phase_name}_unexpected_upload_marker"] = marker
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{phase_name} unexpectedly attempted another upload despite no local changes",
                    artifacts,
                    details,
                )
        return None

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0029"
        case_log_dir = context.logs_dir / "tc0029"
        state_dir = context.state_dir / "tc0029"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        conf_dir = case_work_dir / "conf"
        reset_directory(sync_root)

        context.bootstrap_config_dir(conf_dir)
        self._write_config(conf_dir / "config", sync_root)

        root_name = f"ZZ_E2E_TC0029_{context.run_id}_{os.getpid()}"
        relative_file = f"{root_name}/timestamp-probe.txt"
        local_file = sync_root / relative_file

        initial_content = (
            "TC0029 initial content\n"
            "This file is uploaded with --upload-only --local-first.\n"
        )
        updated_content = (
            "TC0029 updated content\n"
            "This file is uploaded again with a newer local timestamp.\n"
        )

        phase1_stdout = case_log_dir / "phase1_initial_upload_stdout.log"
        phase1_stderr = case_log_dir / "phase1_initial_upload_stderr.log"
        phase2_stdout = case_log_dir / "phase2_modified_upload_stdout.log"
        phase2_stderr = case_log_dir / "phase2_modified_upload_stderr.log"
        phase3_stdout = case_log_dir / "phase3_noop_sync_stdout.log"
        phase3_stderr = case_log_dir / "phase3_noop_sync_stderr.log"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(phase3_stdout),
            str(phase3_stderr),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "root_name": root_name,
            "relative_file": relative_file,
        }

        # Phase 1: create the initial file, set a fixed local timestamp, and upload it.
        write_text_file(local_file, initial_content)
        self._set_file_mtime(local_file, self.FIXED_MTIME_INITIAL)
        phase1_before = self._file_stat_snapshot(local_file)

        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--upload-only",
            "--local-first",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_dir),
        ]
        context.log(f"Executing Test Case {self.case_id} phase1: {command_to_string(phase1_command)}")
        phase1_result = run_command(phase1_command, cwd=context.repo_root)
        write_text_file(phase1_stdout, phase1_result.stdout)
        write_text_file(phase1_stderr, phase1_result.stderr)
        phase1_after = self._file_stat_snapshot(local_file)

        details["phase1_returncode"] = phase1_result.returncode
        details["phase1_before"] = phase1_before
        details["phase1_after"] = phase1_after

        if phase1_result.returncode != 0:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"initial upload phase failed with status {phase1_result.returncode}",
                artifacts,
                details,
            )

        failure = self._assert_no_download_activity(
            phase1_result.stdout,
            "Initial upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_file_state(
            local_file,
            initial_content,
            self.FIXED_MTIME_INITIAL,
            "Initial upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        # Phase 2: modify the local file, set a newer fixed local timestamp, and upload again.
        time.sleep(2)
        write_text_file(local_file, updated_content)
        self._set_file_mtime(local_file, self.FIXED_MTIME_UPDATED)
        phase2_before = self._file_stat_snapshot(local_file)

        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--upload-only",
            "--local-first",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_dir),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2: {command_to_string(phase2_command)}")
        phase2_result = run_command(phase2_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)
        phase2_after = self._file_stat_snapshot(local_file)

        details["phase2_returncode"] = phase2_result.returncode
        details["phase2_before"] = phase2_before
        details["phase2_after"] = phase2_after

        if phase2_result.returncode != 0:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"modified upload phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        failure = self._assert_no_download_activity(
            phase2_result.stdout,
            "Modified upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_file_state(
            local_file,
            updated_content,
            self.FIXED_MTIME_UPDATED,
            "Modified upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        # Phase 3: run again with no local changes; the local file must remain untouched.
        time.sleep(2)
        phase3_before = self._file_stat_snapshot(local_file)

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--upload-only",
            "--local-first",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_dir),
        ]
        context.log(f"Executing Test Case {self.case_id} phase3: {command_to_string(phase3_command)}")
        phase3_result = run_command(phase3_command, cwd=context.repo_root)
        write_text_file(phase3_stdout, phase3_result.stdout)
        write_text_file(phase3_stderr, phase3_result.stderr)
        phase3_after = self._file_stat_snapshot(local_file)

        details["phase3_returncode"] = phase3_result.returncode
        details["phase3_before"] = phase3_before
        details["phase3_after"] = phase3_after

        if phase3_result.returncode != 0:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"no-op sync phase failed with status {phase3_result.returncode}",
                artifacts,
                details,
            )

        failure = self._assert_no_download_activity(
            phase3_result.stdout,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_file_state(
            local_file,
            updated_content,
            self.FIXED_MTIME_UPDATED,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_no_upload_activity(
            phase3_result.stdout,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)