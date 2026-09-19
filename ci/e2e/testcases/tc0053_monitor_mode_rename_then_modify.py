from __future__ import annotations

import os
import time

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx, mutate_xlsx_revision, validate_xlsx
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0053MonitorModeRenameThenModify(MonitorModeTestCaseBase):
    case_id = "0053"
    name = "monitor mode rename then modify"
    description = "Rename passive TXT and real XLSX files and then modify both under --monitor and validate the final remote state"

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0053",
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

        root_name = f"ZZ_E2E_TC0053_{context.run_id}_{os.getpid()}"
        old_relative = f"{root_name}/before.xlsx"
        new_relative = f"{root_name}/after.xlsx"
        old_text_relative = f"{root_name}/before.txt"
        new_text_relative = f"{root_name}/after.txt"
        old_local = sync_root / old_relative
        new_local = sync_root / new_relative
        old_text_local = sync_root / old_text_relative
        new_text_local = sync_root / new_text_relative
        old_verify = verify_root / old_relative
        new_verify = verify_root / new_relative
        old_text_verify = verify_root / old_text_relative
        new_text_verify = verify_root / new_text_relative

        initial_text_content = "TC0053 initial passive TXT content\n"
        final_text_content = "TC0053 final passive TXT content after rename then modify\n"
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0053:{os.getpid()}"

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(conf_verify, ("# tc0053 verify\n" f'sync_dir = "{verify_root}"\n' 'bypass_data_preservation = "true"\n'))
        generated = create_random_xlsx(
            old_local,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0053 monitor rename then modify workbook",
        )
        write_text_file(old_text_local, initial_text_content)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"
        artifacts = [str(seed_stdout), str(seed_stderr), str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {"root_name": root_name, "old_relative": old_relative, "new_relative": new_relative, "old_text_relative": old_text_relative, "new_text_relative": new_text_relative, "xlsx_seed": xlsx_seed, "payload_rows": self.XLSX_PAYLOAD_ROWS, "generated_size": int(generated["size_bytes"])}

        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Seed phase failed with status {seed_result.returncode}", artifacts, details)

        settled_validation_error = validate_xlsx(old_local, REVISION_0)
        settled_text_content = old_text_local.read_text(encoding="utf-8") if old_text_local.is_file() else ""
        details["settled_validation_error"] = settled_validation_error
        details["settled_text_content"] = settled_text_content
        if settled_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Seeded XLSX was invalid after initial sync: {settled_validation_error}", artifacts, details)
        if settled_text_content != initial_text_content:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, "Seeded passive TXT content changed during initial sync", artifacts, details)

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            old_local.rename(new_local)
            old_text_local.rename(new_text_local)
            time.sleep(1.0)
            mutate_xlsx_revision(new_local, REVISION_0, REVISION_1)
            write_text_file(new_text_local, final_text_content)
            modified_validation_error = validate_xlsx(new_local, REVISION_1)
            details["modified_validation_error"] = modified_validation_error
            if modified_validation_error:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, f"Renamed XLSX mutation produced an invalid workbook: {modified_validation_error}", artifacts, details)
            xlsx_groups = [
                [f"[M] Local item moved: {old_relative} -> {new_relative}", f"Uploading modified file: {new_relative} ... done"],
                [f"Moving {old_relative} to {new_relative}", f"Uploading modified file: {new_relative} ... done"],
                [f"Deleting item from Microsoft OneDrive: {old_relative}", f"Uploading new file: {new_relative} ... done"],
            ]
            text_groups = [
                [f"[M] Local item moved: {old_text_relative} -> {new_text_relative}", f"Uploading modified file: {new_text_relative} ... done"],
                [f"Moving {old_text_relative} to {new_text_relative}", f"Uploading modified file: {new_text_relative} ... done"],
                [f"Deleting item from Microsoft OneDrive: {old_text_relative}", f"Uploading new file: {new_text_relative} ... done"],
            ]
            groups = [xlsx_group + text_group for xlsx_group in xlsx_groups for text_group in text_groups]
            mutation_processed, matched_group, post_mutation_log_segment = self._wait_for_any_stdout_growth_pattern_group(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                alternative_pattern_groups=groups,
                timeout_seconds=180,
            )
            post_mutation_sync_complete = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["post_mutation_sync_complete"] = post_mutation_sync_complete
            details["mutation_processed"] = mutation_processed
            details["matched_pattern_group_index"] = matched_group
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_pattern_groups"] = groups
        finally:
            self._shutdown_monitor_process(process, details)

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_old_exists"] = old_verify.exists()
        details["verify_new_exists"] = new_verify.is_file()
        details["verify_old_text_exists"] = old_text_verify.exists()
        details["verify_new_text_exists"] = new_text_verify.is_file()
        verify_text_content = new_text_verify.read_text(encoding="utf-8") if new_text_verify.is_file() else ""
        details["verify_text_content"] = verify_text_content
        verify_validation_error = (
            validate_xlsx(new_verify, REVISION_1)
            if new_verify.is_file()
            else "Verification XLSX is missing"
        )
        details["verify_validation_error"] = verify_validation_error
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if old_verify.exists() or old_text_verify.exists() or not new_verify.is_file() or not new_text_verify.is_file() or verify_validation_error:
            return self.fail_result(self.case_id, self.name, f"Remote verification did not preserve final TXT/XLSX rename-then-modify state correctly: {verify_validation_error}", artifacts, details)
        if verify_text_content != final_text_content:
            return self.fail_result(self.case_id, self.name, "Remote verification passive TXT content did not match final rename-then-modify state", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
