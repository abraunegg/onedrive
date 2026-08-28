from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0054MonitorModeAtomicSaveEditorReplaceWorkflow(MonitorModeTestCaseBase):
    case_id = "0054"
    name = "monitor mode atomic-save and completed-file hand-off workflows"
    description = (
        "Validate atomic temp-file replacement and completed-file hard-link hand-off workflows under --monitor"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0054",
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

        root_name = f"ZZ_E2E_TC0054_{context.run_id}_{os.getpid()}"

        # AS-0001: existing atomic-save editor replace workflow.
        target_relative = f"{root_name}/document.txt"
        temp_relative = f"{root_name}/.document.txt.swp"
        target_local = sync_root / target_relative
        temp_local = sync_root / temp_relative
        target_verify = verify_root / target_relative
        temp_verify = verify_root / temp_relative

        # AS-0002: completed temporary file exposed through a second hard link
        # before the temporary pathname is removed. On Linux this reproduces the
        # CREATE -> CLOSE_WRITE -> CREATE -> DELETE sequence from issue #3840
        # without relying on a WinSCP-specific filename suffix.
        handoff_target_relative = f"{root_name}/handoff-document.txt"
        handoff_temp_relative = f"{root_name}/handoff-document.staging"
        handoff_target_local = sync_root / handoff_target_relative
        handoff_temp_local = sync_root / handoff_temp_relative
        handoff_target_verify = verify_root / handoff_target_relative
        handoff_temp_verify = verify_root / handoff_temp_relative

        original_content = (
            "TC0054 monitor mode atomic-save editor replace workflow\n"
            "ORIGINAL CONTENT\n"
        )
        updated_content = (
            "TC0054 monitor mode atomic-save editor replace workflow\n"
            "UPDATED CONTENT VIA TEMP FILE REPLACE\n"
        )
        handoff_content = (
            "TC0054 monitor mode completed-file hand-off workflow\n"
            "CONTENT WRITTEN THROUGH TEMPORARY PATH\n"
        )

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0054 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(target_local, original_content)

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
        details = {
            "root_name": root_name,
            "target_relative": target_relative,
            "temp_relative": temp_relative,
            "handoff_target_relative": handoff_target_relative,
            "handoff_temp_relative": handoff_temp_relative,
        }

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
        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
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

            # AS-0002 first: require the final pathname to be handled by the
            # inotify path before the 300-second scheduled monitor interval can
            # discover it through the normal filesystem scan.
            handoff_log_start_offset = self._prepare_monitor_for_local_mutation(
                process,
                monitor_stdout,
                details,
            )

            write_text_file(handoff_temp_local, handoff_content)
            os.link(handoff_temp_local, handoff_target_local)
            details["handoff_same_inode_before_unlink"] = (
                handoff_temp_local.stat().st_dev == handoff_target_local.stat().st_dev
                and handoff_temp_local.stat().st_ino == handoff_target_local.stat().st_ino
            )
            handoff_temp_local.unlink()
            details["handoff_temp_local_exists_after_finalise"] = handoff_temp_local.exists()
            details["handoff_target_local_exists_after_finalise"] = handoff_target_local.is_file()

            handoff_required_patterns = [
                f"Uploading new file: {handoff_target_relative} ... done",
            ]
            handoff_processed, handoff_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=handoff_log_start_offset,
                required_patterns=handoff_required_patterns,
                timeout_seconds=180,
            )
            details["handoff_processed"] = handoff_processed
            details["handoff_log_segment_length"] = len(handoff_log_segment)
            details["handoff_required_patterns"] = handoff_required_patterns
            details["handoff_temp_upload_seen"] = (
                f"Uploading new file: {handoff_temp_relative}" in handoff_log_segment
                or f"Uploading modified file: {handoff_temp_relative}" in handoff_log_segment
            )

            if not handoff_processed:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "AS-0002 monitor did not immediately upload the completed-file hand-off destination",
                    artifacts,
                    details,
                )
            if details["handoff_temp_upload_seen"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "AS-0002 monitor incorrectly attempted to upload the temporary hand-off pathname",
                    artifacts,
                    details,
                )

            # AS-0001: preserve the existing atomic editor-save replacement
            # coverage after the new completed-file hand-off scenario.
            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            write_text_file(temp_local, updated_content)
            os.replace(temp_local, target_local)
            details["temp_local_exists_after_replace"] = temp_local.exists()
            details["target_local_exists_after_replace"] = target_local.is_file()

            pattern_groups = [
                [f"Uploading modified file: {target_relative} ... done"],
                [f"Uploading new file: {target_relative} ... done"],
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
            details["pattern_groups"] = pattern_groups

            if not mutation_processed:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "AS-0001 monitor did not process the atomic editor-save replacement within the expected time",
                    artifacts,
                    details,
                )
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
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_target_exists"] = target_verify.is_file()
        details["verify_target_content"] = target_verify.read_text(encoding="utf-8") if target_verify.is_file() else ""
        details["verify_temp_exists"] = temp_verify.exists()
        details["verify_handoff_target_exists"] = handoff_target_verify.is_file()
        details["verify_handoff_target_content"] = (
            handoff_target_verify.read_text(encoding="utf-8") if handoff_target_verify.is_file() else ""
        )
        details["verify_handoff_temp_exists"] = handoff_temp_verify.exists()
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )
        if not target_verify.is_file() or details["verify_target_content"] != updated_content:
            return self.fail_result(
                self.case_id,
                self.name,
                f"AS-0001 remote verification did not preserve the updated editor-save content: {target_relative}",
                artifacts,
                details,
            )
        if temp_verify.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"AS-0001 remote verification still contains temporary editor-save file: {temp_relative}",
                artifacts,
                details,
            )
        if not handoff_target_verify.is_file() or details["verify_handoff_target_content"] != handoff_content:
            return self.fail_result(
                self.case_id,
                self.name,
                f"AS-0002 remote verification did not preserve the completed-file hand-off content: {handoff_target_relative}",
                artifacts,
                details,
            )
        if handoff_temp_verify.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"AS-0002 remote verification still contains temporary hand-off file: {handoff_temp_relative}",
                artifacts,
                details,
            )
        return self.pass_result(self.case_id, self.name, artifacts, details)
