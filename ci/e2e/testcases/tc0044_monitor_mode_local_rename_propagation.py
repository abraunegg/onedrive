from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, rename_xlsx_pair, large_xlsx_relative, xlsx_pair_any_exists, xlsx_pair_all_files
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0044MonitorModeLocalRenamePropagation(MonitorModeTestCaseBase):
    case_id = "0044"
    name = "monitor mode local rename propagation"
    description = "Rename passive TXT and real XLSX files while --monitor is active and validate correct behaviour"

    XLSX_PAYLOAD_ROWS = 32

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _build_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        return (
            "# tc0044 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n'
        )

    def _read_stdout(self, stdout_file: Path) -> str:
        if not stdout_file.exists():
            return ""
        try:
            return stdout_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def _wait_for_initial_sync_complete(
        self,
        stdout_file: Path,
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds
        marker = "Sync with Microsoft OneDrive is complete"

        while time.time() < deadline:
            if marker in self._read_stdout(stdout_file):
                return True
            time.sleep(poll_interval)

        return False

    def _wait_for_monitor_patterns(
        self,
        stdout_file: Path,
        required_patterns: list[str],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            content = self._read_stdout(stdout_file)
            if all(self._monitor_output_contains(content, pattern) for pattern in required_patterns):
                return True
            time.sleep(poll_interval)

        return False

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0044",
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

        root_name = f"ZZ_E2E_TC0044_{context.run_id}_{os.getpid()}"
        old_relative = f"{root_name}/original-name.xlsx"
        new_relative = f"{root_name}/renamed-file.xlsx"
        old_text_relative = f"{root_name}/original-name.txt"
        new_text_relative = f"{root_name}/renamed-file.txt"

        old_local_path = sync_root / old_relative
        new_local_path = sync_root / new_relative
        old_text_local_path = sync_root / old_text_relative
        new_text_local_path = sync_root / new_text_relative
        old_verify_path = verify_root / old_relative
        new_verify_path = verify_root / new_relative
        old_text_verify_path = verify_root / old_text_relative
        new_text_verify_path = verify_root / new_text_relative

        file_content = (
            "TC0044 monitor mode local rename propagation\n"
            "This content must survive the rename unchanged.\n"
        )
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0044:{os.getpid()}"

        context.bootstrap_config_dir(conf_main)
        write_text_file(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        context.bootstrap_config_dir(conf_verify)
        write_text_file(
            conf_verify / "config",
            (
                "# tc0044 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        details: dict[str, object] = {
            "root_name": root_name,
            "old_relative": old_relative,
            "new_relative": new_relative,
            "old_text_relative": old_text_relative,
            "new_text_relative": new_text_relative,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
        }

        generated = create_random_xlsx_pair(
            old_local_path,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0044 monitor local rename propagation workbook",
        )
        details["generated_size"] = int(generated["size_bytes"])
        write_text_file(old_text_local_path, file_content)

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode

        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        settled_validation_error = validate_xlsx_pair(old_local_path, REVISION_0)
        details["settled_validation_error"] = settled_validation_error
        if settled_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seeded XLSX was invalid after initial sync: {settled_validation_error}",
                artifacts,
                details,
            )

        settled_text_content = old_text_local_path.read_text(encoding="utf-8") if old_text_local_path.is_file() else ""
        details["settled_text_content"] = settled_text_content
        if settled_text_content != file_content:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Seeded passive TXT content changed during initial sync",
                artifacts,
                details,
            )

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
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
        )
        try:
            details["initial_sync_complete"] = initial_sync_complete

            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor mode did not complete the initial sync within the expected time",
                    artifacts,
                    details,
                )

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            context.log(
                f"Test Case {self.case_id}: renaming local files while monitor is running: "
                f"{old_relative} -> {new_relative}; {old_text_relative} -> {new_text_relative}"
            )
            rename_xlsx_pair(old_local_path, new_local_path)
            old_text_local_path.rename(new_text_local_path)
            details["old_local_exists_after_rename"] = xlsx_pair_any_exists(old_local_path)
            details["new_local_exists_after_rename"] = xlsx_pair_all_files(new_local_path)
            details["old_text_local_exists_after_rename"] = old_text_local_path.exists()
            details["new_text_local_exists_after_rename"] = new_text_local_path.is_file()

            xlsx_variant_groups = []
            for old_xlsx_relative, new_xlsx_relative in (
                (old_relative, new_relative),
                (large_xlsx_relative(old_relative), large_xlsx_relative(new_relative)),
            ):
                xlsx_variant_groups.append([
                    [
                        f"[M] Local item moved: {old_xlsx_relative} -> {new_xlsx_relative}",
                        f"Moving {old_xlsx_relative} to {new_xlsx_relative}",
                    ],
                    [f"Uploading new file: {new_xlsx_relative} ... done"],
                ])
            text_groups = [
                [
                    f"[M] Local item moved: {old_text_relative} -> {new_text_relative}",
                    f"Moving {old_text_relative} to {new_text_relative}",
                ],
                [f"Uploading new file: {new_text_relative} ... done"],
            ]
            pattern_groups = [
                small_group + large_group + text_group
                for small_group in xlsx_variant_groups[0]
                for large_group in xlsx_variant_groups[1]
                for text_group in text_groups
            ]
            mutation_processed, matched_group, post_mutation_log_segment = self._wait_for_any_stdout_growth_pattern_group(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                alternative_pattern_groups=pattern_groups,
                timeout_seconds=180,
            )
            post_mutation_sync_complete = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["post_mutation_sync_complete"] = post_mutation_sync_complete
            details["mutation_processed"] = mutation_processed
            details["matched_pattern_group_index"] = matched_group
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_pattern_groups"] = pattern_groups
        finally:
            self._shutdown_monitor_process(process, details)

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

        details["verify_old_exists"] = old_verify_path.exists()
        details["verify_new_exists"] = new_verify_path.is_file()
        details["verify_old_text_exists"] = old_text_verify_path.exists()
        details["verify_new_text_exists"] = new_text_verify_path.is_file()
        details["verify_new_text_content"] = (
            new_text_verify_path.read_text(encoding="utf-8")
            if new_text_verify_path.is_file()
            else ""
        )
        verify_validation_error = (
            validate_xlsx_pair(new_verify_path, REVISION_0)
            if new_verify_path.is_file()
            else "Verification XLSX is missing"
        )
        details["verify_validation_error"] = verify_validation_error

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if old_verify_path.exists() or old_text_verify_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote verification still contains one or more old filenames after rename",
                artifacts,
                details,
            )

        if not new_verify_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing renamed file: {new_relative}",
                artifacts,
                details,
            )

        if verify_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification returned an invalid or stale XLSX workbook: {verify_validation_error}",
                artifacts,
                details,
            )

        if not new_text_verify_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing renamed passive TXT file: {new_text_relative}",
                artifacts,
                details,
            )

        if details["verify_new_text_content"] != file_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Renamed passive TXT content did not match after remote verification",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
