from __future__ import annotations

import os
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx, validate_xlsx


class TestCase0080MonitorRemoteDirectoryRenameReconciliation(MonitorModeTestCaseBase):
    """
    Test Case 0080: live monitor remote populated-directory rename reconciliation

    Regression coverage for a production-style remote directory rename while the
    receiving client is already running in normal bidirectional --monitor mode.

    The subject client:
      * has existing local filesystem and items.sqlite3 state;
      * runs bidirectionally with no sync_list or skip_dir filtering;
      * keeps WebSocket support enabled so the remote change is consumed through
        the normal monitor remote-notification path;
      * must reconcile a populated same-parent directory rename as a move of the
        already-known item, not destination creation + stale-source re-upload.

    The independent mutator:
      * first downloads the same tracked tree and keeps its own items.sqlite3;
      * then runs --monitor --upload-only;
      * performs local directory renames while monitor/inotify is active;
      * must log the existing-item move path so the remote stimulus cannot be a
        standalone-sync delete/recreate operation with a new remote item ID.

    Two populated sibling directories are renamed in one monitor session.  This
    intentionally exercises both the single-operation regression and ordering /
    batching behaviour when more than one populated directory rename arrives in
    close succession.

    The subject must not:
      * delete descendants from Microsoft OneDrive;
      * recreate either old directory online;
      * upload children from either old local path;
      * retain stale source trees locally;
      * require a later convergence cycle to repair or recreate state.
    """

    XLSX_PAYLOAD_ROWS = 32
    case_id = "0080"
    name = "monitor remote populated directory rename reconciliation"
    description = (
        "Validate that an already-running bidirectional monitor with WebSocket support "
        "reconciles genuine remote same-parent renames of populated directories using "
        "existing local/database identity without delete/re-upload or old-path recreation"
    )

    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"
    WEBSOCKET_ENABLE_PATTERNS = [
        "Attempting to enable WebSocket support to monitor Microsoft Graph API changes in near real-time.",
        "Enabled WebSocket support to monitor Microsoft Graph API changes in near real-time.",
    ]
    WEBSOCKET_SIGNAL_PATTERN = "DEBUG: Received 1 signal(s) from WebSocket handler"

    def _subject_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        # Unlike most MonitorModeTestCaseBase tests, this testcase explicitly
        # enables WebSocket support because the production topology being tested
        # is a live remote rename received by an already-running monitor.
        return (
            f"# tc{self.case_id} subject config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "false"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "false"\n'
        )

    def _mutator_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        # The mutator only needs local inotify move handling.  Disable WebSocket
        # so the remote stimulus is not obscured by unrelated remote events.
        return self._build_config_text(sync_dir, app_log_dir)

    def _verify_config_text(self, sync_dir: Path) -> str:
        return (
            f"# tc{self.case_id} verify config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

    def _read_text(self, path: Path) -> str:
        if not path.exists():
            return ""
        try:
            return path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def _websocket_signal_count(self, stdout_file: Path) -> int:
        # stdout is the canonical event stream for this metric.  The same
        # WebSocket signal is also written to the configured application log,
        # so counting a combined stdout + app-log stream would double-count one
        # real notification.
        return self._read_text(stdout_file).count(self.WEBSOCKET_SIGNAL_PATTERN)

    def _combined_monitor_output(
        self,
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
    ) -> str:
        parts = [
            self._read_text(stdout_file),
            self._read_text(stderr_file),
            self._read_app_logs(app_log_dir),
        ]
        return "\n".join(part for part in parts if part)

    def _combined_monitor_output_lengths(
        self,
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
    ) -> tuple[int, int, int]:
        return (
            len(self._read_text(stdout_file)),
            len(self._read_text(stderr_file)),
            len(self._read_app_logs(app_log_dir)),
        )

    def _combined_monitor_output_from_offsets(
        self,
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
        offsets: tuple[int, int, int],
    ) -> str:
        stdout_text = self._read_text(stdout_file)
        stderr_text = self._read_text(stderr_file)
        app_log_text = self._read_app_logs(app_log_dir)
        stdout_offset, stderr_offset, app_log_offset = offsets
        return "\n".join(
            part
            for part in [
                stdout_text[stdout_offset:],
                stderr_text[stderr_offset:],
                app_log_text[app_log_offset:],
            ]
            if part
        )

    def _wait_for_patterns(
        self,
        *,
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
        required_patterns: list[str],
        timeout_seconds: int,
        poll_interval: float = 0.5,
    ) -> tuple[bool, str]:
        deadline = time.time() + timeout_seconds
        latest = ""
        while time.time() < deadline:
            latest = self._combined_monitor_output(stdout_file, stderr_file, app_log_dir)
            if all(self._monitor_output_contains(latest, pattern) for pattern in required_patterns):
                return True, latest
            time.sleep(poll_interval)
        return False, latest

    def _wait_for_subject_renames(
        self,
        *,
        subject_root: Path,
        renames: list[tuple[str, str]],
        expected_files: dict[str, str],
        expected_xlsx_revisions: dict[str, str],
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
        start_offsets: tuple[int, int, int],
        websocket_signal_count_before: int,
        timeout_seconds: int = 180,
        poll_interval: float = 0.5,
    ) -> tuple[bool, str]:
        deadline = time.time() + timeout_seconds
        last_reason = "subject monitor did not converge to renamed directory state"

        expected_move_markers = [
            f"Moving ./{source_relative} to ./{destination_relative}"
            for source_relative, destination_relative in renames
        ]

        while time.time() < deadline:
            output = self._combined_monitor_output_from_offsets(
                stdout_file,
                stderr_file,
                app_log_dir,
                start_offsets,
            )
            websocket_signal_count = self._websocket_signal_count(stdout_file)

            state_ok = True
            for source_relative, destination_relative in renames:
                if (subject_root / source_relative).exists():
                    state_ok = False
                    last_reason = f"stale subject source path still exists: {source_relative}"
                    break
                if not (subject_root / destination_relative).is_dir():
                    state_ok = False
                    last_reason = f"subject destination directory is missing: {destination_relative}"
                    break

            if state_ok:
                for relative, expected_content in expected_files.items():
                    path = subject_root / relative
                    if not path.is_file():
                        state_ok = False
                        last_reason = f"subject renamed tree is missing expected file: {relative}"
                        break
                    actual = path.read_text(encoding="utf-8", errors="replace")
                    if actual != expected_content:
                        state_ok = False
                        last_reason = f"subject renamed tree content mismatch: {relative}"
                        break

            if state_ok:
                for relative, expected_revision in expected_xlsx_revisions.items():
                    path = subject_root / relative
                    if not path.is_file():
                        state_ok = False
                        last_reason = f"subject renamed tree is missing expected XLSX: {relative}"
                        break
                    validation_error = validate_xlsx(path, expected_revision)
                    if validation_error:
                        state_ok = False
                        last_reason = f"subject renamed XLSX validation failed for {relative}: {validation_error}"
                        break

            if state_ok and websocket_signal_count <= websocket_signal_count_before:
                state_ok = False
                last_reason = (
                    "subject reached the expected local tree state but no new WebSocket "
                    "signal marker was observed after the remote rename stimulus"
                )

            missing_move_markers = [
                marker
                for marker in expected_move_markers
                if not self._monitor_output_contains(output, marker)
            ]
            if state_ok and missing_move_markers:
                state_ok = False
                last_reason = (
                    "subject reached the expected local tree state but did not prove the "
                    "existing-item remote move path for: "
                    + "; ".join(missing_move_markers)
                )

            if state_ok:
                return True, ""

            time.sleep(poll_interval)

        return False, last_reason

    def _wait_for_mutator_move(
        self,
        *,
        stdout_file: Path,
        stderr_file: Path,
        app_log_dir: Path,
        start_offsets: tuple[int, int, int],
        source_relative: str,
        destination_relative: str,
        timeout_seconds: int = 180,
    ) -> tuple[bool, str]:
        required = [
            f"[M] Local item moved: ./{source_relative} -> ./{destination_relative}",
            f"Moving ./{source_relative} to ./{destination_relative}",
        ]
        deadline = time.time() + timeout_seconds
        latest = ""
        while time.time() < deadline:
            latest = self._combined_monitor_output_from_offsets(
                stdout_file,
                stderr_file,
                app_log_dir,
                start_offsets,
            )
            if all(self._monitor_output_contains(latest, pattern) for pattern in required):
                return True, latest
            time.sleep(0.5)
        return False, latest

    def _subject_bad_side_effects(
        self,
        output: str,
        *,
        root_name: str,
        renames: list[tuple[str, str]],
    ) -> list[str]:
        failures: list[str] = []

        # A remote rename requires no subject-origin remote deletion anywhere
        # inside this reserved testcase tree.
        delete_prefixes = [
            f"Deleting item from Microsoft OneDrive: {root_name}/",
            f"Deleting item from Microsoft OneDrive: ./{root_name}/",
        ]
        for prefix in delete_prefixes:
            if prefix in output:
                failures.append(f"subject attempted remote deletion under testcase root: {prefix}")

        for source_relative, destination_relative in renames:
            source_variants = [source_relative, f"./{source_relative}"]
            destination_variants = [destination_relative, f"./{destination_relative}"]

            for source in source_variants:
                markers = [
                    f"OneDrive Client requested to create this directory online: {source}",
                    f"Uploading new file: {source}/",
                    f"Uploading changed file: {source}/",
                    f"Uploading modified file: {source}/",
                ]
                for marker in markers:
                    if marker in output:
                        failures.append(f"old-path feedback activity detected: {marker}")

            # Existing known remote directories must be moved locally; creating
            # the destination as a new local directory is the failure shape that
            # historically detached descendants from the renamed parent.
            for destination in destination_variants:
                marker = f"Attempting to create local directory: {destination}"
                if marker in output:
                    failures.append(f"destination was pre-created instead of moved: {marker}")

        return sorted(set(failures))

    def _expected_tree(
        self,
        root_name: str,
    ) -> tuple[
        dict[str, str],
        list[tuple[str, str]],
        dict[str, str],
    ]:
        source_files = {
            f"{root_name}/Quarterly Reports/2025/Q4/forecast.xlsx.txt":
                "TC0080 Quarterly Reports / Q4 forecast payload\n",
            f"{root_name}/Quarterly Reports/2025/Q4/Nested/notes.txt":
                "TC0080 Quarterly Reports nested notes payload\n",
            f"{root_name}/Quarterly Reports/overview.txt":
                "TC0080 Quarterly Reports overview payload\n",
            f"{root_name}/Project Alpha/Design/specification.txt":
                "TC0080 Project Alpha design specification payload\n",
            f"{root_name}/Project Alpha/Design/Deep/review.txt":
                "TC0080 Project Alpha deep review payload\n",
            f"{root_name}/Project Alpha/readme.txt":
                "TC0080 Project Alpha readme payload\n",
            f"{root_name}/control.txt":
                "TC0080 unaffected sibling control payload\n",
        }

        renames = [
            (
                f"{root_name}/Quarterly Reports",
                f"{root_name}/Quarterly Reports - Renamed",
            ),
            (
                f"{root_name}/Project Alpha",
                f"{root_name}/Project Alpha - Renamed",
            ),
        ]

        expected_after: dict[str, str] = {}
        for relative, content in source_files.items():
            mapped = relative
            for source_relative, destination_relative in renames:
                if mapped == source_relative or mapped.startswith(source_relative + "/"):
                    mapped = destination_relative + mapped[len(source_relative):]
                    break
            expected_after[mapped] = content

        return source_files, renames, expected_after

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0080",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        subject_root = case_work_dir / "subject-root"
        mutator_root = case_work_dir / "mutator-root"
        verify_root = case_work_dir / "verify-root"

        conf_subject = case_work_dir / "conf-subject"
        conf_mutator = case_work_dir / "conf-mutator"
        conf_verify = case_work_dir / "conf-verify"

        subject_app_logs = case_log_dir / "subject-app-logs"
        mutator_app_logs = case_log_dir / "mutator-app-logs"

        reset_directory(subject_root)
        reset_directory(mutator_root)
        reset_directory(verify_root)

        root_name = f"ZZ_E2E_TC0080_{context.run_id}_{os.getpid()}"
        source_files, renames, expected_after = self._expected_tree(root_name)
        xlsx_source_relative = f"{root_name}/Quarterly Reports/2025/Q4/forecast.xlsx"
        xlsx_expected_relative = f"{root_name}/Quarterly Reports - Renamed/2025/Q4/forecast.xlsx"
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0080:{os.getpid()}"
        expected_xlsx_revisions = {xlsx_expected_relative: REVISION_0}

        context.prepare_minimal_config_dir(
            conf_subject,
            self._subject_config_text(subject_root, subject_app_logs),
        )
        context.prepare_minimal_config_dir(
            conf_mutator,
            self._mutator_config_text(mutator_root, mutator_app_logs),
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            self._verify_config_text(verify_root),
        )

        for relative, content in source_files.items():
            write_text_file(subject_root / relative, content)
        generated_xlsx = create_random_xlsx(
            subject_root / xlsx_source_relative,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0080 remote populated-directory rename workbook",
        )

        phase_files = {
            "subject_seed": (
                case_log_dir / "phase1_subject_seed_stdout.log",
                case_log_dir / "phase1_subject_seed_stderr.log",
            ),
            "mutator_download": (
                case_log_dir / "phase2_mutator_download_stdout.log",
                case_log_dir / "phase2_mutator_download_stderr.log",
            ),
            "subject_monitor": (
                case_log_dir / "phase3_subject_monitor_stdout.log",
                case_log_dir / "phase3_subject_monitor_stderr.log",
            ),
            "mutator_monitor": (
                case_log_dir / "phase4_mutator_monitor_stdout.log",
                case_log_dir / "phase4_mutator_monitor_stderr.log",
            ),
            "subject_converge": (
                case_log_dir / "phase5_subject_converge_stdout.log",
                case_log_dir / "phase5_subject_converge_stderr.log",
            ),
            "verify": (
                case_log_dir / "phase6_verify_stdout.log",
                case_log_dir / "phase6_verify_stderr.log",
            ),
        }

        subject_manifest_file = state_dir / "subject_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            *(str(path) for pair in phase_files.values() for path in pair),
            str(subject_app_logs),
            str(mutator_app_logs),
            str(subject_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "subject_root": str(subject_root),
            "mutator_root": str(mutator_root),
            "verify_root": str(verify_root),
            "subject_conf": str(conf_subject),
            "mutator_conf": str(conf_mutator),
            "verify_conf": str(conf_verify),
            "subject_items_db": str(conf_subject / "items.sqlite3"),
            "mutator_items_db": str(conf_mutator / "items.sqlite3"),
            "renames": renames,
            "source_files": sorted(source_files),
            "expected_after_files": sorted(expected_after),
            "xlsx_source_relative": xlsx_source_relative,
            "xlsx_expected_relative": xlsx_expected_relative,
            "xlsx_seed": xlsx_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_xlsx_size": int(generated_xlsx["size_bytes"]),
            "subject_websocket_enabled_by_config": True,
            "subject_monitor_interval": 300,
            "subject_monitor_fullscan_frequency": 0,
        }

        # Phase 1: establish the subject's real local + DB baseline.
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
            str(conf_subject),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase1 subject seed: "
            f"{command_to_string(seed_command)}"
        )
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(phase_files["subject_seed"][0], seed_result.stdout)
        write_text_file(phase_files["subject_seed"][1], seed_result.stderr)
        details["subject_seed_returncode"] = seed_result.returncode
        details["subject_items_db_exists_after_seed"] = (conf_subject / "items.sqlite3").is_file()

        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"subject seed failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        subject_seed_xlsx_validation_error = (
            validate_xlsx(subject_root / xlsx_source_relative, REVISION_0)
            if (subject_root / xlsx_source_relative).is_file()
            else "Subject XLSX is missing after seed"
        )
        details["subject_seed_xlsx_validation_error"] = subject_seed_xlsx_validation_error
        if subject_seed_xlsx_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"subject XLSX baseline is invalid after seed: {subject_seed_xlsx_validation_error}",
                artifacts,
                details,
            )

        # Phase 2: independent mutator obtains the same existing remote identities.
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
            str(conf_mutator),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase2 mutator download: "
            f"{command_to_string(mutator_download_command)}"
        )
        mutator_download_result = run_command(mutator_download_command, cwd=context.repo_root)
        write_text_file(phase_files["mutator_download"][0], mutator_download_result.stdout)
        write_text_file(phase_files["mutator_download"][1], mutator_download_result.stderr)
        details["mutator_download_returncode"] = mutator_download_result.returncode
        details["mutator_items_db_exists_after_download"] = (conf_mutator / "items.sqlite3").is_file()

        if mutator_download_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"mutator initial download failed with status {mutator_download_result.returncode}",
                artifacts,
                details,
            )

        for relative, expected_content in source_files.items():
            path = mutator_root / relative
            if not path.is_file():
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"mutator did not download expected baseline file: {relative}",
                    artifacts,
                    details,
                )
            actual = path.read_text(encoding="utf-8", errors="replace")
            if actual != expected_content:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"mutator baseline content mismatch: {relative}",
                    artifacts,
                    details,
                )

        mutator_xlsx_validation_error = (
            validate_xlsx(mutator_root / xlsx_source_relative, REVISION_0)
            if (mutator_root / xlsx_source_relative).is_file()
            else "Mutator XLSX is missing after baseline download"
        )
        details["mutator_xlsx_validation_error"] = mutator_xlsx_validation_error
        if mutator_xlsx_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"mutator XLSX baseline is invalid: {mutator_xlsx_validation_error}",
                artifacts,
                details,
            )

        # Phase 3: launch the subject first.  It remains running while the
        # independent endpoint performs both genuine existing-ID renames.
        subject_monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_subject),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase3 subject monitor: "
            f"{command_to_string(subject_monitor_command)}"
        )
        subject_process, subject_initial_sync_complete = self._launch_monitor_process(
            context,
            subject_monitor_command,
            phase_files["subject_monitor"][0],
            phase_files["subject_monitor"][1],
            startup_timeout_seconds=300,
        )

        mutator_process = None
        remote_rename_reconciled = False
        remote_rename_failure = ""
        subject_post_mutation_output = ""
        mutator_move_results: dict[str, bool] = {}

        try:
            details["subject_monitor_initial_sync_complete"] = subject_initial_sync_complete
            if not subject_initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "subject monitor did not complete its initial sync",
                    artifacts,
                    details,
                )

            websocket_enabled, _ = self._wait_for_patterns(
                stdout_file=phase_files["subject_monitor"][0],
                stderr_file=phase_files["subject_monitor"][1],
                app_log_dir=subject_app_logs,
                required_patterns=self.WEBSOCKET_ENABLE_PATTERNS,
                timeout_seconds=45,
            )
            details["subject_websocket_enablement_seen"] = websocket_enabled
            if not websocket_enabled:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "subject monitor did not log WebSocket enablement",
                    artifacts,
                    details,
                )

            websocket_signal_count_before = self._websocket_signal_count(
                phase_files["subject_monitor"][0]
            )
            subject_mutation_offsets = self._combined_monitor_output_lengths(
                phase_files["subject_monitor"][0],
                phase_files["subject_monitor"][1],
                subject_app_logs,
            )
            details["subject_websocket_signal_count_before_renames"] = (
                websocket_signal_count_before
            )

            # Phase 4: start the independent mutator in monitor/upload-only mode.
            mutator_monitor_command = [
                context.onedrive_bin,
                "--display-running-config",
                "--monitor",
                "--upload-only",
                "--verbose",
                "--verbose",
                "--single-directory",
                root_name,
                "--confdir",
                str(conf_mutator),
            ]
            context.log(
                f"Executing Test Case {self.case_id} phase4 mutator monitor: "
                f"{command_to_string(mutator_monitor_command)}"
            )
            mutator_process, mutator_initial_sync_complete = self._launch_monitor_process(
                context,
                mutator_monitor_command,
                phase_files["mutator_monitor"][0],
                phase_files["mutator_monitor"][1],
                startup_timeout_seconds=300,
            )
            details["mutator_monitor_initial_sync_complete"] = mutator_initial_sync_complete

            if not mutator_initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "mutator monitor did not complete its initial sync",
                    artifacts,
                    details,
                )

            for source_relative, destination_relative in renames:
                mutator_offsets = self._combined_monitor_output_lengths(
                    phase_files["mutator_monitor"][0],
                    phase_files["mutator_monitor"][1],
                    mutator_app_logs,
                )

                source_path = mutator_root / source_relative
                destination_path = mutator_root / destination_relative

                if not source_path.is_dir():
                    self._write_metadata(metadata_file, details)
                    return self.fail_result(
                        self.case_id,
                        self.name,
                        f"mutator source directory missing before rename: {source_relative}",
                        artifacts,
                        details,
                    )
                if destination_path.exists():
                    self._write_metadata(metadata_file, details)
                    return self.fail_result(
                        self.case_id,
                        self.name,
                        f"mutator destination unexpectedly exists before rename: {destination_relative}",
                        artifacts,
                        details,
                    )

                context.log(
                    f"Test Case {self.case_id}: mutator renaming populated directory "
                    f"{source_relative} -> {destination_relative}"
                )
                source_path.rename(destination_path)

                move_seen, move_segment = self._wait_for_mutator_move(
                    stdout_file=phase_files["mutator_monitor"][0],
                    stderr_file=phase_files["mutator_monitor"][1],
                    app_log_dir=mutator_app_logs,
                    start_offsets=mutator_offsets,
                    source_relative=source_relative,
                    destination_relative=destination_relative,
                    timeout_seconds=180,
                )
                mutator_move_results[source_relative] = move_seen
                details[f"mutator_move_seen_{source_relative}"] = move_seen

                if not move_seen:
                    details["mutator_failed_move_log_segment"] = move_segment
                    self._write_metadata(metadata_file, details)
                    return self.fail_result(
                        self.case_id,
                        self.name,
                        (
                            "mutator did not prove an existing-item monitor move for "
                            f"{source_relative} -> {destination_relative}"
                        ),
                        artifacts,
                        details,
                    )

            details["mutator_move_results"] = mutator_move_results

            mutator_post_rename_xlsx_error = (
                validate_xlsx(mutator_root / xlsx_expected_relative, REVISION_0)
                if (mutator_root / xlsx_expected_relative).is_file()
                else "Mutator XLSX is missing after directory rename"
            )
            details["mutator_post_rename_xlsx_validation_error"] = mutator_post_rename_xlsx_error
            if mutator_post_rename_xlsx_error:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"mutator XLSX was invalid after local directory rename: {mutator_post_rename_xlsx_error}",
                    artifacts,
                    details,
                )

            remote_rename_reconciled, remote_rename_failure = self._wait_for_subject_renames(
                subject_root=subject_root,
                renames=renames,
                expected_files=expected_after,
                expected_xlsx_revisions=expected_xlsx_revisions,
                stdout_file=phase_files["subject_monitor"][0],
                stderr_file=phase_files["subject_monitor"][1],
                app_log_dir=subject_app_logs,
                start_offsets=subject_mutation_offsets,
                websocket_signal_count_before=websocket_signal_count_before,
                timeout_seconds=180,
            )
            details["subject_remote_rename_reconciled"] = remote_rename_reconciled
            details["subject_remote_rename_failure"] = remote_rename_failure

            subject_post_mutation_output = self._combined_monitor_output_from_offsets(
                phase_files["subject_monitor"][0],
                phase_files["subject_monitor"][1],
                subject_app_logs,
                subject_mutation_offsets,
            )

            details["subject_websocket_signal_count_after_renames"] = (
                self._websocket_signal_count(phase_files["subject_monitor"][0])
            )
            details["subject_expected_move_markers"] = [
                f"Moving ./{source_relative} to ./{destination_relative}"
                for source_relative, destination_relative in renames
            ]
            details["subject_move_markers_seen"] = {
                f"{source_relative} -> {destination_relative}": self._monitor_output_contains(
                    subject_post_mutation_output,
                    f"Moving ./{source_relative} to ./{destination_relative}",
                )
                for source_relative, destination_relative in renames
            }
            details["subject_bad_side_effects"] = self._subject_bad_side_effects(
                subject_post_mutation_output,
                root_name=root_name,
                renames=renames,
            )

            if not remote_rename_reconciled:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    remote_rename_failure,
                    artifacts,
                    details,
                )

            if details["subject_bad_side_effects"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    (
                        "subject monitor logged destructive rename side effects: "
                        + "; ".join(details["subject_bad_side_effects"])
                    ),
                    artifacts,
                    details,
                )

        finally:
            if mutator_process is not None:
                self._shutdown_monitor_process(mutator_process, details)
                details["mutator_monitor_returncode"] = mutator_process.returncode
            self._shutdown_monitor_process(subject_process, details)
            details["subject_monitor_returncode"] = subject_process.returncode
            # _shutdown_monitor_process() uses this generic key for shared testcases.
            # TC0080 owns two concurrent monitor processes, so retain only the
            # explicit per-role return codes to avoid ambiguous overwritten data.
            details.pop("monitor_returncode", None)

        # Phase 5: same subject state must remain converged in a normal follow-up
        # pass.  This catches delayed stale-DB feedback that only appears after
        # the monitor event processing has completed.
        subject_converge_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_subject),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase5 subject converge: "
            f"{command_to_string(subject_converge_command)}"
        )
        subject_converge_result = run_command(subject_converge_command, cwd=context.repo_root)
        write_text_file(
            phase_files["subject_converge"][0],
            subject_converge_result.stdout,
        )
        write_text_file(
            phase_files["subject_converge"][1],
            subject_converge_result.stderr,
        )
        details["subject_converge_returncode"] = subject_converge_result.returncode

        converge_combined = subject_converge_result.stdout + "\n" + subject_converge_result.stderr
        details["subject_converge_bad_side_effects"] = self._subject_bad_side_effects(
            converge_combined,
            root_name=root_name,
            renames=renames,
        )

        # Phase 6: independent remote truth verification.
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
            str(conf_verify),
        ]
        context.log(
            f"Executing Test Case {self.case_id} phase6 verify remote truth: "
            f"{command_to_string(verify_command)}"
        )
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(phase_files["verify"][0], verify_result.stdout)
        write_text_file(phase_files["verify"][1], verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        subject_manifest = build_manifest(subject_root)
        verify_manifest = build_manifest(verify_root)
        write_manifest(subject_manifest_file, subject_manifest)
        write_manifest(verify_manifest_file, verify_manifest)

        details["subject_manifest"] = subject_manifest
        details["verify_manifest"] = verify_manifest

        failures: list[str] = []

        if subject_converge_result.returncode != 0:
            failures.append(
                f"subject convergence pass failed with status {subject_converge_result.returncode}"
            )
        if verify_result.returncode != 0:
            failures.append(
                f"remote verification failed with status {verify_result.returncode}"
            )

        if details["subject_converge_bad_side_effects"]:
            failures.append(
                "subject convergence pass logged delayed destructive rename side effects: "
                + "; ".join(details["subject_converge_bad_side_effects"])
            )

        missing_subject_moves = [
            label
            for label, seen in details.get("subject_move_markers_seen", {}).items()
            if not seen
        ]
        if missing_subject_moves:
            failures.append(
                "subject monitor did not prove receiver-side existing-item move handling for: "
                + "; ".join(missing_subject_moves)
            )

        if details.get("mutator_monitor_returncode") not in {0, 130}:
            failures.append(
                "mutator monitor exited unexpectedly with status "
                f"{details.get('mutator_monitor_returncode')}"
            )
        if details.get("subject_monitor_returncode") not in {0, 130}:
            failures.append(
                "subject monitor exited unexpectedly with status "
                f"{details.get('subject_monitor_returncode')}"
            )

        if not details["subject_items_db_exists_after_seed"]:
            failures.append("subject items.sqlite3 was not established during seed phase")
        if not details["mutator_items_db_exists_after_download"]:
            failures.append("mutator items.sqlite3 was not established during download phase")

        for source_relative, destination_relative in renames:
            if (subject_root / source_relative).exists():
                failures.append(
                    f"subject retained stale source directory after convergence: {source_relative}"
                )
            if (verify_root / source_relative).exists():
                failures.append(
                    f"remote truth contains recreated old directory: {source_relative}"
                )
            if not (subject_root / destination_relative).is_dir():
                failures.append(
                    f"subject is missing renamed destination directory: {destination_relative}"
                )
            if not (verify_root / destination_relative).is_dir():
                failures.append(
                    f"remote truth is missing renamed destination directory: {destination_relative}"
                )

        for relative, expected_content in expected_after.items():
            subject_path = subject_root / relative
            verify_path = verify_root / relative

            if not subject_path.is_file():
                failures.append(f"subject is missing expected final file: {relative}")
            elif subject_path.read_text(encoding="utf-8", errors="replace") != expected_content:
                failures.append(f"subject final file content mismatch: {relative}")

            if not verify_path.is_file():
                failures.append(f"remote truth is missing expected final file: {relative}")
            elif verify_path.read_text(encoding="utf-8", errors="replace") != expected_content:
                failures.append(f"remote truth final file content mismatch: {relative}")

        subject_final_xlsx_error = (
            validate_xlsx(subject_root / xlsx_expected_relative, REVISION_0)
            if (subject_root / xlsx_expected_relative).is_file()
            else "Subject final XLSX is missing"
        )
        verify_final_xlsx_error = (
            validate_xlsx(verify_root / xlsx_expected_relative, REVISION_0)
            if (verify_root / xlsx_expected_relative).is_file()
            else "Remote truth final XLSX is missing"
        )
        details["subject_final_xlsx_validation_error"] = subject_final_xlsx_error
        details["verify_final_xlsx_validation_error"] = verify_final_xlsx_error
        if subject_final_xlsx_error:
            failures.append(
                f"subject final XLSX validation failed for {xlsx_expected_relative}: {subject_final_xlsx_error}"
            )
        if verify_final_xlsx_error:
            failures.append(
                f"remote truth final XLSX validation failed for {xlsx_expected_relative}: {verify_final_xlsx_error}"
            )

        if (subject_root / xlsx_source_relative).exists():
            failures.append(f"subject retained stale old-path XLSX: {xlsx_source_relative}")
        if (verify_root / xlsx_source_relative).exists():
            failures.append(f"remote truth contains stale old-path XLSX: {xlsx_source_relative}")

        old_paths = set(source_files) - {f"{root_name}/control.txt"}
        for relative in old_paths:
            if relative in verify_manifest or (verify_root / relative).exists():
                failures.append(f"remote truth contains stale old-path file: {relative}")

        expected_manifest_files = set(expected_after) | {xlsx_expected_relative}
        actual_subject_files = {
            entry for entry in subject_manifest if (subject_root / entry).is_file()
        }
        actual_verify_files = {
            entry for entry in verify_manifest if (verify_root / entry).is_file()
        }

        if actual_subject_files != expected_manifest_files:
            failures.append(
                "subject final file manifest mismatch: "
                f"expected {sorted(expected_manifest_files)}, got {sorted(actual_subject_files)}"
            )
        if actual_verify_files != expected_manifest_files:
            failures.append(
                "remote truth final file manifest mismatch: "
                f"expected {sorted(expected_manifest_files)}, got {sorted(actual_verify_files)}"
            )

        self._write_metadata(metadata_file, details)

        if failures:
            return self.fail_result(
                self.case_id,
                self.name,
                "; ".join(failures),
                artifacts,
                details,
            )

        return self.pass_result(
            self.case_id,
            self.name,
            artifacts,
            details,
        )
