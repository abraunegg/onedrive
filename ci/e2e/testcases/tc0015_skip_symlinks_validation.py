from __future__ import annotations

import os

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0015SkipSymlinksValidation(Wave1TestCaseBase):
    case_id = "0015"
    name = "skip_symlinks validation"
    description = "Validate that symbolic links are excluded when skip_symlinks is enabled"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        sync_root = case_work_dir / "syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        target_file = sync_root / root_name / "real.txt"
        self._create_text_file(target_file, "real content\n")
        symlink_path = sync_root / root_name / "real-link.txt"
        symlink_path.parent.mkdir(parents=True, exist_ok=True)
        os.symlink("real.txt", symlink_path)
        conf_dir = self._new_config_dir(context, case_work_dir, "main")
        config_path, sync_list_path = self._write_config(conf_dir, extra_lines=['skip_symlinks = "true"'], sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        artifacts.append(self._write_json_artifact(case_state_dir / "local_snapshot_pre.json", self._snapshot_files(sync_root)))
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir)
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="skip_symlinks"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"skip_symlinks validation failed with status {result.returncode}", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "verify_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)
        snapshot = self._snapshot_files(verify_root)
        if f"{root_name}/real.txt" not in snapshot:
            return TestResult.fail_result(self.case_id, self.name, "Real file is missing remotely", artifacts)
        if f"{root_name}/real-link.txt" in snapshot:
            return TestResult.fail_result(self.case_id, self.name, "Symbolic link was unexpectedly synchronised", artifacts)
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
