from __future__ import annotations

import os
import re
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0016CheckNosyncValidation(MonitorModeTestCaseBase):
    case_id = "0016"
    name = "check_nosync validation"
    description = (
        "Validate pre-existing .nosync exclusion and dynamic .nosync exclusion "
        "after a directory has already been synchronised"
    )

    def _simple_config_text(
        self,
        sync_root: Path,
        *,
        label: str,
        check_nosync: bool = False,
    ) -> str:
        lines = [
            f"# tc0016 {label} config",
            f'sync_dir = "{sync_root}"',
            'bypass_data_preservation = "true"',
        ]
        if check_nosync:
            lines.append('check_nosync = "true"')
        return "\n".join(lines) + "\n"

    def _prepare_simple_client(
        self,
        context: E2EContext,
        config_dir: Path,
        sync_root: Path,
        *,
        label: str,
        check_nosync: bool = False,
    ) -> None:
        context.prepare_minimal_config_dir(
            config_dir,
            self._simple_config_text(
                sync_root,
                label=label,
                check_nosync=check_nosync,
            ),
        )

    def _prepare_monitor_mutator(
        self,
        context: E2EContext,
        config_dir: Path,
        sync_root: Path,
        app_log_dir: Path,
    ) -> None:
        context.prepare_minimal_config_dir(
            config_dir,
            self._build_config_text(sync_root, app_log_dir),
        )

    def _run_phase(
        self,
        *,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        details: dict[str, object],
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        details[f"{label}_returncode"] = result.returncode
        details[f"{label}_command"] = command_to_string(command)
        return result

    @staticmethod
    def _combined_output(stdout_file: Path, stderr_file: Path) -> str:
        stdout = stdout_file.read_text(encoding="utf-8", errors="replace") if stdout_file.exists() else ""
        stderr = stderr_file.read_text(encoding="utf-8", errors="replace") if stderr_file.exists() else ""
        return stdout + "\n" + stderr

    @staticmethod
    def _read_file(path: Path) -> str:
        if not path.is_file():
            return ""
        return path.read_text(encoding="utf-8", errors="replace")

    @staticmethod
    def _check_nosync_active(output: str) -> bool:
        return re.search(r"Config option 'check_nosync'\s*=\s*true", output) is not None

    def _run_preexisting_nosync_scenario(
        self,
        context: E2EContext,
        *,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> tuple[list[str], list[str], dict[str, object]]:
        scenario_id = "NS-0001"
        sync_root = scenario_work_dir / "syncroot"
        verify_root = scenario_work_dir / "verifyroot"
        conf_main = scenario_work_dir / "conf-main"
        conf_verify = scenario_work_dir / "conf-verify"

        for path in [sync_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0016_{scenario_id}_{context.run_id}_{os.getpid()}"
        allowed_relative = f"{root_name}/Allowed/ok.txt"
        blocked_dir_relative = f"{root_name}/Blocked"
        blocked_marker_relative = f"{blocked_dir_relative}/.nosync"
        blocked_file_relative = f"{blocked_dir_relative}/blocked.txt"

        write_text_file(sync_root / allowed_relative, "ok\n")
        write_text_file(sync_root / blocked_marker_relative, "")
        write_text_file(sync_root / blocked_file_relative, "blocked\n")

        self._prepare_simple_client(
            context,
            conf_main,
            sync_root,
            label=f"{scenario_id} subject",
            check_nosync=True,
        )
        self._prepare_simple_client(
            context,
            conf_verify,
            verify_root,
            label=f"{scenario_id} verify",
        )

        sync_stdout = scenario_log_dir / "phase1_sync_stdout.log"
        sync_stderr = scenario_log_dir / "phase1_sync_stderr.log"
        verify_stdout = scenario_log_dir / "phase2_verify_stdout.log"
        verify_stderr = scenario_log_dir / "phase2_verify_stderr.log"
        remote_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts = [
            str(sync_stdout),
            str(sync_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "root_name": root_name,
            "allowed_relative": allowed_relative,
            "blocked_dir_relative": blocked_dir_relative,
            "blocked_marker_relative": blocked_marker_relative,
            "blocked_file_relative": blocked_file_relative,
            "subject_items_db": str(conf_main / "items.sqlite3"),
        }
        failures: list[str] = []

        sync_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        sync_result = self._run_phase(
            context=context,
            label=f"{scenario_id}_phase1_sync",
            command=sync_command,
            stdout_file=sync_stdout,
            stderr_file=sync_stderr,
            details=details,
        )
        if sync_result.returncode != 0:
            failures.append(f"pre-existing .nosync sync failed with status {sync_result.returncode}")

        sync_output = self._combined_output(sync_stdout, sync_stderr)
        details["check_nosync_active"] = self._check_nosync_active(sync_output)
        details["subject_items_db_exists"] = (conf_main / "items.sqlite3").is_file()
        if not details["check_nosync_active"]:
            failures.append("subject sync did not prove check_nosync=true was active")

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
        verify_result = self._run_phase(
            context=context,
            label=f"{scenario_id}_phase2_verify",
            command=verify_command,
            stdout_file=verify_stdout,
            stderr_file=verify_stderr,
            details=details,
        )
        if verify_result.returncode != 0:
            failures.append(f"remote verification failed with status {verify_result.returncode}")

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)
        details["remote_manifest"] = remote_manifest

        if allowed_relative not in remote_manifest:
            failures.append("allowed content missing after check_nosync processing")
        for unwanted in [blocked_dir_relative, blocked_marker_relative, blocked_file_relative]:
            if unwanted in remote_manifest:
                failures.append(f".nosync directory content was unexpectedly synchronised: {unwanted}")

        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

    def _run_dynamic_nosync_scenario(
        self,
        context: E2EContext,
        *,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> tuple[list[str], list[str], dict[str, object]]:
        scenario_id = "NS-0002"

        mutator_root = scenario_work_dir / "mutator-root"
        subject_root = scenario_work_dir / "subject-root"
        precheck_root = scenario_work_dir / "precheck-root"
        verify_root = scenario_work_dir / "verify-root"

        conf_mutator = scenario_work_dir / "conf-mutator"
        conf_subject = scenario_work_dir / "conf-subject"
        conf_precheck = scenario_work_dir / "conf-precheck"
        conf_verify = scenario_work_dir / "conf-verify"
        mutator_app_logs = scenario_log_dir / "app-logs"

        for path in [mutator_root, subject_root, precheck_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0016_{scenario_id}_{context.run_id}_{os.getpid()}"
        excluded_dir_relative = f"{root_name}/DynamicExcluded"
        existing_a_relative = f"{excluded_dir_relative}/existing-a.txt"
        existing_b_relative = f"{excluded_dir_relative}/existing-b.txt"
        nosync_relative = f"{excluded_dir_relative}/.nosync"
        local_only_relative = f"{excluded_dir_relative}/local-only-after-nosync.txt"
        remote_only_relative = f"{excluded_dir_relative}/remote-only-after-nosync.txt"
        control_relative = f"{root_name}/Control/control.txt"

        existing_a_initial = "TC0016 NS-0002 existing A initial\n"
        existing_a_remote_modified = "TC0016 NS-0002 existing A modified remotely after .nosync\n"
        existing_b_initial = "TC0016 NS-0002 existing B initial\n"
        control_initial = "TC0016 NS-0002 control initial\n"
        control_remote_modified = "TC0016 NS-0002 control modified remotely\n"
        local_only_content = "TC0016 NS-0002 local-only content created after .nosync\n"
        remote_only_content = "TC0016 NS-0002 remote-only content created by mutator\n"

        write_text_file(mutator_root / existing_a_relative, existing_a_initial)
        write_text_file(mutator_root / existing_b_relative, existing_b_initial)
        write_text_file(mutator_root / control_relative, control_initial)

        self._prepare_monitor_mutator(
            context,
            conf_mutator,
            mutator_root,
            mutator_app_logs,
        )
        self._prepare_simple_client(
            context,
            conf_subject,
            subject_root,
            label=f"{scenario_id} subject",
            check_nosync=True,
        )
        self._prepare_simple_client(
            context,
            conf_precheck,
            precheck_root,
            label=f"{scenario_id} precheck",
        )
        self._prepare_simple_client(
            context,
            conf_verify,
            verify_root,
            label=f"{scenario_id} verify",
        )

        phase_files = {
            "mutator_seed": (
                scenario_log_dir / "phase1_mutator_seed_stdout.log",
                scenario_log_dir / "phase1_mutator_seed_stderr.log",
            ),
            "subject_initial": (
                scenario_log_dir / "phase2_subject_initial_stdout.log",
                scenario_log_dir / "phase2_subject_initial_stderr.log",
            ),
            "mutator_monitor": (
                scenario_log_dir / "phase4_mutator_monitor_stdout.log",
                scenario_log_dir / "phase4_mutator_monitor_stderr.log",
            ),
            "precheck": (
                scenario_log_dir / "phase5_remote_precheck_stdout.log",
                scenario_log_dir / "phase5_remote_precheck_stderr.log",
            ),
            "subject_reconcile": (
                scenario_log_dir / "phase6_subject_reconcile_stdout.log",
                scenario_log_dir / "phase6_subject_reconcile_stderr.log",
            ),
            "verify": (
                scenario_log_dir / "phase7_remote_verify_stdout.log",
                scenario_log_dir / "phase7_remote_verify_stderr.log",
            ),
        }

        subject_before_manifest_file = scenario_state_dir / "subject_before_reconcile_manifest.txt"
        precheck_manifest_file = scenario_state_dir / "remote_precheck_manifest.txt"
        subject_after_manifest_file = scenario_state_dir / "subject_after_reconcile_manifest.txt"
        verify_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts = [
            *(str(path) for pair in phase_files.values() for path in pair),
            str(mutator_app_logs),
            str(subject_before_manifest_file),
            str(precheck_manifest_file),
            str(subject_after_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "root_name": root_name,
            "excluded_dir_relative": excluded_dir_relative,
            "existing_a_relative": existing_a_relative,
            "existing_b_relative": existing_b_relative,
            "nosync_relative": nosync_relative,
            "local_only_relative": local_only_relative,
            "remote_only_relative": remote_only_relative,
            "control_relative": control_relative,
            "mutator_items_db": str(conf_mutator / "items.sqlite3"),
            "subject_items_db": str(conf_subject / "items.sqlite3"),
            "mutator_root": str(mutator_root),
            "subject_root": str(subject_root),
            "precheck_root": str(precheck_root),
            "verify_root": str(verify_root),
        }
        failures: list[str] = []

        # Phase 1: establish the real online baseline through an independent
        # upload-only client. The mutator keeps its own items.sqlite3 state and
        # will later make genuine online changes through --monitor.
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
            str(conf_mutator),
        ]
        seed_result = self._run_phase(
            context=context,
            label=f"{scenario_id}_phase1_mutator_seed",
            command=seed_command,
            stdout_file=phase_files["mutator_seed"][0],
            stderr_file=phase_files["mutator_seed"][1],
            details=details,
        )
        if seed_result.returncode != 0:
            failures.append(f"mutator seed failed with status {seed_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        details["mutator_items_db_exists_after_seed"] = (conf_mutator / "items.sqlite3").is_file()
        if not details["mutator_items_db_exists_after_seed"]:
            failures.append("mutator seed did not preserve items.sqlite3")

        # Phase 2: independently establish the subject client's own database and
        # local baseline while check_nosync=true but before any .nosync exists.
        subject_initial_command = [
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
            str(conf_subject),
        ]
        subject_initial_result = self._run_phase(
            context=context,
            label=f"{scenario_id}_phase2_subject_initial",
            command=subject_initial_command,
            stdout_file=phase_files["subject_initial"][0],
            stderr_file=phase_files["subject_initial"][1],
            details=details,
        )
        if subject_initial_result.returncode != 0:
            failures.append(
                f"subject initial download failed with status {subject_initial_result.returncode}"
            )
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        subject_initial_output = self._combined_output(*phase_files["subject_initial"])
        details["check_nosync_active_during_initial"] = self._check_nosync_active(subject_initial_output)
        details["subject_items_db_exists_after_initial"] = (conf_subject / "items.sqlite3").is_file()
        if not details["check_nosync_active_during_initial"]:
            failures.append("subject initial phase did not prove check_nosync=true was active")
        if not details["subject_items_db_exists_after_initial"]:
            failures.append("subject initial phase did not preserve items.sqlite3")

        initial_expectations = {
            existing_a_relative: existing_a_initial,
            existing_b_relative: existing_b_initial,
            control_relative: control_initial,
        }
        for relative, expected in initial_expectations.items():
            path = subject_root / relative
            if not path.is_file():
                failures.append(f"subject initial baseline is missing expected file: {relative}")
            elif self._read_file(path) != expected:
                failures.append(f"subject initial baseline content mismatch: {relative}")

        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # Phase 3: this is the state transition under test. The directory and its
        # children are already synchronised and represented in items.sqlite3.
        # Adding .nosync must make this local subtree non-destructively excluded.
        write_text_file(subject_root / nosync_relative, "")
        write_text_file(subject_root / local_only_relative, local_only_content)

        subject_before_manifest = build_manifest(subject_root)
        write_manifest(subject_before_manifest_file, subject_before_manifest)
        details["subject_before_reconcile_manifest"] = subject_before_manifest
        details["subject_nosync_exists_before_reconcile"] = (subject_root / nosync_relative).is_file()
        details["subject_local_only_exists_before_reconcile"] = (subject_root / local_only_relative).is_file()

        # Phase 4: while the subject stays stale, use the established independent
        # mutator as a real --monitor --upload-only endpoint. Modify one file under
        # the soon-to-be-excluded subtree, modify a control file outside it, and
        # create a new remote-only file under the excluded subtree.
        monitor_command = [
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
        details["mutator_monitor_command"] = command_to_string(monitor_command)
        context.log(
            f"Executing Test Case {self.case_id} {scenario_id} phase4 mutator monitor: "
            f"{details['mutator_monitor_command']}"
        )

        monitor_details: dict[str, object] = {}
        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            phase_files["mutator_monitor"][0],
            phase_files["mutator_monitor"][1],
            startup_timeout_seconds=300,
        )
        try:
            details["mutator_monitor_initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                failures.append("mutator monitor did not complete its initial sync")
            else:
                modify_start = self._prepare_monitor_for_local_mutation(
                    process,
                    phase_files["mutator_monitor"][0],
                    monitor_details,
                )
                if not bool(monitor_details.get("monitor_ready_after_initial_sync", False)):
                    failures.append("mutator monitor was not ready for remote modification stimulus")
                else:
                    time.sleep(1.5)
                    write_text_file(mutator_root / existing_a_relative, existing_a_remote_modified)
                    write_text_file(mutator_root / control_relative, control_remote_modified)
                    modify_patterns = [
                        f"Uploading modified file: {existing_a_relative} ... done",
                        f"Uploading modified file: {control_relative} ... done",
                    ]
                    modify_processed, modify_segment = self._wait_for_stdout_growth_patterns(
                        phase_files["mutator_monitor"][0],
                        start_offset=modify_start,
                        required_patterns=modify_patterns,
                        timeout_seconds=180,
                    )
                    details["mutator_modify_processed"] = modify_processed
                    details["mutator_modify_patterns"] = modify_patterns
                    details["mutator_modify_log_segment_length"] = len(modify_segment)
                    if not modify_processed:
                        failures.append("mutator monitor did not propagate both remote modifications")

                if not failures:
                    create_start = self._prepare_monitor_for_local_mutation(
                        process,
                        phase_files["mutator_monitor"][0],
                        monitor_details,
                    )
                    if not bool(monitor_details.get("monitor_ready_after_initial_sync", False)):
                        failures.append("mutator monitor was not ready for remote create stimulus")
                    else:
                        write_text_file(mutator_root / remote_only_relative, remote_only_content)
                        create_patterns = [
                            f"Uploading new file: {remote_only_relative} ... done",
                        ]
                        create_processed, create_segment = self._wait_for_stdout_growth_patterns(
                            phase_files["mutator_monitor"][0],
                            start_offset=create_start,
                            required_patterns=create_patterns,
                            timeout_seconds=180,
                        )
                        details["mutator_create_processed"] = create_processed
                        details["mutator_create_patterns"] = create_patterns
                        details["mutator_create_log_segment_length"] = len(create_segment)
                        if not create_processed:
                            failures.append("mutator monitor did not propagate remote-only file creation")
        finally:
            self._shutdown_monitor_process(process, monitor_details)
            details["mutator_monitor_details"] = monitor_details

        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # Phase 5: independently prove the online mutations exist before allowing
        # the stale subject to reconcile. This removes monitor/API timing from the
        # actual #3769 assertion.
        precheck_command = [
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
            str(conf_precheck),
        ]
        precheck_result = self._run_phase(
            context=context,
            label=f"{scenario_id}_phase5_remote_precheck",
            command=precheck_command,
            stdout_file=phase_files["precheck"][0],
            stderr_file=phase_files["precheck"][1],
            details=details,
        )
        if precheck_result.returncode != 0:
            failures.append(f"remote mutation precheck failed with status {precheck_result.returncode}")

        precheck_manifest = build_manifest(precheck_root)
        write_manifest(precheck_manifest_file, precheck_manifest)
        details["precheck_manifest"] = precheck_manifest

        precheck_expectations = {
            existing_a_relative: existing_a_remote_modified,
            existing_b_relative: existing_b_initial,
            control_relative: control_remote_modified,
            remote_only_relative: remote_only_content,
        }
        for relative, expected in precheck_expectations.items():
            path = precheck_root / relative
            if not path.is_file():
                failures.append(f"remote mutation precheck is missing expected file: {relative}")
            elif self._read_file(path) != expected:
                failures.append(f"remote mutation precheck content mismatch: {relative}")

        for absent in [nosync_relative, local_only_relative]:
            if (precheck_root / absent).exists() or absent in precheck_manifest:
                failures.append(f"remote mutation precheck unexpectedly contains local-only path: {absent}")

        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # Phase 6: actual Issue #3769 observation point. Use the SAME subject
        # syncroot + config + items.sqlite3 established in phase 2. Do not resync.
        subject_reconcile_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_subject),
        ]
        subject_reconcile_result = self._run_phase(
            context=context,
            label=f"{scenario_id}_phase6_subject_reconcile",
            command=subject_reconcile_command,
            stdout_file=phase_files["subject_reconcile"][0],
            stderr_file=phase_files["subject_reconcile"][1],
            details=details,
        )
        if subject_reconcile_result.returncode != 0:
            failures.append(
                f"subject reconciliation failed with status {subject_reconcile_result.returncode}"
            )

        subject_reconcile_output = self._combined_output(*phase_files["subject_reconcile"])
        details["check_nosync_active_during_reconcile"] = self._check_nosync_active(subject_reconcile_output)
        details["subject_items_db_exists_after_reconcile"] = (conf_subject / "items.sqlite3").is_file()
        reconcile_lines = subject_reconcile_output.splitlines()
        details["subject_reconcile_nosync_log_lines"] = [
            line
            for line in reconcile_lines
            if ".nosync" in line and excluded_dir_relative in line
        ]
        excluded_action_markers = [
            "Uploading new file:",
            "Uploading modified file:",
            "Downloading file:",
            "Moving this local file to the configured 'Recycle Bin'",
            "Moving this local directory to the configured 'Recycle Bin'",
            "Deleting item from Microsoft OneDrive:",
            "Trying to delete this item as requested:",
            "The local item has been deleted:",
        ]
        details["subject_reconcile_excluded_action_lines"] = [
            line
            for line in reconcile_lines
            if excluded_dir_relative in line
            and any(marker in line for marker in excluded_action_markers)
        ]

        if not details["check_nosync_active_during_reconcile"]:
            failures.append("subject reconciliation did not prove check_nosync=true was active")
        if not details["subject_items_db_exists_after_reconcile"]:
            failures.append("subject reconciliation did not retain items.sqlite3")
        if details["subject_reconcile_excluded_action_lines"]:
            failures.append(
                "subject reconciliation performed synchronisation action(s) beneath .nosync: "
                + " | ".join(details["subject_reconcile_excluded_action_lines"])
            )

        subject_after_manifest = build_manifest(subject_root)
        write_manifest(subject_after_manifest_file, subject_after_manifest)
        details["subject_after_reconcile_manifest"] = subject_after_manifest

        subject_expectations = {
            existing_a_relative: existing_a_initial,
            existing_b_relative: existing_b_initial,
            control_relative: control_remote_modified,
            local_only_relative: local_only_content,
            nosync_relative: "",
        }
        for relative, expected in subject_expectations.items():
            path = subject_root / relative
            if not path.is_file():
                failures.append(f"subject reconciliation removed or failed to retain expected local file: {relative}")
            elif self._read_file(path) != expected:
                failures.append(f"subject reconciliation produced unexpected local content: {relative}")

        if (subject_root / remote_only_relative).exists() or remote_only_relative in subject_after_manifest:
            failures.append(
                f"subject reconciliation downloaded remote content beneath .nosync: {remote_only_relative}"
            )

        # Phase 7: fresh independent remote truth verification. Existing remote
        # content under the excluded subtree must remain online, remote mutations
        # must remain authoritative online, and local-only/.nosync data must not
        # have been uploaded by the subject.
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
        verify_result = self._run_phase(
            context=context,
            label=f"{scenario_id}_phase7_remote_verify",
            command=verify_command,
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
            details=details,
        )
        if verify_result.returncode != 0:
            failures.append(f"final remote verification failed with status {verify_result.returncode}")

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_manifest"] = verify_manifest

        verify_expectations = {
            existing_a_relative: existing_a_remote_modified,
            existing_b_relative: existing_b_initial,
            control_relative: control_remote_modified,
            remote_only_relative: remote_only_content,
        }
        for relative, expected in verify_expectations.items():
            path = verify_root / relative
            if not path.is_file():
                failures.append(f"final remote verification is missing expected online file: {relative}")
            elif self._read_file(path) != expected:
                failures.append(f"final remote verification content mismatch: {relative}")

        for absent in [nosync_relative, local_only_relative]:
            if (verify_root / absent).exists() or absent in verify_manifest:
                failures.append(f"local-only .nosync subtree content was unexpectedly uploaded: {absent}")

        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0016",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        scenarios = [
            ("NS-0001", self._run_preexisting_nosync_scenario),
            ("NS-0002", self._run_dynamic_nosync_scenario),
        ]
        scenarios = [
            (scenario_id, runner)
            for scenario_id, runner in scenarios
            if context.should_run_scenario(self.case_id, scenario_id)
        ]

        all_artifacts: list[str] = []
        details: dict[str, object] = {}
        failed_scenarios: list[str] = []
        failure_messages: dict[str, list[str]] = {}

        for scenario_id, runner in scenarios:
            scenario_dir_name = scenario_id.lower().replace("-", "")
            scenario_work_dir = case_work_dir / scenario_dir_name
            scenario_log_dir = case_log_dir / scenario_dir_name
            scenario_state_dir = state_dir / scenario_dir_name
            reset_directory(scenario_work_dir)
            reset_directory(scenario_log_dir)
            reset_directory(scenario_state_dir)

            try:
                failures, artifacts, scenario_details = runner(
                    context,
                    scenario_work_dir=scenario_work_dir,
                    scenario_log_dir=scenario_log_dir,
                    scenario_state_dir=scenario_state_dir,
                )
            except Exception as exc:
                failures = [f"unexpected exception: {exc}"]
                artifacts = []
                scenario_details = {"exception": repr(exc)}
                self._write_metadata(scenario_state_dir / "metadata.txt", scenario_details)

            all_artifacts.extend(artifacts)
            details[scenario_id] = scenario_details
            details[f"{scenario_id}_passed"] = not failures
            if failures:
                failed_scenarios.append(scenario_id)
                failure_messages[scenario_id] = failures

        details["executed_scenario_ids"] = [scenario_id for scenario_id, _ in scenarios]
        details["failed_scenario_ids"] = list(failed_scenarios)
        details["failure_messages"] = failure_messages

        summary_file = state_dir / "scenario_summary.txt"
        summary_lines: list[str] = []
        for scenario_id, _ in scenarios:
            failures = failure_messages.get(scenario_id, [])
            if failures:
                summary_lines.append(f"{scenario_id} [FAIL] " + "; ".join(failures))
            else:
                summary_lines.append(f"{scenario_id} [PASS]")
        write_text_file(summary_file, "\n".join(summary_lines) + "\n")
        all_artifacts.append(str(summary_file))

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        all_artifacts.append(str(metadata_file))

        deduped_artifacts: list[str] = []
        seen: set[str] = set()
        for artifact in all_artifacts:
            if artifact not in seen:
                deduped_artifacts.append(artifact)
                seen.add(artifact)

        if failed_scenarios:
            first_scenario = failed_scenarios[0]
            first_failure = failure_messages[first_scenario][0]
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failed_scenarios)} of {len(scenarios)} check_nosync scenarios failed: "
                f"{', '.join(failed_scenarios)} — {first_failure}",
                deduped_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, deduped_artifacts, details)
