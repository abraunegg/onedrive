from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0005ForceSyncOverride(Wave1TestCaseBase):
    case_id = "0005"
    name = "force-sync override"
    description = "Validate that --force-sync overrides skip_dir when using --single-directory"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []

        seed_root = case_work_dir / "seed-syncroot"
        seed_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(seed_root / root_name / "Blocked" / "blocked.txt", "blocked remote file\n")
        seed_conf = self._new_config_dir(context, case_work_dir, "seed")
        config_path, sync_list_path = self._write_config(seed_conf, sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        seed_result = self._run_onedrive(context, sync_root=seed_root, config_dir=seed_conf)
        artifacts.extend(self._write_command_artifacts(result=seed_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="seed"))
        if seed_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", artifacts)

        no_force_root = case_work_dir / "no-force-syncroot"
        no_force_root.mkdir(parents=True, exist_ok=True)
        no_force_conf = self._new_config_dir(context, case_work_dir, "no-force")
        config_path, sync_list_path = self._write_config(no_force_conf, extra_lines=['skip_dir = "Blocked"'], sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        no_force_result = self._run_onedrive(context, sync_root=no_force_root, config_dir=no_force_conf, extra_args=["--download-only", "--single-directory", f"{root_name}/Blocked"])
        artifacts.extend(self._write_command_artifacts(result=no_force_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="no_force"))
        if no_force_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Blocked single-directory sync without --force-sync failed with status {no_force_result.returncode}", artifacts)
        if (no_force_root / root_name / "Blocked" / "blocked.txt").exists():
            return TestResult.fail_result(self.case_id, self.name, "Blocked content was downloaded without --force-sync", artifacts)

        force_root = case_work_dir / "force-syncroot"
        force_root.mkdir(parents=True, exist_ok=True)
        force_conf = self._new_config_dir(context, case_work_dir, "force")
        config_path, sync_list_path = self._write_config(force_conf, extra_lines=['skip_dir = "Blocked"'], sync_list_entries=[f"/{root_name}"])
        artifacts.extend([str(config_path), str(sync_list_path)])
        force_result = self._run_onedrive(context, sync_root=force_root, config_dir=force_conf, extra_args=["--download-only", "--single-directory", f"{root_name}/Blocked", "--force-sync"])
        artifacts.extend(self._write_command_artifacts(result=force_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="force"))
        artifacts.extend(self._write_manifests(force_root, case_state_dir, "force_manifest"))
        if force_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Blocked single-directory sync with --force-sync failed with status {force_result.returncode}", artifacts)
        if not (force_root / root_name / "Blocked" / "blocked.txt").exists():
            return TestResult.fail_result(self.case_id, self.name, "Blocked content was not downloaded with --force-sync", artifacts)
        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
