from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, rename_xlsx_pair, unlink_xlsx_pair, large_xlsx_relative, xlsx_pair_any_exists
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0049MonitorModeMixedBurstOperations(MonitorModeTestCaseBase):
    XLSX_PAYLOAD_ROWS = 32
    case_id = "0049"
    name = "monitor mode mixed burst operations"
    description = "Perform create, modify, delete, and rename operations in one burst under --monitor and validate the final state"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0049",
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

        root_name = f"ZZ_E2E_TC0049_{context.run_id}_{os.getpid()}"
        anchor_relative = f"{root_name}/anchor.txt"
        modify_relative = f"{root_name}/modify-me.txt"
        delete_relative = f"{root_name}/delete-me.txt"
        rename_old_relative = f"{root_name}/rename-me.txt"
        rename_new_relative = f"{root_name}/renamed-result.txt"
        create_relative = f"{root_name}/new-created.txt"
        modify_xlsx_relative = f"{root_name}/modify-me.xlsx"
        delete_xlsx_relative = f"{root_name}/delete-me.xlsx"
        rename_old_xlsx_relative = f"{root_name}/rename-me.xlsx"
        rename_new_xlsx_relative = f"{root_name}/renamed-result.xlsx"
        create_xlsx_relative = f"{root_name}/new-created.xlsx"

        anchor_local = sync_root / anchor_relative
        modify_local = sync_root / modify_relative
        delete_local = sync_root / delete_relative
        rename_old_local = sync_root / rename_old_relative
        rename_new_local = sync_root / rename_new_relative
        create_local = sync_root / create_relative
        modify_xlsx_local = sync_root / modify_xlsx_relative
        delete_xlsx_local = sync_root / delete_xlsx_relative
        rename_old_xlsx_local = sync_root / rename_old_xlsx_relative
        rename_new_xlsx_local = sync_root / rename_new_xlsx_relative
        create_xlsx_local = sync_root / create_xlsx_relative

        modify_verify = verify_root / modify_relative
        delete_verify = verify_root / delete_relative
        rename_old_verify = verify_root / rename_old_relative
        rename_new_verify = verify_root / rename_new_relative
        create_verify = verify_root / create_relative
        modify_xlsx_verify = verify_root / modify_xlsx_relative
        delete_xlsx_verify = verify_root / delete_xlsx_relative
        rename_old_xlsx_verify = verify_root / rename_old_xlsx_relative
        rename_new_xlsx_verify = verify_root / rename_new_xlsx_relative
        create_xlsx_verify = verify_root / create_xlsx_relative

        initial_modify = "TC0049 initial modify content\n"
        final_modify = "TC0049 final modify content\n"
        rename_content = "TC0049 rename content\n"
        create_content = "TC0049 create content\n"
        xlsx_seed_base = f"{context.run_id}:{context.e2e_target}:TC0049:{os.getpid()}"

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(conf_verify, ("# tc0049 verify\n" f'sync_dir = "{verify_root}"\n' 'bypass_data_preservation = "true"\n'))

        write_text_file(anchor_local, "TC0049 anchor\n")
        write_text_file(modify_local, initial_modify)
        write_text_file(delete_local, "TC0049 delete me\n")
        write_text_file(rename_old_local, rename_content)
        generated_modify_xlsx = create_random_xlsx_pair(
            modify_xlsx_local,
            f"{xlsx_seed_base}:modify",
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0049 mixed burst modify workbook",
        )
        generated_delete_xlsx = create_random_xlsx_pair(
            delete_xlsx_local,
            f"{xlsx_seed_base}:delete",
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0049 mixed burst delete workbook",
        )
        generated_rename_xlsx = create_random_xlsx_pair(
            rename_old_xlsx_local,
            f"{xlsx_seed_base}:rename",
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0049 mixed burst rename workbook",
        )

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [str(seed_stdout), str(seed_stderr), str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {
            "root_name": root_name,
            "modify_relative": modify_relative,
            "delete_relative": delete_relative,
            "rename_old_relative": rename_old_relative,
            "rename_new_relative": rename_new_relative,
            "create_relative": create_relative,
            "modify_xlsx_relative": modify_xlsx_relative,
            "delete_xlsx_relative": delete_xlsx_relative,
            "rename_old_xlsx_relative": rename_old_xlsx_relative,
            "rename_new_xlsx_relative": rename_new_xlsx_relative,
            "create_xlsx_relative": create_xlsx_relative,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_modify_xlsx_size": int(generated_modify_xlsx["size_bytes"]),
            "generated_delete_xlsx_size": int(generated_delete_xlsx["size_bytes"]),
            "generated_rename_xlsx_size": int(generated_rename_xlsx["size_bytes"]),
        }

        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Seed phase failed with status {seed_result.returncode}", artifacts, details)

        seed_xlsx_errors = {
            "modify": validate_xlsx_pair(modify_xlsx_local, REVISION_0) if modify_xlsx_local.is_file() else "missing",
            "delete": validate_xlsx_pair(delete_xlsx_local, REVISION_0) if delete_xlsx_local.is_file() else "missing",
            "rename": validate_xlsx_pair(rename_old_xlsx_local, REVISION_0) if rename_old_xlsx_local.is_file() else "missing",
        }
        details["seed_xlsx_validation_errors"] = seed_xlsx_errors
        invalid_seed_xlsx = {key: value for key, value in seed_xlsx_errors.items() if value}
        if invalid_seed_xlsx:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed phase did not leave valid XLSX burst subjects: {invalid_seed_xlsx}",
                artifacts,
                details,
            )

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            write_text_file(create_local, create_content)
            write_text_file(modify_local, final_modify)
            mutate_xlsx_pair_revision(modify_xlsx_local, REVISION_0, REVISION_1)
            details["modified_xlsx_validation_error"] = validate_xlsx_pair(modify_xlsx_local, REVISION_1)
            if delete_local.exists():
                delete_local.unlink()
            unlink_xlsx_pair(delete_xlsx_local)
            rename_old_local.rename(rename_new_local)
            rename_xlsx_pair(rename_old_xlsx_local, rename_new_xlsx_local)
            generated_create_xlsx = create_random_xlsx_pair(
                create_xlsx_local,
                f"{xlsx_seed_base}:create",
                revision=REVISION_0,
                payload_rows=self.XLSX_PAYLOAD_ROWS,
                title="TC0049 mixed burst create workbook",
            )
            details["generated_create_xlsx_size"] = int(generated_create_xlsx["size_bytes"])
            details["created_xlsx_validation_error"] = validate_xlsx_pair(create_xlsx_local, REVISION_0)

            fixed_patterns = [
                f"Uploading new file: {create_relative} ... done",
                f"Uploading modified file: {modify_relative} ... done",
                f"Deleting item from Microsoft OneDrive: {delete_relative}",
                f"Uploading new file: {create_xlsx_relative} ... done",
                f"Uploading new file: {large_xlsx_relative(create_xlsx_relative)} ... done",
                f"Uploading modified file: {modify_xlsx_relative} ... done",
                f"Uploading modified file: {large_xlsx_relative(modify_xlsx_relative)} ... done",
                f"Deleting item from Microsoft OneDrive: {delete_xlsx_relative}",
                f"Deleting item from Microsoft OneDrive: {large_xlsx_relative(delete_xlsx_relative)}",
            ]
            text_rename_move = [f"[M] Local item moved: {rename_old_relative} -> {rename_new_relative}", f"Moving {rename_old_relative} to {rename_new_relative}"]
            text_rename_recreate = [f"Deleting item from Microsoft OneDrive: {rename_old_relative}", f"Uploading new file: {rename_new_relative} ... done"]
            xlsx_rename_groups = []
            for old_xlsx_relative, new_xlsx_relative in (
                (rename_old_xlsx_relative, rename_new_xlsx_relative),
                (large_xlsx_relative(rename_old_xlsx_relative), large_xlsx_relative(rename_new_xlsx_relative)),
            ):
                xlsx_rename_groups.append([
                    f"[M] Local item moved: {old_xlsx_relative} -> {new_xlsx_relative}",
                    f"Moving {old_xlsx_relative} to {new_xlsx_relative}",
                ])
                xlsx_rename_groups.append([
                    f"Deleting item from Microsoft OneDrive: {old_xlsx_relative}",
                    f"Uploading new file: {new_xlsx_relative} ... done",
                ])
            rename_groups = [
                text_group + first_xlsx_group + second_xlsx_group
                for text_group in (text_rename_move, text_rename_recreate)
                for first_xlsx_group in xlsx_rename_groups[0:2]
                for second_xlsx_group in xlsx_rename_groups[2:4]
            ]
            fixed_ok, rename_ok, matched_group, post_mutation_log_segment = self._wait_for_required_patterns_and_any_group(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=fixed_patterns,
                alternative_pattern_groups=rename_groups,
                timeout_seconds=180,
            )
            post_mutation_sync_complete = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["post_mutation_sync_complete"] = post_mutation_sync_complete
            details["fixed_patterns_observed"] = fixed_ok
            details["rename_patterns_observed"] = rename_ok
            details["matched_rename_pattern_group_index"] = matched_group
            details["mutation_processed"] = bool(fixed_ok and rename_ok)
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
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
        details["verify_modify_xlsx_validation_error"] = (validate_xlsx_pair(modify_xlsx_verify, REVISION_1) if modify_xlsx_verify.is_file() else "missing")
        details["verify_delete_xlsx_exists"] = xlsx_pair_any_exists(delete_xlsx_verify)
        details["verify_rename_old_xlsx_exists"] = xlsx_pair_any_exists(rename_old_xlsx_verify)
        details["verify_rename_new_xlsx_validation_error"] = (validate_xlsx_pair(rename_new_xlsx_verify, REVISION_0) if rename_new_xlsx_verify.is_file() else "missing")
        details["verify_create_xlsx_validation_error"] = (validate_xlsx_pair(create_xlsx_verify, REVISION_0) if create_xlsx_verify.is_file() else "missing")
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not modify_verify.is_file() or details["verify_modify_content"] != final_modify:
            return self.fail_result(self.case_id, self.name, f"Remote verification did not preserve modified file state: {modify_relative}", artifacts, details)
        if delete_verify.exists():
            return self.fail_result(self.case_id, self.name, f"Remote verification still contains deleted file: {delete_relative}", artifacts, details)
        if rename_old_verify.exists() or not rename_new_verify.is_file() or details["verify_rename_new_content"] != rename_content:
            return self.fail_result(self.case_id, self.name, "Remote verification did not preserve renamed file state correctly", artifacts, details)
        if not create_verify.is_file() or details["verify_create_content"] != create_content:
            return self.fail_result(self.case_id, self.name, f"Remote verification did not preserve created file state: {create_relative}", artifacts, details)
        if details["verify_modify_xlsx_validation_error"]:
            return self.fail_result(self.case_id, self.name, f"Remote verification did not preserve modified XLSX revision: {modify_xlsx_relative}", artifacts, details)
        if xlsx_pair_any_exists(delete_xlsx_verify):
            return self.fail_result(self.case_id, self.name, f"Remote verification still contains deleted XLSX: {delete_xlsx_relative}", artifacts, details)
        if xlsx_pair_any_exists(rename_old_xlsx_verify) or details["verify_rename_new_xlsx_validation_error"]:
            return self.fail_result(self.case_id, self.name, "Remote verification did not preserve renamed XLSX state correctly", artifacts, details)
        if details["verify_create_xlsx_validation_error"]:
            return self.fail_result(self.case_id, self.name, f"Remote verification did not preserve created XLSX state: {create_xlsx_relative}", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
