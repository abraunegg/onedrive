from __future__ import annotations

import os
import threading
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0056MonitorModeCreateThenDeleteQuickly(MonitorModeTestCaseBase):
    case_id = "0056"
    name = "monitor mode create then delete quickly"
    description = (
        "Validate rapid local create/delete and continued monitor watch registration "
        "when short-lived entries disappear during directory traversal"
    )

    # Issue #3940: actual readdir()/stat() timing is not guaranteed on every CI run.
    WATCH_RACE_ROUNDS = 3
    WATCH_RACE_SIBLINGS = 3
    WATCH_RACE_CHURN_FILES = 1500
    WATCH_RACE_RECOVERY_MARKER = "Skipping vanished entry during directory traversal:"

    @staticmethod
    def _directory_has_inotify_watch(pid: int, directory: Path) -> bool:
        """Inspect the watch on a directory inode, as in TC0060 (Linux CI)."""
        try:
            inode = directory.stat().st_ino
            fd_root = Path(f"/proc/{pid}/fd")
            for fd in fd_root.iterdir():
                try:
                    if os.readlink(fd) != "anon_inode:inotify":
                        continue
                    fdinfo = Path(f"/proc/{pid}/fdinfo/{fd.name}")
                    for line in fdinfo.read_text(encoding="utf-8", errors="replace").splitlines():
                        if not line.startswith("inotify "):
                            continue
                        for field in line.split():
                            if field.startswith("ino:"):
                                try:
                                    if int(field[4:], 16) == inode:
                                        return True
                                except ValueError:
                                    continue
                except OSError:
                    continue
        except OSError:
            pass
        return False

    def _wait_for_sibling_watches(self, process, sibling_dirs: list[Path]) -> bool:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and process.poll() is None:
            if all(self._directory_has_inotify_watch(process.pid, path) for path in sibling_dirs):
                return True
            time.sleep(0.25)
        return False

    def _wait_for_patterns_or_monitor_exit(
        self, process, stdout_file: Path, start_offset: int, patterns: list[str], timeout: int = 120
    ) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and process.poll() is None:
            output = self._read_monitor_output_from_offsets(stdout_file, start_offset)
            if all(self._monitor_output_contains(output, pattern) for pattern in patterns):
                return True
            time.sleep(0.5)
        return False

    def _validate_watch_traversal_race(
        self, process, case_work_dir: Path, sync_root: Path, root_name: str,
        stdout_file: Path, details: dict[str, object]
    ) -> tuple[str | None, list[tuple[str, str]], list[str]]:
        """Exercise monitor watch registration during genuine, bounded file churn.

        Churn is performed relative to an open directory fd so it survives the
        atomic rename from staging into the watched tree. Do not require the
        timing-dependent recovery diagnostic for normal CI success.
        """
        phase_details: dict[str, object] = {}
        offset = self._prepare_monitor_for_local_mutation(process, stdout_file, phase_details)
        details["watch_race_readiness"] = phase_details
        details["watch_race_log_offset"] = offset
        details["watch_race_started"] = True
        details["watch_race_rounds_completed"] = 0
        expected_files: list[tuple[str, str]] = []
        deleted_files: list[str] = []
        for round_id in range(self.WATCH_RACE_ROUNDS):
            name = f"watch-race-{round_id:02d}"
            staging = case_work_dir / f"tc0056-{name}-staging"
            destination = sync_root / root_name / name
            staging.mkdir()
            sibling_names = [f"sibling-{index:02d}" for index in range(self.WATCH_RACE_SIBLINGS)]
            for sibling in sibling_names:
                (staging / sibling).mkdir()

            churn_done = threading.Event()
            churn_started = threading.Event()
            churn_errors: list[str] = []
            churn_count = [0]

            def churn(directory: Path = staging) -> None:
                try:
                    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        churn_started.set()
                        for number in range(self.WATCH_RACE_CHURN_FILES):
                            if churn_done.is_set():
                                break
                            filename = f"transient-{number:05d}"
                            fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory_fd)
                            os.close(fd)
                            os.unlink(filename, dir_fd=directory_fd)
                            churn_count[0] += 1
                            # Spread mutations across the initial monitor traversal.
                            if churn_done.wait(0.0005):
                                break
                    finally:
                        os.close(directory_fd)
                except OSError as error:
                    churn_errors.append(str(error))
                    churn_started.set()

            mutator = threading.Thread(target=churn, name=f"tc0056-{name}-churn")
            mutator.start()
            try:
                if not churn_started.wait(5):
                    return "Filesystem churn did not start", expected_files, deleted_files
                if churn_errors:
                    return f"Filesystem churn failed: {churn_errors[0]}", expected_files, deleted_files
                staging.rename(destination)
                # Keep entries changing while addRecursive()/traverseDirectory() run.
                mutator.join(timeout=3)
            finally:
                churn_done.set()
                mutator.join(timeout=5)
            if mutator.is_alive():
                return "Filesystem churn worker did not stop", expected_files, deleted_files
            if churn_errors:
                return f"Filesystem churn failed: {churn_errors[0]}", expected_files, deleted_files
            if churn_count[0] == 0:
                return "Filesystem churn produced no transient entries", expected_files, deleted_files

            details[f"watch_race_{round_id:02d}_churn_count"] = churn_count[0]
            if process.poll() is not None:
                return f"Monitor exited during directory traversal with status {process.returncode}", expected_files, deleted_files
            siblings = [destination / sibling for sibling in sibling_names]
            watched = self._wait_for_sibling_watches(process, siblings)
            details[f"watch_race_{round_id:02d}_sibling_watches_present"] = watched
            if not watched:
                missing = [str(path.relative_to(sync_root)) for path in siblings if not self._directory_has_inotify_watch(process.pid, path)]
                details[f"watch_race_{round_id:02d}_missing_watches"] = missing
                return f"Missing surviving sibling inotify watches: {missing}", expected_files, deleted_files

            # Only create probes after proving watches are installed. A periodic
            # full scan must not be allowed to hide missed monitor notifications.
            probes: list[str] = []
            for sibling in sibling_names:
                relative = f"{root_name}/{name}/{sibling}/probe.txt"
                payload = f"TC0056 Issue 3940 {name}/{sibling} monitor probe\n"
                write_text_file(sync_root / relative, payload)
                expected_files.append((relative, payload))
                probes.append(relative)
            uploads = [f"Uploading new file: {relative} ... done" for relative in probes]
            uploads_seen = self._wait_for_patterns_or_monitor_exit(process, stdout_file, offset, uploads)
            details[f"watch_race_{round_id:02d}_probe_uploads_seen"] = uploads_seen
            if not uploads_seen:
                return f"Monitor did not upload all surviving sibling probes in {name}", expected_files, deleted_files
            details["watch_race_rounds_completed"] = round_id + 1

        # Verify a subsequent deletion propagates from a watched child directory.
        deleted = expected_files.pop()[0]
        (sync_root / deleted).unlink()
        deleted_files.append(deleted)
        deletion_seen = self._wait_for_patterns_or_monitor_exit(
            process, stdout_file, offset, [f"Successfully deleted item from Microsoft OneDrive: {deleted}"]
        )
        details["watch_race_remote_deletion_seen"] = deletion_seen
        if not deletion_seen:
            return f"Monitor did not propagate deletion of {deleted}", expected_files, deleted_files
        details["watch_traversal_monitor_checks_passed"] = True
        if process.poll() is not None:
            return f"Monitor exited during watch traversal validation with status {process.returncode}", expected_files, deleted_files
        return None, expected_files, deleted_files

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0056",
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

        root_name = f"ZZ_E2E_TC0056_{context.run_id}_{os.getpid()}"
        anchor_relative = f"{root_name}/anchor.txt"
        transient_relative = f"{root_name}/transient.txt"

        anchor_local = sync_root / anchor_relative
        transient_local = sync_root / transient_relative
        anchor_verify = verify_root / anchor_relative
        transient_verify = verify_root / transient_relative

        transient_content = (
            "TC0056 monitor mode create then delete quickly\n"
            "This file should not remain remotely after the rapid local delete.\n"
        )

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0056 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )
        write_text_file(anchor_local, "TC0056 anchor\n")

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        details = {
            "root_name": root_name,
            "anchor_relative": anchor_relative,
            "transient_relative": transient_relative,
        }

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
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
        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        early_failure: str | None = None
        race_expected_files: list[tuple[str, str]] = []
        race_deleted_files: list[str] = []
        details["vanished_entry_recovery_exercised"] = False
        details["watch_traversal_validation_passed"] = False
        details["watch_traversal_monitor_checks_passed"] = False
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

            write_text_file(transient_local, transient_content)
            time.sleep(0.2)
            if transient_local.exists():
                transient_local.unlink()
            details["transient_exists_after_local_delete"] = transient_local.exists()

            pattern_groups = [
                [f"[M] Local item deleted: {transient_relative}"],
                [f"[M] New local file added: {transient_relative}"],
                [f"Uploading new file: {transient_relative} ... done"],
                [f"Deleting item from Microsoft OneDrive: {transient_relative}"],
            ]
            mutation_processed, matched_group, post_mutation_log_segment = self._wait_for_any_stdout_growth_pattern_group(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                alternative_pattern_groups=pattern_groups,
                timeout_seconds=60,
            )
            details["post_mutation_sync_complete"] = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["mutation_processed"] = mutation_processed
            details["matched_pattern_group_index"] = matched_group
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_pattern_groups"] = pattern_groups
            if process.poll() is not None:
                early_failure = f"Monitor process exited before shutdown with status {process.returncode} after transient create/delete workflow"

            details["monitor_observed_new_file"] = self._monitor_output_contains(
                post_mutation_log_segment,
                f"[M] New local file added: {transient_relative}",
            )
            details["monitor_observed_delete"] = self._monitor_output_contains(
                post_mutation_log_segment,
                f"[M] Local item deleted: {transient_relative}",
            )
            details["monitor_observed_upload"] = self._monitor_output_contains(
                post_mutation_log_segment,
                f"Uploading new file: {transient_relative} ... done",
            )
            details["monitor_observed_remote_delete"] = self._monitor_output_contains(
                post_mutation_log_segment,
                f"Deleting item from Microsoft OneDrive: {transient_relative}",
            )
            if early_failure is None:
                race_failure, race_expected_files, race_deleted_files = self._validate_watch_traversal_race(
                    process, case_work_dir, sync_root, root_name, monitor_stdout, details
                )
                early_failure = race_failure
        finally:
            self._shutdown_monitor_process(process, details)
            if details.get("watch_race_started", False):
                watch_output = self._read_monitor_output_from_offsets(
                    monitor_stdout, int(details["watch_race_log_offset"])
                )
                recovery_lines = [
                    line for line in watch_output.splitlines()
                    if self.WATCH_RACE_RECOVERY_MARKER in line and "watch-race-" in line
                ]
                details["vanished_entry_recovery_exercised"] = bool(recovery_lines)
                details["vanished_entry_recovery_event_count"] = len(recovery_lines)

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
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_anchor_exists"] = anchor_verify.is_file()
        details["verify_transient_exists"] = transient_verify.exists()
        self._write_metadata(metadata_file, details)

        if early_failure is not None:
            return self.fail_result(self.case_id, self.name, early_failure, artifacts, details)
        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )
        if not anchor_verify.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing retained anchor file: {anchor_relative}",
                artifacts,
                details,
            )
        if anchor_verify.read_bytes() != b"TC0056 anchor\n":
            return self.fail_result(self.case_id, self.name, "Retained remote anchor bytes changed during rapid create/delete", artifacts, details)
        if transient_verify.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains transient file after rapid create/delete: {transient_relative}",
                artifacts,
                details,
            )
        for relative, expected_bytes in race_expected_files:
            target = verify_root / relative
            if not target.is_file() or target.read_text(encoding="utf-8") != expected_bytes:
                return self.fail_result(self.case_id, self.name, f"Missing or altered remote watch-traversal probe: {relative}", artifacts, details)
        for relative in race_deleted_files:
            if (verify_root / relative).exists():
                return self.fail_result(self.case_id, self.name, f"Watch-traversal deletion remains online: {relative}", artifacts, details)
        for round_id in range(self.WATCH_RACE_ROUNDS):
            race_verify_dir = verify_root / root_name / f"watch-race-{round_id:02d}"
            if not race_verify_dir.is_dir():
                return self.fail_result(self.case_id, self.name, f"Missing remote watch-traversal directory: {race_verify_dir}", artifacts, details)
            if any(path.name.startswith("transient-") for path in race_verify_dir.rglob("*")):
                return self.fail_result(self.case_id, self.name, f"Unexpected transient churn file remains online: {race_verify_dir}", artifacts, details)
        details["watch_traversal_validation_passed"] = True
        self._write_metadata(metadata_file, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
