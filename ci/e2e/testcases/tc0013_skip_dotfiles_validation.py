from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0013SkipDotfilesValidation(Wave1TestCaseBase):
    case_id = "0013"
    name = "skip_dotfiles validation"
    description = "Validate that dotfiles and dot-directories are excluded when skip_dotfiles is enabled"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        sync_root = case_work_dir / "syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(sync_root / root_name / ".hidden.txt", "hidden\n")
        self._create_text_file(sync_root / root_name / ".dotdir" / "inside.txt", "inside dotdir\n")
        self._create_text_file(sync_root / root_name / "visible.txt", "visible\n")
        self._create_text_file(sync_root / root_name / "normal" / "keep.md", "normal keep\n")
        conf_dir = self._new_config_dir(context, case_work_dir, "main")
        config_path, sync_list_path = self._write_config(conf_dir, extra_lines=['skip_dotfiles = "true"'], sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir)
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="skip_dotfiles"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"skip_dotfiles validation failed with status {result.returncode}", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "verify_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)
        snapshot = self._snapshot_files(verify_root)
        for required in [f"{root_name}/visible.txt", f"{root_name}/normal/keep.md"]:
            if required not in snapshot:
                return TestResult.fail_result(self.case_id, self.name, f"Expected visible content missing remotely: {required}", artifacts)
        for forbidden in [f"{root_name}/.hidden.txt", f"{root_name}/.dotdir/inside.txt"]:
            if forbidden in snapshot:
                return TestResult.fail_result(self.case_id, self.name, f"Dotfile content was unexpectedly synchronised: {forbidden}", artifacts)
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
