from __future__ import annotations

import os
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0060MonitorModeLocalMoveNoDeleteReupload(MonitorModeTestCaseBase):
    case_id = "0060"
    name = "monitor mode local move without delete re-upload"
    description = (
        "Start --monitor, move in-sync local files and directories within the sync tree, "
        "and validate they are propagated as moves rather than delete/re-upload operations"
    )

    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"

    def _build_monitor_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        return self._build_config_text(
            sync_dir,
            app_log_dir,
            extra_config_lines=[
                # This testcase is specifically validating local inotify IN_MOVED_* handling.
                # Keep WebSocket disabled so remote notification timing does not mask or race
                # the local monitor event path under test.
                'disable_websocket_support = "true"',
            ],
        )

    def _build_verify_config_text(self, sync_dir: Path) -> str:
        return (
            "# tc0060 verify config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

    def _read_text_file(self, path: Path) -> str:
        if not path.exists():
            return ""
        try:
            return path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def _wait_for_stdout_growth_patterns(
        self,
        stdout_file: Path,
        *,
        start_offset: int,
        required_patterns: list[str],
        timeout_seconds: int = 180,
        poll_interval: float = 0.5,
    ) -> tuple[bool, str]:
        deadline = time.time() + timeout_seconds
        latest_segment = ""

        while time.time() < deadline:
            content = self._read_stdout(stdout_file)
            latest_segment = content[start_offset:]
            if all(pattern in latest_segment for pattern in required_patterns):
                return True, latest_segment
            time.sleep(poll_interval)

        return False, latest_segment

    def _contains_bad_move_side_effects(self, log_segment: str) -> list[str]:
        bad_markers = [
            "Trying to delete this item as requested:",
            "The local item has been deleted:",
            "Uploading new file:",
            "Uploading changed file:",
        ]
        return [marker for marker in bad_markers if marker in log_segment]

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0060",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0060_{context.run_id}_{os.getpid()}"

        file_source_relative = f"{root_name}/FileSource/move-me.txt"
        file_destination_relative = f"{root_name}/FileDestination/move-me.txt"
        file_destination_anchor_relative = f"{root_name}/FileDestination/anchor.txt"

        dir_source_relative = f"{root_name}/Pictures/2005"
        dir_destination_relative = f"{root_name}/Pictures/Year/2005"
        dir_destination_parent_anchor_relative = f"{root_name}/Pictures/Year/anchor.txt"
        dir_file_relative_paths = [
            f"{dir_source_relative}/photo-root-001.txt",
            f"{dir_source_relative}/photo-root-002.txt",
            f"{dir_source_relative}/nested/photo-nested-001.txt",
            f"{dir_source_relative}/nested/deeper/photo-deeper-001.txt",
        ]

        file_source_path = sync_root / file_source_relative
        file_destination_path = sync_root / file_destination_relative
        file_destination_anchor_path = sync_root / file_destination_anchor_relative
        dir_source_path = sync_root / dir_source_relative
        dir_destination_path = sync_root / dir_destination_relative
        dir_destination_parent_anchor_path = sync_root / dir_destination_parent_anchor_relative

        file_destination_verify_path = verify_root / file_destination_relative
        file_source_verify_path = verify_root / file_source_relative
        dir_source_verify_path = verify_root / dir_source_relative
        dir_destination_verify_path = verify_root / dir_destination_relative

        file_content = (
            "TC0060 monitor local file move validation\n"
            "This file must be moved remotely, not deleted and re-uploaded.\n"
        )
        file_anchor_content = "TC0060 destination directory anchor for file move\n"
        dir_anchor_content = "TC0060 destination parent anchor for directory move\n"
        dir_file_contents = {
            dir_file_relative_paths[0]: "TC0060 root photo 001\n",
            dir_file_relative_paths[1]: "TC0060 root photo 002\n",
            dir_file_relative_paths[2]: "TC0060 nested photo 001\n",
            dir_file_relative_paths[3]: "TC0060 deeper nested photo 001\n",
        }

        context.prepare_minimal_config_dir(
            conf_main,
            self._build_monitor_config_text(sync_root, app_log_dir),
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            self._build_verify_config_text(verify_root),
        )

        write_text_file(file_source_path, file_content)
        write_text_file(file_destination_anchor_path, file_anchor_content)
        write_text_file(dir_destination_parent_anchor_path, dir_anchor_content)
        for relative_path, content in dir_file_contents.items():
            write_text_file(sync_root / relative_path, content)

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        monitor_manifest_file = state_dir / "monitor_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(monitor_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
            str(app_log_dir),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "file_source_relative": file_source_relative,
            "file_destination_relative": file_destination_relative,
            "dir_source_relative": dir_source_relative,
            "dir_destination_relative": dir_destination_relative,
            "dir_file_relative_paths": dir_file_relative_paths,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
            "websocket_disabled": True,
        }

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")

        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            startup_timeout_seconds=300,
        )

        mutation_processed = False
        post_mutation_log_segment = ""
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor process did not complete initial sync before local moves",
                    artifacts,
                    details,
                )

            initial_stdout = self._read_stdout(monitor_stdout)
            mutation_log_start_offset = len(initial_stdout)
            details["mutation_log_start_offset"] = mutation_log_start_offset
            details["initial_sync_complete_count_before_moves"] = initial_stdout.count(self.SYNC_COMPLETE_PATTERN)

            context.log(f"Test Case {self.case_id}: moving in-sync local file: {file_source_relative} -> {file_destination_relative}")
            file_destination_path.parent.mkdir(parents=True, exist_ok=True)
            file_source_path.rename(file_destination_path)

            context.log(f"Test Case {self.case_id}: moving in-sync local directory tree: {dir_source_relative} -> {dir_destination_relative}")
            dir_destination_path.parent.mkdir(parents=True, exist_ok=True)
            dir_source_path.rename(dir_destination_path)

            details["file_source_exists_after_local_move"] = file_source_path.exists()
            details["file_destination_exists_after_local_move"] = file_destination_path.is_file()
            details["dir_source_exists_after_local_move"] = dir_source_path.exists()
            details["dir_destination_exists_after_local_move"] = dir_destination_path.is_dir()

            required_patterns = [
                f"[M] Local item moved: {file_source_relative} -> {file_destination_relative}",
                f"Moving {file_source_relative} to {file_destination_relative}",
                f"[M] Local item moved: {dir_source_relative} -> {dir_destination_relative}",
                f"Moving {dir_source_relative} to {dir_destination_relative}",
            ]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=180,
            )
            details["mutation_processed"] = mutation_processed
            details["mutation_required_patterns"] = required_patterns
            details["post_mutation_bad_markers"] = self._contains_bad_move_side_effects(post_mutation_log_segment)
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
        finally:
            self._shutdown_monitor_process(process, details)

        monitor_manifest = build_manifest(sync_root)
        write_manifest(monitor_manifest_file, monitor_manifest)

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

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)

        expected_destination_dir_files = [
            relative_path.replace(dir_source_relative, dir_destination_relative, 1)
            for relative_path in dir_file_relative_paths
        ]
        details["expected_destination_dir_files"] = expected_destination_dir_files
        details["verify_file_source_exists"] = file_source_verify_path.exists()
        details["verify_file_destination_exists"] = file_destination_verify_path.is_file()
        details["verify_file_destination_content"] = (
            file_destination_verify_path.read_text(encoding="utf-8")
            if file_destination_verify_path.is_file()
            else ""
        )
        details["verify_dir_source_exists"] = dir_source_verify_path.exists()
        details["verify_dir_destination_exists"] = dir_destination_verify_path.is_dir()
        details["verify_destination_dir_files_exist"] = {
            relative_path: (verify_root / relative_path).is_file()
            for relative_path in expected_destination_dir_files
        }
        details["verify_destination_dir_file_contents"] = {
            relative_path: (
                (verify_root / relative_path).read_text(encoding="utf-8")
                if (verify_root / relative_path).is_file()
                else ""
            )
            for relative_path in expected_destination_dir_files
        }

        self._write_metadata(metadata_file, details)

        if not mutation_processed:
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor process did not log both local move operations before shutdown",
                artifacts,
                details,
            )

        bad_markers = details.get("post_mutation_bad_markers", [])
        if bad_markers:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Monitor move processing logged delete/re-upload side effects after local moves: {bad_markers}",
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

        if file_source_verify_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains original file move source: {file_source_relative}",
                artifacts,
                details,
            )

        if not file_destination_verify_path.is_file() or details["verify_file_destination_content"] != file_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote verification did not preserve moved file at the destination path with expected content",
                artifacts,
                details,
            )

        if dir_source_verify_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains original directory move source: {dir_source_relative}",
                artifacts,
                details,
            )

        if not dir_destination_verify_path.is_dir():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing moved directory destination: {dir_destination_relative}",
                artifacts,
                details,
            )

        missing_dir_files = [
            relative_path
            for relative_path, exists in details["verify_destination_dir_files_exist"].items()
            if not exists
        ]
        if missing_dir_files:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing moved directory descendant files: {missing_dir_files}",
                artifacts,
                details,
            )

        content_mismatches = []
        for source_relative, expected_content in dir_file_contents.items():
            destination_relative = source_relative.replace(dir_source_relative, dir_destination_relative, 1)
            actual_content = details["verify_destination_dir_file_contents"].get(destination_relative, "")
            if actual_content != expected_content:
                content_mismatches.append(destination_relative)
        if content_mismatches:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification found moved directory descendant content mismatches: {content_mismatches}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
