from __future__ import annotations

from framework.result import TestResult
from testcases.wave1_common import Wave1TestCaseBase


class TestCase0003DryRunValidation(Wave1TestCaseBase):
    case_id = "0003"
    name = "dry-run validation"
    description = "Validate that --dry-run performs no local or remote changes"

    def run(self, context):
        case_work_dir, case_log_dir, case_state_dir = self._initialise_case_dirs(context)
        root_name = self._root_name(context)
        artifacts = []

        seed_root = case_work_dir / "seed-syncroot"
        seed_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(seed_root / root_name / "Remote" / "online.txt", "online baseline\n")
        self._create_text_file(seed_root / root_name / "Remote" / "keep.txt", "keep baseline\n")
        self._create_binary_file(seed_root / root_name / "Data" / "payload.bin", 64 * 1024)

        seed_config_dir = self._new_config_dir(context, case_work_dir, "seed")
        config_path = self._write_config(seed_config_dir)
        artifacts.append(str(config_path))
        seed_result = self._run_onedrive(context, sync_root=seed_root, config_dir=seed_config_dir)
        artifacts.extend(self._write_command_artifacts(result=seed_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="seed"))
        artifacts.extend(self._write_manifests(seed_root, case_state_dir, "seed_local"))
        if seed_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", artifacts, {"phase": "seed"})

        dry_root = case_work_dir / "dryrun-syncroot"
        dry_root.mkdir(parents=True, exist_ok=True)
        self._create_text_file(dry_root / root_name / "LocalOnly" / "draft.txt", "local only\n")
        self._create_text_file(dry_root / root_name / "Remote" / "keep.txt", "locally modified but should not upload\n")
        pre_snapshot = self._snapshot_files(dry_root)
        artifacts.append(self._write_json_artifact(case_state_dir / "pre_snapshot.json", pre_snapshot))

        dry_config_dir = self._new_config_dir(context, case_work_dir, "dryrun")
        config_path = self._write_config(dry_config_dir)
        artifacts.append(str(config_path))
        dry_result = self._run_onedrive(context, sync_root=dry_root, config_dir=dry_config_dir, extra_args=["--dry-run"])
        artifacts.extend(self._write_command_artifacts(result=dry_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="dry_run"))
        post_snapshot = self._snapshot_files(dry_root)
        artifacts.append(self._write_json_artifact(case_state_dir / "post_snapshot.json", post_snapshot))

        if dry_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Dry-run exited with status {dry_result.returncode}", artifacts, {"phase": "dry-run"})
        if pre_snapshot != post_snapshot:
            return TestResult.fail_result(self.case_id, self.name, "Local filesystem changed during --dry-run", artifacts, {"phase": "dry-run"})

        verify_root, verify_result, verify_artifacts = self._download_remote_scope(context, case_work_dir, root_name, "remote")
        artifacts.extend(verify_artifacts)
        artifacts.extend(self._write_command_artifacts(result=verify_result, log_dir=case_log_dir, state_dir=case_state_dir, phase_name="verify_remote"))
        artifacts.extend(self._write_manifests(verify_root, case_state_dir, "verify_remote"))
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification download failed with status {verify_result.returncode}", artifacts)

        downloaded = set(self._snapshot_files(verify_root).keys())
        expected_present = {
            f"{root_name}/Remote",
            f"{root_name}/Remote/online.txt",
            f"{root_name}/Remote/keep.txt",
            f"{root_name}/Data",
            f"{root_name}/Data/payload.bin",
        }
        unexpected_absent = sorted(expected_present - downloaded)
        if unexpected_absent:
            return TestResult.fail_result(self.case_id, self.name, "Remote baseline changed after --dry-run", artifacts, {"missing": unexpected_absent})
        if f"{root_name}/LocalOnly/draft.txt" in downloaded:
            return TestResult.fail_result(self.case_id, self.name, "Local-only file was uploaded during --dry-run", artifacts)

        return TestResult.pass_result(self.case_id, self.name, artifacts, {"root_name": root_name})
