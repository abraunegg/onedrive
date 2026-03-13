from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0007DownloadOnlyCleanupLocalFiles(Wave1TestCaseBase):
    case_id = "0007"
    name = "download-only cleanup-local-files"
    description = "Validate that stale local files are removed when cleanup_local_files is enabled"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        seed_root = case_work_dir / "seed-syncroot"
        seed_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(seed_root / root_name / "Keep" / "keep.txt", "keep\n")
        seed_conf = self._new_config_dir(context, case_work_dir, "seed")
        config_path, sync_list_path = self._write_config(seed_conf, sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        seed_result = self._run_onedrive(context, sync_root=seed_root, config_dir=seed_conf)
        artifacts.extend(self._write_command_artifacts(result=seed_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="seed"))
        if seed_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", artifacts)

        sync_root = case_work_dir / "cleanup-syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(sync_root / root_name / "Keep" / "keep.txt", "local keep placeholder\n")
        self._create_text_file(sync_root / root_name / "Obsolete" / "old.txt", "obsolete\n")
        conf_dir = self._new_config_dir(context, case_work_dir, "cleanup")
        config_path, sync_list_path = self._write_config(conf_dir, extra_lines=['cleanup_local_files = "true"'], sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        result = self._run_onedrive(context, sync_root=sync_root, config_dir=conf_dir, extra_args=["--download-only"])
        artifacts.extend(self._write_command_artifacts(result=result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="cleanup_download_only"))
        artifacts.extend(self._write_manifests(sync_root, case_state_dir, "local_after"))
        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Cleanup validation failed with status {result.returncode}", artifacts)
        if not (sync_root / root_name / "Keep" / "keep.txt").exists():
            return TestResult.fail_result(self.case_id, self.name, "Expected retained file is missing after cleanup", artifacts)
        if (sync_root / root_name / "Obsolete" / "old.txt").exists():
            return TestResult.fail_result(self.case_id, self.name, "Stale local file still exists after cleanup_local_files processing", artifacts)
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
