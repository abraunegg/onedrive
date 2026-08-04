from __future__ import annotations

import os
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0061RemoteMoveIntoSkipDirReconciliation(MonitorModeTestCaseBase):
    case_id = "0061"
    name = "remote move into skip_dir removes stale local source files"
    description = (
        "Validate that an existing skip_dir-configured client removes stale local "
        "source files after a second synced endpoint moves those files from an "
        "included path into a skipped path, while preserving unrelated files that "
        "remain in the original source directory"
    )

    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"

    def _build_skip_config_text(self, sync_dir: Path) -> str:
        return self._build_config_text(
            sync_dir,
            sync_dir.parent / "linux-skip-client-app-logs",
            extra_config_lines=[
                'skip_dir = "Pictures/Archive"',
                'skip_dir_strict_match = "true"',
            ],
        )

    def _build_mutator_monitor_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        # This testcase uses the mutator as the remote-side synced endpoint.
        # The shared monitor config keeps WebSocket disabled so the online move is
        # driven by local inotify move detection rather than remote notification timing.
        return self._build_config_text(sync_dir, app_log_dir)

    def _build_unfiltered_config_text(self, sync_dir: Path) -> str:
        return (
            "# tc0061 unfiltered remote truth verifier config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

    def _run_phase(
        self,
        *,
        context: E2EContext,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        details: dict[str, object],
        detail_key: str,
    ):
        context.log(f"Executing Test Case {self.case_id} {detail_key}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        details[f"{detail_key}_returncode"] = result.returncode
        return result

    def _list_files_under(self, root: Path) -> list[str]:
        if not root.exists():
            return []
        return sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_file())

    def _contains_bad_monitor_move_side_effects(self, log_segment: str) -> list[str]:
        bad_markers = [
            "Trying to delete this item as requested:",
            "The local item has been deleted:",
            "Uploading new file:",
            "Uploading changed file:",
            "Deleted local items to delete on Microsoft OneDrive:",
        ]
        return [marker for marker in bad_markers if marker in log_segment]

    def _wait_for_stdout_growth_patterns(
        self,
        stdout_file: Path,
        *,
        start_offset: int,
        required_patterns: list[str],
        timeout_seconds: int = 180,
        poll_interval: float = 0.5,
    ) -> tuple[bool, str]:
        import time

        deadline = time.time() + timeout_seconds
        latest_segment = ""

        while time.time() < deadline:
            content = self._read_stdout(stdout_file)
            latest_segment = content[start_offset:]
            if all(pattern in latest_segment for pattern in required_patterns):
                return True, latest_segment
            time.sleep(poll_interval)

        return False, latest_segment

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0061",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        linux_sync_root = case_work_dir / "linux-skip-client-syncroot"
        mutator_sync_root = case_work_dir / "remote-mutator-syncroot"
        verify_sync_root = case_work_dir / "remote-truth-verify-syncroot"

        linux_conf = case_work_dir / "conf-linux-skip-client"
        mutator_conf = case_work_dir / "conf-remote-mutator"
        verify_conf = case_work_dir / "conf-remote-truth-verify"
        mutator_app_log_dir = case_log_dir / "mutator-app-logs"

        reset_directory(linux_sync_root)
        reset_directory(mutator_sync_root)
        reset_directory(verify_sync_root)

        root_name = f"ZZ_E2E_TC0061_{context.run_id}_{os.getpid()}"
        dcim_relative = f"{root_name}/Pictures/DCIM"
        archive_relative = f"{root_name}/Pictures/Archive"
        archive_2025_relative = f"{archive_relative}/2025"
        skipped_relative = "Pictures/Archive"

        # Keep one file behind in DCIM to model Norbert's clarified case:
        # only selected files are moved out to the skipped archive path, while
        # the source directory remains valid because it still contains other
        # synced content.
        moved_source_files = {
            f"{dcim_relative}/photo-001.txt": "TC0061 photo 001\n",
            f"{dcim_relative}/photo-002.txt": "TC0061 photo 002\n",
            f"{dcim_relative}/photo-003.txt": "TC0061 photo 003\n",
        }
        retained_source_files = {
            f"{dcim_relative}/keep-synced.txt": "TC0061 file intentionally retained in DCIM\n",
        }
        source_files = {**moved_source_files, **retained_source_files}
        moved_files = {
            path.replace(dcim_relative, archive_2025_relative, 1): content
            for path, content in moved_source_files.items()
        }

        context.prepare_minimal_config_dir(
            linux_conf,
            self._build_skip_config_text(linux_sync_root),
        )
        context.prepare_minimal_config_dir(
            mutator_conf,
            self._build_mutator_monitor_config_text(mutator_sync_root, mutator_app_log_dir),
        )
        context.prepare_minimal_config_dir(
            verify_conf,
            self._build_unfiltered_config_text(verify_sync_root),
        )

        for relative_path, content in source_files.items():
            write_text_file(linux_sync_root / relative_path, content)

        phase_files = {
            "seed": (case_log_dir / "phase1_linux_seed_stdout.log", case_log_dir / "phase1_linux_seed_stderr.log"),
            "mutator_download": (case_log_dir / "phase2_mutator_download_stdout.log", case_log_dir / "phase2_mutator_download_stderr.log"),
            "mutator_prepare_archive": (case_log_dir / "phase2b_mutator_prepare_archive_stdout.log", case_log_dir / "phase2b_mutator_prepare_archive_stderr.log"),
            "mutator_monitor": (case_log_dir / "phase3_mutator_monitor_stdout.log", case_log_dir / "phase3_mutator_monitor_stderr.log"),
            "reconcile": (case_log_dir / "phase4_linux_skip_reconcile_stdout.log", case_log_dir / "phase4_linux_skip_reconcile_stderr.log"),
            "verify": (case_log_dir / "phase5_remote_truth_verify_stdout.log", case_log_dir / "phase5_remote_truth_verify_stderr.log"),
        }

        linux_manifest_file = state_dir / "linux_skip_client_manifest_after_reconcile.txt"
        verify_manifest_file = state_dir / "remote_truth_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            *(str(path) for pair in phase_files.values() for path in pair),
            str(linux_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
            str(mutator_app_log_dir),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "dcim_relative": dcim_relative,
            "archive_relative": archive_relative,
            "archive_2025_relative": archive_2025_relative,
            "skipped_relative": skipped_relative,
            "source_files": sorted(source_files),
            "moved_source_files": sorted(moved_source_files),
            "retained_source_files": sorted(retained_source_files),
            "moved_files": sorted(moved_files),
            "linux_sync_root": str(linux_sync_root),
            "mutator_sync_root": str(mutator_sync_root),
            "verify_sync_root": str(verify_sync_root),
            "linux_conf": str(linux_conf),
            "mutator_conf": str(mutator_conf),
            "verify_conf": str(verify_conf),
            "linux_items_db": str(linux_conf / "items.sqlite3"),
            "mutator_items_db": str(mutator_conf / "items.sqlite3"),
            "mutator_websocket_disabled": True,
        }

        # Phase 1: seed the remote source path using the same skip_dir-configured
        # Linux client that will later reconcile. This establishes the real local
        # root + items.sqlite3 baseline for /Pictures/DCIM before the remote move.
        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(linux_conf),
        ]
        seed_result = self._run_phase(
            context=context,
            command=seed_command,
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
            details=details,
            detail_key="phase1_linux_seed",
        )
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Linux seed phase failed with status {seed_result.returncode}", artifacts, details)

        details["linux_items_db_exists_after_seed"] = (linux_conf / "items.sqlite3").is_file()
        details["linux_source_files_exist_after_seed"] = {
            relative: (linux_sync_root / relative).is_file() for relative in source_files
        }

        # Phase 2: create an unfiltered second-client view of the remote tree.
        # This represents the machine / OneDrive endpoint that will perform the move.
        mutator_download_command = [
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
            str(mutator_conf),
        ]
        mutator_download_result = self._run_phase(
            context=context,
            command=mutator_download_command,
            stdout_file=phase_files["mutator_download"][0],
            stderr_file=phase_files["mutator_download"][1],
            details=details,
            detail_key="phase2_mutator_download",
        )
        if mutator_download_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Mutator download phase failed with status {mutator_download_result.returncode}", artifacts, details)

        details["mutator_items_db_exists_after_download"] = (mutator_conf / "items.sqlite3").is_file()

        for source_relative in source_files:
            source_path = mutator_sync_root / source_relative
            if not source_path.is_file():
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, f"Mutator did not download expected source before move: {source_relative}", artifacts, details)

        # Phase 2b: create only the destination archive directory before
        # starting monitor. This is important because monitor/inotify must have
        # the destination tree under watch before the file moves occur. Do not
        # create any destination files here; the file moves themselves must be
        # produced by monitor-mode local move handling.
        (mutator_sync_root / archive_2025_relative).mkdir(parents=True, exist_ok=True)
        mutator_prepare_archive_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(mutator_conf),
        ]
        mutator_prepare_archive_result = self._run_phase(
            context=context,
            command=mutator_prepare_archive_command,
            stdout_file=phase_files["mutator_prepare_archive"][0],
            stderr_file=phase_files["mutator_prepare_archive"][1],
            details=details,
            detail_key="phase2b_mutator_prepare_archive",
        )
        if mutator_prepare_archive_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Mutator archive directory preparation failed with status {mutator_prepare_archive_result.returncode}", artifacts, details)

        for moved_relative in moved_files:
            if (mutator_sync_root / moved_relative).exists():
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, f"Mutator destination file unexpectedly exists before monitor move: {moved_relative}", artifacts, details)

        # Phase 3: run the mutator as a real synced endpoint in --monitor mode,
        # then move the local files while monitor is active. This avoids the
        # standalone --sync delete + upload path and validates that the online
        # change is produced by monitor local-move handling.
        mutator_monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(mutator_conf),
        ]
        context.log(f"Executing Test Case {self.case_id} phase3_mutator_monitor: {command_to_string(mutator_monitor_command)}")
        process, initial_sync_complete = self._launch_monitor_process(
            context,
            mutator_monitor_command,
            phase_files["mutator_monitor"][0],
            phase_files["mutator_monitor"][1],
            startup_timeout_seconds=300,
        )

        mutator_move_processed = False
        mutator_post_move_log_segment = ""
        try:
            details["mutator_monitor_initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Mutator monitor did not complete initial sync before local moves",
                    artifacts,
                    details,
                )

            initial_stdout = self._read_stdout(phase_files["mutator_monitor"][0])
            mutation_log_start_offset = len(initial_stdout)
            details["mutator_move_log_start_offset"] = mutation_log_start_offset
            details["mutator_initial_sync_complete_count_before_moves"] = initial_stdout.count(self.SYNC_COMPLETE_PATTERN)

            required_move_patterns: list[str] = []
            move_results: dict[str, bool] = {}
            current_log_offset = mutation_log_start_offset

            for source_relative in sorted(moved_source_files):
                destination_relative = source_relative.replace(dcim_relative, archive_2025_relative, 1)
                source_path = mutator_sync_root / source_relative
                destination_path = mutator_sync_root / destination_relative
                destination_path.parent.mkdir(parents=True, exist_ok=True)

                context.log(f"Test Case {self.case_id}: mutator monitor moving local file: {source_relative} -> {destination_relative}")
                source_path.rename(destination_path)

                per_file_required_patterns = [
                    f"[M] Local item moved: {source_relative} -> {destination_relative}",
                    f"Moving {source_relative} to {destination_relative}",
                ]
                required_move_patterns.extend(per_file_required_patterns)

                per_file_processed, per_file_segment = self._wait_for_stdout_growth_patterns(
                    phase_files["mutator_monitor"][0],
                    start_offset=current_log_offset,
                    required_patterns=per_file_required_patterns,
                    timeout_seconds=180,
                )
                mutator_post_move_log_segment += per_file_segment
                move_results[source_relative] = per_file_processed
                current_log_offset = len(self._read_stdout(phase_files["mutator_monitor"][0]))

                if not per_file_processed:
                    break

            details["mutator_source_files_exist_after_local_move"] = {
                relative: (mutator_sync_root / relative).exists() for relative in source_files
            }
            details["mutator_destination_files_exist_after_local_move"] = {
                relative: (mutator_sync_root / relative).is_file() for relative in moved_files
            }
            details["mutator_required_move_patterns"] = required_move_patterns
            details["mutator_per_file_move_results"] = move_results

            mutator_move_processed = all(move_results.get(relative, False) for relative in sorted(moved_source_files))
            details["mutator_move_processed"] = mutator_move_processed
            details["mutator_post_move_bad_markers"] = self._contains_bad_monitor_move_side_effects(mutator_post_move_log_segment)
            details["mutator_post_move_log_segment_length"] = len(mutator_post_move_log_segment)
        finally:
            self._shutdown_monitor_process(process, details)

        if not mutator_move_processed:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Mutator monitor did not log all local file move operations before shutdown",
                artifacts,
                details,
            )

        if details["mutator_post_move_bad_markers"]:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Mutator monitor move processing logged delete/re-upload side effects: {details['mutator_post_move_bad_markers']}",
                artifacts,
                details,
            )

        # Phase 4: reconcile the original skip_dir-configured Linux client using
        # the same sync root and same items.sqlite3 state from phase 1. No --resync.
        reconcile_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(linux_conf),
        ]
        reconcile_result = self._run_phase(
            context=context,
            command=reconcile_command,
            stdout_file=phase_files["reconcile"][0],
            stderr_file=phase_files["reconcile"][1],
            details=details,
            detail_key="phase4_linux_skip_reconcile",
        )

        # Phase 5: unfiltered verification only. This phase intentionally does not
        # use skip_dir because its purpose is to prove the remote truth still has
        # the moved archive files and no longer has the old DCIM files.
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
            str(verify_conf),
        ]
        verify_result = self._run_phase(
            context=context,
            command=verify_command,
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
            details=details,
            detail_key="phase5_remote_truth_verify",
        )

        linux_manifest = build_manifest(linux_sync_root)
        verify_manifest = build_manifest(verify_sync_root)
        write_manifest(linux_manifest_file, linux_manifest)
        write_manifest(verify_manifest_file, verify_manifest)

        reconcile_output = phase_files["reconcile"][0].read_text(encoding="utf-8", errors="replace")
        reconcile_errors = phase_files["reconcile"][1].read_text(encoding="utf-8", errors="replace")
        reconcile_combined = reconcile_output + "\n" + reconcile_errors

        details.update(
            {
                "linux_manifest": linux_manifest,
                "verify_manifest": verify_manifest,
                "linux_dcim_exists_after_reconcile": (linux_sync_root / dcim_relative).exists(),
                "linux_archive_exists_after_reconcile": (linux_sync_root / archive_relative).exists(),
                "verify_dcim_exists": (verify_sync_root / dcim_relative).exists(),
                "verify_archive_2025_exists": (verify_sync_root / archive_2025_relative).exists(),
                "linux_source_dir_files_after_reconcile": self._list_files_under(linux_sync_root / dcim_relative),
                "linux_archive_dir_files_after_reconcile": self._list_files_under(linux_sync_root / archive_relative),
                "verify_source_dir_files": self._list_files_under(verify_sync_root / dcim_relative),
                "skip_dir_visible_in_reconcile_output": (
                    "skip_dir" in reconcile_combined and skipped_relative in reconcile_combined
                ),
                "archive_download_logged_in_reconcile": any(
                    f"Downloading file: {moved_relative}" in reconcile_combined for moved_relative in moved_files
                ),
            }
        )
        self._write_metadata(metadata_file, details)

        failures: list[str] = []
        if reconcile_result.returncode != 0:
            failures.append(f"Linux skip_dir reconciliation failed with status {reconcile_result.returncode}")
        if verify_result.returncode != 0:
            failures.append(f"Remote truth verification failed with status {verify_result.returncode}")

        if not details["linux_items_db_exists_after_seed"]:
            failures.append("Linux skip client did not preserve items.sqlite3 after seed phase")
        if not details["mutator_items_db_exists_after_download"]:
            failures.append("Mutator client did not preserve items.sqlite3 after download phase")

        if not details["skip_dir_visible_in_reconcile_output"]:
            failures.append("Reconcile phase output did not show skip_dir active for the Linux client")

        if details["archive_download_logged_in_reconcile"]:
            failures.append("Linux skip_dir reconcile phase attempted to download skipped archive files")

        for source_relative in moved_source_files:
            if source_relative in linux_manifest or (linux_sync_root / source_relative).exists():
                failures.append(f"Linux skip client still contains stale moved source file after remote move into skip_dir: {source_relative}")
            if source_relative in verify_manifest or (verify_sync_root / source_relative).exists():
                failures.append(f"Remote truth still contains old moved source file after move: {source_relative}")

        for retained_relative, expected_content in retained_source_files.items():
            linux_retained_path = linux_sync_root / retained_relative
            verify_retained_path = verify_sync_root / retained_relative
            if not linux_retained_path.is_file():
                failures.append(f"Linux skip client removed retained source file unexpectedly: {retained_relative}")
            elif linux_retained_path.read_text(encoding="utf-8", errors="replace") != expected_content:
                failures.append(f"Linux skip client retained source content mismatch: {retained_relative}")
            if not verify_retained_path.is_file():
                failures.append(f"Remote truth is missing retained source file unexpectedly: {retained_relative}")
            elif verify_retained_path.read_text(encoding="utf-8", errors="replace") != expected_content:
                failures.append(f"Remote truth retained source content mismatch: {retained_relative}")

        expected_linux_source_dir_files = sorted(str(Path(relative).relative_to(dcim_relative)) for relative in retained_source_files)
        if details["linux_source_dir_files_after_reconcile"] != expected_linux_source_dir_files:
            failures.append(
                "Linux skip client source directory contents after reconcile are incorrect: "
                f"expected {expected_linux_source_dir_files}, got {details['linux_source_dir_files_after_reconcile']}"
            )
        if details["verify_source_dir_files"] != expected_linux_source_dir_files:
            failures.append(
                "Remote truth source directory contents after move are incorrect: "
                f"expected {expected_linux_source_dir_files}, got {details['verify_source_dir_files']}"
            )

        for moved_relative, expected_content in moved_files.items():
            linux_moved_path = linux_sync_root / moved_relative
            verify_moved_path = verify_sync_root / moved_relative
            if linux_moved_path.exists():
                failures.append(f"Linux skip client downloaded skipped destination unexpectedly: {moved_relative}")
            if moved_relative in linux_manifest:
                failures.append(f"Linux skip client manifest contains skipped destination unexpectedly: {moved_relative}")
            if not verify_moved_path.is_file():
                failures.append(f"Remote truth is missing moved skipped destination: {moved_relative}")
            elif verify_moved_path.read_text(encoding="utf-8", errors="replace") != expected_content:
                failures.append(f"Remote truth content mismatch for moved skipped destination: {moved_relative}")

        if details["linux_archive_dir_files_after_reconcile"]:
            failures.append(f"Linux skip client contains files under skipped archive directory: {details['linux_archive_dir_files_after_reconcile']}")

        if failures:
            return self.fail_result(self.case_id, self.name, "; ".join(failures), artifacts, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)
