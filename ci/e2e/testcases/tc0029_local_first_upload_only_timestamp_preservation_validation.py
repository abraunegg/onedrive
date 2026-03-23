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

        if actual_content != expected_content:
            details[f"{phase_name}_actual_content"] = actual_content
            details[f"{phase_name}_expected_content"] = expected_content
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local file content unexpectedly",
                artifacts,
                details,
            )

        if actual_mtime != expected_mtime:
            details[f"{phase_name}_actual_mtime"] = actual_mtime
            details[f"{phase_name}_expected_mtime"] = expected_mtime
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local file timestamp unexpectedly",
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

        write_text_file(local_file, initial_content)
        self._set_file_mtime(local_file, self.FIXED_MTIME_INITIAL)
        initial_before = self._file_stat_snapshot(local_file)

        phase1_stdout = case_log_dir / "phase1_initial_upload_stdout.log"
        phase1_stderr = case_log_dir / "phase1_initial_upload_stderr.log"
        phase2_stdout = case_log_dir / "phase2_modified_upload_stdout.log"
        phase2_stderr = case_log_dir / "phase2_modified_upload_stderr.log"
        phase3_stdout = case_log_dir / "phase3_noop_sync_stdout.log"
        phase3_stderr = case_log_dir / "phase3_noop_sync_stderr.log"
        metadata_file = state_dir / "metadata.txt"

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

        # Phase 2: change local content, set a newer fixed local timestamp, upload again
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

        # Phase 3: run again with no local changes; the local file must remain untouched
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
            "phase1_returncode": phase1_result.returncode,
            "phase2_returncode": phase2_result.returncode,
            "phase3_returncode": phase3_result.returncode,
            "phase1_before": initial_before,
            "phase1_after": phase1_after,
            "phase2_before": phase2_before,
            "phase2_after": phase2_after,
            "phase3_before": phase3_before,
            "phase3_after": phase3_after,
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"relative_file={relative_file}",
                    f"phase1_returncode={phase1_result.returncode}",
                    f"phase2_returncode={phase2_result.returncode}",
                    f"phase3_returncode={phase3_result.returncode}",
                    f"phase1_before={initial_before!r}",
                    f"phase1_after={phase1_after!r}",
                    f"phase2_before={phase2_before!r}",
                    f"phase2_after={phase2_after!r}",
                    f"phase3_before={phase3_before!r}",
                    f"phase3_after={phase3_after!r}",
                ]
            )
            + "\n",
        )

        for label, result in [
            ("initial upload phase", phase1_result),
            ("modified upload phase", phase2_result),
            ("no-op sync phase", phase3_result),
        ]:
            if result.returncode != 0:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} failed with status {result.returncode}",
                    artifacts,
                    details,
                )

        # Upload-only mode should not perform download actions back to the local filesystem.
        for label, stdout_text in [
            ("phase1", phase1_result.stdout),
            ("phase2", phase2_result.stdout),
            ("phase3", phase3_result.stdout),
        ]:
            if "Downloading file:" in stdout_text or "Creating local directory" in stdout_text:
                details[f"{label}_unexpected_download_activity"] = True
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} showed unexpected download-side local reconciliation activity in upload-only mode",
                    artifacts,
                    details,
                )

        failure = self._assert_local_file_state(
            local_file,
            initial_content,
            self.FIXED_MTIME_INITIAL,
            "Initial upload phase",
            artifacts,
            details,
        )
        if failure is not None:
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
            return failure

        # Phase 3 should not upload again when nothing changed locally.
        phase3_upload_markers = [
            "Uploading new file:",
            "Uploading modified file:",
            "Uploading file:",
        ]
        if any(marker in phase3_result.stdout for marker in phase3_upload_markers):
            details["phase3_unexpected_upload_activity"] = True
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "No-op sync phase unexpectedly attempted another upload despite no local changes",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)