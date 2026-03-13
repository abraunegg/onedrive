from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0004SingleDirectorySync(Wave1TestCaseBase):
    case_id = "0004"
    name = "single-directory synchronisation"
    description = "Validate that only the nominated subtree is synchronised"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []

        sync_root = case_work_dir / "syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(sync_root / root_name / "Scoped" / "include.txt", "scoped file\n")
        self._create_text_file(sync_root / root_name / "Scoped" / "Nested" / "deep.txt", "nested scoped\n")
        self._create_text_file(sync_root / root_name / "Unscoped" / "exclude.txt", "should stay local only\n")

        config_dir = self._new_config_dir(context, case_work_dir, "main")
        config_path, sync_list_path = self._write_config(config_dir, sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=config_dir, extra_args=["--single-directory", f"{root_name}/Scoped"])
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="single_directory"))
        artifacts.extend(self._write_manifests(sync_root, case_state_dir, "local_after"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"--single-directory sync failed with status {result.returncode}", artifacts)

        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        artifacts.extend(self._write_manifests(verify_root, case_state_dir, "remote_manifest"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)

        snapshot = self._snapshot_files(verify_root)
        required = {
            f"{root_name}/Scoped",
            f"{root_name}/Scoped/include.txt",
            f"{root_name}/Scoped/Nested",
            f"{root_name}/Scoped/Nested/deep.txt",
        }
        missing = sorted(required - set(snapshot.keys()))
        if missing:
            return TestResult.fail_result(self.case_id, self.name, "Scoped content was not uploaded as expected", artifacts, {"missing": missing})
        if f"{root_name}/Unscoped/exclude.txt" in snapshot:
            return TestResult.fail_result(self.case_id, self.name, "Unscoped content was unexpectedly synchronised", artifacts)

        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
