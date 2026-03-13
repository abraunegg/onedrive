from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0014SkipSizeValidation(Wave1TestCaseBase):
    case_id = "0014"
    name = "skip_size validation"
    description = "Validate that files above the configured size threshold are excluded from synchronisation"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        sync_root = case_work_dir / "syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        self._create_binary_file(sync_root / root_name / "small.bin", 128 * 1024)
        self._create_binary_file(sync_root / root_name / "large.bin", 2 * 1024 * 1024)
        conf_dir = self._new_config_dir(context, case_work_dir, "main")
        config_path = self._write_config(conf_dir, extra_lines=['skip_size = "1"'])
        artifacts.append(str(config_path))
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir, extra_args=["--single-directory", root_name])
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="skip_size"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"skip_size validation failed with status {result.returncode}", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "verify_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)
        snapshot = self._snapshot_files(verify_root)
        if f"{root_name}/small.bin" not in snapshot:
            return TestResult.fail_result(self.case_id, self.name, "Small file is missing remotely", artifacts)
        if f"{root_name}/large.bin" in snapshot:
            return TestResult.fail_result(self.case_id, self.name, "Large file exceeded skip_size threshold but was synchronised", artifacts)
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
