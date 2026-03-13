from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0011SkipFileValidation(Wave1TestCaseBase):
    case_id = "0011"
    name = "skip_file validation"
    description = "Validate that skip_file patterns exclude matching files from synchronisation"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        sync_root = case_work_dir / "syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(sync_root / root_name / "keep.txt", "keep me\n")
        self._create_text_file(sync_root / root_name / "ignore.tmp", "temp\n")
        self._create_text_file(sync_root / root_name / "editor.swp", "swap\n")
        self._create_text_file(sync_root / root_name / "Nested" / "keep.md", "nested keep\n")
        conf_dir = self._new_config_dir(context, case_work_dir, "main")
        config_path = self._write_config(conf_dir, extra_lines=['skip_file = "*.tmp|*.swp"'])
        artifacts.append(str(config_path))
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir)
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="skip_file"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"skip_file validation failed with status {result.returncode}", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "verify_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        artifacts.extend(self._write_manifests(verify_root, case_state_dir, "remote_manifest"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts)
        snapshot = self._snapshot_files(verify_root)
        expected = {f"{root_name}/keep.txt", f"{root_name}/Nested/keep.md"}
        missing = sorted(expected - set(snapshot.keys()))
        if missing:
            return TestResult.fail_result(self.case_id, self.name, "Expected non-skipped files are missing remotely", artifacts, {"missing": missing})
        present = sorted(path for path in [f"{root_name}/ignore.tmp", f"{root_name}/editor.swp"] if path in snapshot)
        if present:
            return TestResult.fail_result(self.case_id, self.name, "skip_file patterns did not exclude all matching files", artifacts, {"present": present})
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
