from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0010UploadOnlyRemoveSourceFiles(Wave1TestCaseBase):
    case_id = "0010"
    name = "upload-only remove-source-files"
    description = "Validate that local files are removed after successful upload when remove_source_files is enabled"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        sync_root = case_work_dir / "upload-syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        source_file = sync_root / root_name / "Source" / "upload_and_remove.txt"
        self._create_text_file(source_file, "remove after upload\n")
        conf_dir = self._new_config_dir(context, case_work_dir, "upload")
        config_path, sync_list_path = self._write_config(conf_dir, extra_lines=['remove_source_files = "true"'], sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir, extra_args=["--upload-only"])
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="upload_only_remove_source"))
        artifacts.extend(self._write_manifests(sync_root, case_state_dir, "local_after"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"--upload-only with remove_source_files failed with status {result.returncode}", artifacts)
        if source_file.exists():
            return TestResult.fail_result(self.case_id, self.name, "Source file still exists locally after upload", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "verify_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)
        if not (verify_root / root_name / "Source" / "upload_and_remove.txt").exists():
            return TestResult.fail_result(self.case_id, self.name, "Uploaded file was not present remotely after local removal", artifacts)
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
