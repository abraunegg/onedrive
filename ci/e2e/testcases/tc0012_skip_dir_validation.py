from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0012SkipDirValidation(Wave1TestCaseBase):
    case_id = "0012"
    name = "skip_dir validation"
    description = "Validate loose and strict skip_dir matching behaviour"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []
        failures = []

        loose_root = case_work_dir / "loose-syncroot"
        loose_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(loose_root / root_name / "project" / "build" / "out.bin", "skip me\n")
        self._create_text_file(loose_root / root_name / "build" / "root.bin", "skip me too\n")
        self._create_text_file(loose_root / root_name / "project" / "src" / "app.txt", "keep me\n")
        loose_conf = self._new_config_dir(context, case_work_dir, "loose")
        config_path, sync_list_path = self._write_config(loose_conf, extra_lines=['skip_dir = "build"', 'skip_dir_strict_match = "false"'], sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        loose_result = self._run_onedrive(context, sync_root=loose_root, config_dir=loose_conf)
        artifacts.extend(self._write_command_artifacts(result=loose_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="loose_match"))
        if loose_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Loose skip_dir scenario failed with status {loose_result.returncode}", artifacts)
        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "loose_remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="loose_verify"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Loose skip_dir verification failed with status {verify_result.returncode}", artifacts)
        loose_snapshot = self._snapshot_files(verify_root)
        if f"{root_name}/project/src/app.txt" not in loose_snapshot:
            failures.append("Loose matching did not retain non-build content")
        for forbidden in [f"{root_name}/project/build/out.bin", f"{root_name}/build/root.bin"]:
            if forbidden in loose_snapshot:
                failures.append(f"Loose matching did not exclude {forbidden}")

        strict_scope = f"{root_name}_STRICT"
        strict_root = case_work_dir / "strict-syncroot"
        strict_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(strict_root / strict_scope / "project" / "build" / "skip.bin", "skip strict\n")
        self._create_text_file(strict_root / strict_scope / "other" / "build" / "keep.bin", "keep strict\n")
        self._create_text_file(strict_root / strict_scope / "other" / "src" / "keep.txt", "keep strict txt\n")
        strict_conf = self._new_config_dir(context, case_work_dir, "strict")
        config_path, sync_list_path = self._write_config(strict_conf, extra_lines=[f'skip_dir = "{strict_scope}/project/build"', 'skip_dir_strict_match = "true"'], sync_list_entries=[f"/{strict_scope}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        strict_result = self._run_onedrive(context, sync_root=strict_root, config_dir=strict_conf)
        artifacts.extend(self._write_command_artifacts(result=strict_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="strict_match"))
        if strict_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Strict skip_dir scenario failed with status {strict_result.returncode}", artifacts)
        strict_verify_root, strict_verify_result, strict_verify_artifacts = self._download_remote_scope(context, case_work_dir, strict_scope, "strict_remote")
        artifacts.extend(strict_verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=strict_verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="strict_verify"))
        if strict_verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Strict skip_dir verification failed with status {strict_verify_result.returncode}", artifacts)
        strict_snapshot = self._snapshot_files(strict_verify_root)
        if f"{strict_scope}/project/build/skip.bin" in strict_snapshot:
            failures.append("Strict matching did not exclude the targeted full path")
        for required in [f"{strict_scope}/other/build/keep.bin", f"{strict_scope}/other/src/keep.txt"]:
            if required not in strict_snapshot:
                failures.append(f"Strict matching excluded unexpected content: {required}")
        artifacts.extend(self._write_manifests(verify_root, case_state_dir, "loose_manifest"))
        artifacts.extend(self._write_manifests(strict_verify_root, case_state_dir, "strict_manifest"))
        if failures:
            return TestResult.fail_result(self.case_id, self.name, "; ".join(failures), artifacts, {"failure_count": len(failures)})
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name, "strict_scope": strict_scope})
