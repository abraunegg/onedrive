from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0016CheckNosyncValidation(Wave1TestCaseBase):
    case_id = "0016"
    name = "check_nosync validation"
    description = "Validate that local directories containing .nosync are excluded when check_nosync is enabled"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        sync_root = case_work_dir / "syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(sync_root / root_name / "Blocked" / ".nosync", "marker\n")
        self._create_text_file(sync_root / root_name / "Blocked" / "blocked.txt", "blocked\n")
        self._create_text_file(sync_root / root_name / "Allowed" / "allowed.txt", "allowed\n")
        conf_dir = self._new_config_dir(context, case_work_dir, "main")
        config_path = self._write_config(conf_dir, extra_lines=['check_nosync = "true"'])
        artifacts.append(str(config_path))
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir)
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="check_nosync"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"check_nosync validation failed with status {result.returncode}", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "verify_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)
        snapshot = self._snapshot_files(verify_root)
        if f"{root_name}/Allowed/allowed.txt" not in snapshot:
            return TestResult.fail_result(self.case_id, self.name, "Allowed content is missing remotely", artifacts)
        for forbidden in [f"{root_name}/Blocked/blocked.txt", f"{root_name}/Blocked/.nosync"]:
            if forbidden in snapshot:
                return TestResult.fail_result(self.case_id, self.name, f".nosync-protected content was unexpectedly synchronised: {forbidden}", artifacts)
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
