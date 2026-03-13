from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0008UploadOnly(Wave1TestCaseBase):
    case_id = "0008"
    name = "upload-only behaviour"
    description = "Validate that local content is uploaded when using --upload-only"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        sync_root = case_work_dir / "upload-syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(sync_root / root_name / "Upload" / "file.txt", "upload me\n")
        self._create_binary_file(sync_root / root_name / "Upload" / "blob.bin", 70 * 1024)
        conf_dir = self._new_config_dir(context, case_work_dir, "upload")
        config_path = self._write_config(conf_dir)
        artifacts.append(str(config_path))
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir, extra_args=["--upload-only"])
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="upload_only"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"--upload-only failed with status {result.returncode}", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "verify_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        artifacts.extend(self._write_manifests(verify_root, case_state_dir, "remote_manifest"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)
        verify_snapshot = self._snapshot_files(verify_root)
        expected = {f"{root_name}/Upload/file.txt", f"{root_name}/Upload/blob.bin"}
        missing = sorted(expected - set(verify_snapshot.keys()))
        if missing:
            return TestResult.fail_result(self.case_id, self.name, "Uploaded files were not present remotely", artifacts, {"missing": missing})
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
