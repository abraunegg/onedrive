from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0049MonitorModeMixedBurstOperations(MonitorModeTestCaseBase):
    case_id = "0049"
    name = "monitor mode mixed burst operations"
    description = "Perform create, modify, delete, and rename operations in one burst under --monitor and validate the final state"

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0049"
        case_log_dir = context.logs_dir / "tc0049"
        state_dir = context.state_dir / "tc0049"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0049_{context.run_id}_{os.getpid()}"
        anchor_relative = f"{root_name}/anchor.txt"
        modify_relative = f"{root_name}/modify-me.txt"
        delete_relative = f"{root_name}/delete-me.txt"
        rename_old_relative = f"{root_name}/rename-me.txt"
        rename_new_relative = f"{root_name}/renamed-result.txt"
        create_relative = f"{root_name}/new-created.txt"

        anchor_local = sync_root / anchor_relative
        modify_local = sync_root / modify_relative
        delete_local = sync_root / delete_relative
        rename_old_local = sync_root / rename_old_relative
        rename_new_local = sync_root / rename_new_relative
        create_local = sync_root / create_relative

        modify_verify = verify_root / modify_relative
        delete_verify = verify_root / delete_relative
        rename_old_verify = verify_root / rename_old_relative
        rename_new_verify = verify_root / rename_new_relative
        create_verify = verify_root / create_relative

        initial_modify = "TC0049 initial modify content\n"
        final_modify = "TC0049 final modify content\n"
        rename_content = "TC0049 rename content\n"
        create_content = "TC0049 create content\n"

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(conf_verify, ("# tc0049 verify\n" f'sync_dir = "{verify_root}"\n' 'bypass_data_preservation = "true"\n'))

        write_text_file(anchor_local, "TC0049 anchor\n")
        write_text_file(modify_local, initial_modify)
        write_text_file(delete_local, "TC0049 delete me\n")
        write_text_file(rename_old_local, rename_content)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [str(seed_stdout), str(seed_stderr), str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {"root_name": root_name, "modify_relative": modify_relative, "delete_relative": delete_relative, "rename_old_relative": rename_old_relative, "rename_new_relative": rename_new_relative, "create_relative": create_relative}

        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(self.case_id, self.name, f"Seed phase failed with status {seed_result.returncode}", artifacts, details)

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return TestResult.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            write_text_file(create_local, create_content)
            write_text_file(modify_local, final_modify)
            if delete_local.exists():
                delete_local.unlink()
            rename_old_local.rename(rename_new_local)

            fixed_patterns = [
                f"Uploading new file: {create_relative} ... done",
                f"Uploading modified file: {modify_relative} ... done",
                f"Deleting item from Microsoft OneDrive: {delete_relative}",
            ]
            rename_groups = [
                [f"[M] Local item moved: {rename_old_relative} -> {rename_new_relative}", f"Moving {rename_old_relative} to {rename_new_relative}"],
                [f"Deleting item from Microsoft OneDrive: {rename_old_relative}", f"Uploading new file: {rename_new_relative} ... done"],
            ]
            fixed_ok = self._wait_for_monitor_patterns(monitor_stdout, fixed_patterns)
            rename_ok, matched_group = self._wait_for_any_monitor_pattern_group(monitor_stdout, rename_groups)
            details["fixed_patterns_observed"] = fixed_ok
            details["rename_patterns_observed"] = rename_ok
            details["matched_rename_pattern_group_index"] = matched_group
            details["mutation_processed"] = bool(fixed_ok and rename_ok)
            details["fixed_patterns"] = fixed_patterns
            details["rename_pattern_groups"] = rename_groups
        finally:
            self._shutdown_monitor_process(process, details)

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_modify_exists"] = modify_verify.is_file()
        details["verify_modify_content"] = modify_verify.read_text(encoding="utf-8") if modify_verify.is_file() else ""
        details["verify_delete_exists"] = delete_verify.exists()
        details["verify_rename_old_exists"] = rename_old_verify.exists()
        details["verify_rename_new_exists"] = rename_new_verify.is_file()
        details["verify_rename_new_content"] = rename_new_verify.read_text(encoding="utf-8") if rename_new_verify.is_file() else ""
        details["verify_create_exists"] = create_verify.is_file()
        details["verify_create_content"] = create_verify.read_text(encoding="utf-8") if create_verify.is_file() else ""
        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return TestResult.fail_result(self.case_id, self.name, "Monitor mode did not process the mixed burst operations before shutdown", artifacts, details)
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not modify_verify.is_file() or details["verify_modify_content"] != final_modify:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification did not preserve modified file state: {modify_relative}", artifacts, details)
        if delete_verify.exists():
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification still contains deleted file: {delete_relative}", artifacts, details)
        if rename_old_verify.exists() or not rename_new_verify.is_file() or details["verify_rename_new_content"] != rename_content:
            return TestResult.fail_result(self.case_id, self.name, "Remote verification did not preserve renamed file state correctly", artifacts, details)
        if not create_verify.is_file() or details["verify_create_content"] != create_content:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification did not preserve created file state: {create_relative}", artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
