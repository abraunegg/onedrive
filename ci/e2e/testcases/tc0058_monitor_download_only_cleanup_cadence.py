from __future__ import annotations

import os
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0058MonitorDownloadOnlyCleanupCadence(MonitorModeTestCaseBase):
    case_id = "0058"
    name = "monitor download-only cleanup cadence"
    description = (
        "Validate monitor_authoritative_sync controls when --monitor --download-only "
        "--cleanup-local-files removes locally stale files after remote deletion"
    )

    def _build_config_text(
        self,
        sync_dir: Path,
        app_log_dir: Path,
        *,
        monitor_authoritative_sync: str,
        monitor_interval: int,
        monitor_fullscan_frequency: int,
    ) -> str:
        return (
            "# tc0058 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            f'monitor_interval = "{monitor_interval}"\n'
            f'monitor_fullscan_frequency = "{monitor_fullscan_frequency}"\n'
            f'monitor_authoritative_sync = "{monitor_authoritative_sync}"\n'
        )

    def _write_simple_config(self, config_file: Path, sync_dir: Path) -> None:
        write_text_file(
            config_file,
            (
                "# tc0058 helper config\n"
                f'sync_dir = "{sync_dir}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

    def _wait_for_path_absent(self, path: Path, timeout_seconds: int, poll_interval: float = 0.5) -> bool:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if not path.exists():
                return True
            time.sleep(poll_interval)
        return not path.exists()

    def _seed_remote_fixture(
        self,
        context: E2EContext,
        *,
        root_name: str,
        seed_root: Path,
        seed_conf: Path,
        seed_stdout: Path,
        seed_stderr: Path,
    ):
        write_text_file(seed_root / root_name / "anchor.txt", f"TC0058 anchor for {root_name}\n")
        write_text_file(
            seed_root / root_name / "delete-me.txt",
            f"TC0058 remote deletion target for {root_name}\n",
        )

        context.bootstrap_config_dir(seed_conf)
        self._write_simple_config(seed_conf / "config", seed_root)

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(seed_root),
            "--confdir",
            str(seed_conf),
        ]
        context.log(f"Executing Test Case {self.case_id} seed {root_name}: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        return seed_result

    def _delete_remote_fixture_file(
        self,
        context: E2EContext,
        *,
        root_name: str,
        mutator_root: Path,
        mutator_conf: Path,
        pull_stdout: Path,
        pull_stderr: Path,
        delete_stdout: Path,
        delete_stderr: Path,
    ):
        context.bootstrap_config_dir(mutator_conf)
        self._write_simple_config(mutator_conf / "config", mutator_root)

        pull_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(mutator_root),
            "--confdir",
            str(mutator_conf),
        ]
        context.log(f"Executing Test Case {self.case_id} mutator pull {root_name}: {command_to_string(pull_command)}")
        pull_result = run_command(pull_command, cwd=context.repo_root)
        write_text_file(pull_stdout, pull_result.stdout)
        write_text_file(pull_stderr, pull_result.stderr)

        delete_target = mutator_root / root_name / "delete-me.txt"
        if delete_target.exists():
            delete_target.unlink()

        delete_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(mutator_root),
            "--confdir",
            str(mutator_conf),
        ]
        context.log(f"Executing Test Case {self.case_id} mutator remote delete {root_name}: {command_to_string(delete_command)}")
        delete_result = run_command(delete_command, cwd=context.repo_root)
        write_text_file(delete_stdout, delete_result.stdout)
        write_text_file(delete_stderr, delete_result.stderr)
        return pull_result, delete_result, delete_target

    def _run_policy_scenario(
        self,
        context: E2EContext,
        *,
        scenario_id: str,
        scenario_name: str,
        monitor_authoritative_sync: str,
        monitor_interval: int,
        monitor_fullscan_frequency: int,
        expect_deferred_cleanup: bool,
        work_dir: Path,
        log_dir: Path,
        state_dir: Path,
    ) -> tuple[bool, str, list[str], dict[str, object]]:
        scenario_work = work_dir / scenario_id
        scenario_logs = log_dir / scenario_id
        scenario_state = state_dir / scenario_id
        scenario_work.mkdir(parents=True, exist_ok=True)
        scenario_logs.mkdir(parents=True, exist_ok=True)
        scenario_state.mkdir(parents=True, exist_ok=True)

        root_name = f"ZZ_E2E_TC0058_{scenario_id}_{context.run_id}_{os.getpid()}"
        seed_root = scenario_work / "seedroot"
        monitor_root = scenario_work / "monitorroot"
        mutator_root = scenario_work / "mutatorroot"
        seed_conf = scenario_work / "conf-seed"
        monitor_conf = scenario_work / "conf-monitor"
        mutator_conf = scenario_work / "conf-mutator"
        app_log_dir = scenario_logs / "app-logs"

        seed_stdout = scenario_logs / "seed_stdout.log"
        seed_stderr = scenario_logs / "seed_stderr.log"
        monitor_stdout = scenario_logs / "monitor_stdout.log"
        monitor_stderr = scenario_logs / "monitor_stderr.log"
        mutator_pull_stdout = scenario_logs / "mutator_pull_stdout.log"
        mutator_pull_stderr = scenario_logs / "mutator_pull_stderr.log"
        mutator_delete_stdout = scenario_logs / "mutator_delete_stdout.log"
        mutator_delete_stderr = scenario_logs / "mutator_delete_stderr.log"
        monitor_manifest_file = scenario_state / "monitor_manifest.txt"
        metadata_file = scenario_state / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(mutator_pull_stdout),
            str(mutator_pull_stderr),
            str(mutator_delete_stdout),
            str(mutator_delete_stderr),
            str(monitor_manifest_file),
            str(metadata_file),
            str(app_log_dir),
        ]

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "monitor_authoritative_sync": monitor_authoritative_sync,
            "monitor_interval": monitor_interval,
            "monitor_fullscan_frequency": monitor_fullscan_frequency,
            "expect_deferred_cleanup": expect_deferred_cleanup,
            "seed_root": str(seed_root),
            "monitor_root": str(monitor_root),
            "mutator_root": str(mutator_root),
        }

        seed_result = self._seed_remote_fixture(
            context,
            root_name=root_name,
            seed_root=seed_root,
            seed_conf=seed_conf,
            seed_stdout=seed_stdout,
            seed_stderr=seed_stderr,
        )
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_name}: seed phase failed with status {seed_result.returncode}", artifacts, details

        context.bootstrap_config_dir(monitor_conf)
        write_text_file(
            monitor_conf / "config",
            self._build_config_text(
                monitor_root,
                app_log_dir,
                monitor_authoritative_sync=monitor_authoritative_sync,
                monitor_interval=monitor_interval,
                monitor_fullscan_frequency=monitor_fullscan_frequency,
            ),
        )

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--download-only",
            "--cleanup-local-files",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(monitor_root),
            "--confdir",
            str(monitor_conf),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor {scenario_name}: {command_to_string(monitor_command)}")

        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            startup_timeout_seconds=180,
        )

        try:
            details["initial_sync_complete"] = initial_sync_complete
            local_anchor = monitor_root / root_name / "anchor.txt"
            local_delete_target = monitor_root / root_name / "delete-me.txt"

            details["local_anchor_exists_after_initial_sync"] = local_anchor.is_file()
            details["local_delete_target_exists_after_initial_sync"] = local_delete_target.is_file()

            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: monitor initial sync did not complete", artifacts, details

            if not local_anchor.is_file() or not local_delete_target.is_file():
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: monitor initial sync did not download expected fixture files", artifacts, details

            pull_result, delete_result, mutator_delete_target = self._delete_remote_fixture_file(
                context,
                root_name=root_name,
                mutator_root=mutator_root,
                mutator_conf=mutator_conf,
                pull_stdout=mutator_pull_stdout,
                pull_stderr=mutator_pull_stderr,
                delete_stdout=mutator_delete_stdout,
                delete_stderr=mutator_delete_stderr,
            )
            details["mutator_pull_returncode"] = pull_result.returncode
            details["mutator_delete_returncode"] = delete_result.returncode
            details["mutator_delete_target_exists_after_unlink"] = mutator_delete_target.exists()

            if pull_result.returncode != 0:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: mutator pull failed with status {pull_result.returncode}", artifacts, details

            if delete_result.returncode != 0:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: remote delete propagation failed with status {delete_result.returncode}", artifacts, details

            # Allow at least one monitor interval to run after the remote delete.
            # For monitor_fullscan_frequency cadence this should be a fast/non-authoritative pass,
            # so cleanup_local_files must not remove the local file yet.
            if expect_deferred_cleanup:
                time.sleep(monitor_interval + 3)
                details["local_delete_target_exists_after_first_interval"] = local_delete_target.exists()
                if not local_delete_target.exists():
                    self._write_metadata(metadata_file, details)
                    return (
                        False,
                        f"{scenario_name}: stale local file was removed before the authoritative full-scan cadence",
                        artifacts,
                        details,
                    )

            removed = self._wait_for_path_absent(
                local_delete_target,
                timeout_seconds=max(60, (monitor_interval * (monitor_fullscan_frequency + 2))),
            )
            details["local_delete_target_removed_by_monitor"] = removed
            details["local_anchor_exists_after_monitor_cleanup"] = local_anchor.is_file()

            monitor_manifest = build_manifest(monitor_root)
            write_manifest(monitor_manifest_file, monitor_manifest)
            details["monitor_manifest_entries"] = len(monitor_manifest)

            if not removed:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: stale local file was not removed by the expected authoritative cleanup cadence", artifacts, details

            if not local_anchor.is_file():
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: retained anchor file disappeared during cleanup cadence validation", artifacts, details

            self._write_metadata(metadata_file, details)
            return True, "", artifacts, details
        finally:
            self._shutdown_monitor_process(process, details)
            self._write_metadata(metadata_file, details)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0058",
            ensure_refresh_token=True,
        )

        scenarios = [
            {
                "scenario_id": "MSFREQ",
                "scenario_name": "monitor_fullscan_frequency cadence",
                "monitor_authoritative_sync": "monitor_fullscan_frequency",
                "monitor_interval": 6,
                "monitor_fullscan_frequency": 3,
                "expect_deferred_cleanup": True,
            },
            {
                "scenario_id": "MSIGNAL",
                "scenario_name": "monitor_and_signal immediate authoritative cleanup",
                "monitor_authoritative_sync": "monitor_and_signal",
                "monitor_interval": 6,
                "monitor_fullscan_frequency": 99,
                "expect_deferred_cleanup": False,
            },
        ]

        all_artifacts: list[str] = []
        scenario_details: dict[str, object] = {}
        failures: list[str] = []

        for scenario in scenarios:
            ok, reason, artifacts, details = self._run_policy_scenario(
                context,
                work_dir=layout.work_dir,
                log_dir=layout.log_dir,
                state_dir=layout.state_dir,
                **scenario,
            )
            all_artifacts.extend(artifacts)
            scenario_details[scenario["scenario_id"]] = details
            if not ok:
                failures.append(reason)

        details = {
            "scenarios_run": len(scenarios),
            "scenarios_failed": len(failures),
            "failures": failures,
            "scenario_details": scenario_details,
        }

        if failures:
            return self.fail_result(
                self.case_id,
                self.name,
                "; ".join(failures),
                all_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, all_artifacts, details)
