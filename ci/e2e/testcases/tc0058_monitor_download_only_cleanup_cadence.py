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
        "Validate monitor_authoritative_sync behaviour for --monitor --download-only "
        "and --cleanup-local-files using a local-only stale file and one monitor pass"
    )

    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"
    STALE_FILE_NAME = "tc0058-local-only-stale-file.txt"

    def _build_config_text(
        self,
        sync_dir: Path,
        app_log_dir: Path,
        *,
        monitor_authoritative_sync: str,
        monitor_interval: int,
        monitor_fullscan_frequency: int,
        monitor_max_loop: int,
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
            f'monitor_max_loop = "{monitor_max_loop}"\n'
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

    def _count_sync_complete_markers(self, log_file: Path) -> int:
        try:
            return log_file.read_text(errors="replace").count(self.SYNC_COMPLETE_PATTERN)
        except FileNotFoundError:
            return 0

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
        # Only seed a retained online anchor. The stale-file target is created
        # locally after preload and is intentionally never uploaded to OneDrive.
        # This prevents normal remote-delete/tombstone processing from masking
        # the --cleanup-local-files behaviour being tested.
        write_text_file(seed_root / root_name / "anchor.txt", f"TC0058 anchor for {root_name}\n")

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

    def _preload_monitor_fixture(
        self,
        context: E2EContext,
        *,
        root_name: str,
        monitor_root: Path,
        monitor_conf: Path,
        preload_stdout: Path,
        preload_stderr: Path,
    ):
        preload_command = [
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
            str(monitor_root),
            "--confdir",
            str(monitor_conf),
        ]
        context.log(f"Executing Test Case {self.case_id} preload {root_name}: {command_to_string(preload_command)}")
        preload_result = run_command(preload_command, cwd=context.repo_root)
        write_text_file(preload_stdout, preload_result.stdout)
        write_text_file(preload_stderr, preload_result.stderr)
        return preload_result

    def _run_policy_scenario(
        self,
        context: E2EContext,
        *,
        scenario_id: str,
        scenario_name: str,
        monitor_authoritative_sync: str,
        include_cleanup_local_files: bool,
        expect_cleanup_after_single_monitor_pass: bool,
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
        seed_conf = scenario_work / "conf-seed"
        monitor_conf = scenario_work / "conf-monitor"
        app_log_dir = scenario_logs / "app-logs"

        seed_stdout = scenario_logs / "seed_stdout.log"
        seed_stderr = scenario_logs / "seed_stderr.log"
        preload_stdout = scenario_logs / "preload_stdout.log"
        preload_stderr = scenario_logs / "preload_stderr.log"
        monitor_stdout = scenario_logs / "monitor_stdout.log"
        monitor_stderr = scenario_logs / "monitor_stderr.log"
        monitor_manifest_file = scenario_state / "monitor_manifest.txt"
        metadata_file = scenario_state / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(preload_stdout),
            str(preload_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(monitor_manifest_file),
            str(metadata_file),
            str(app_log_dir),
        ]

        monitor_interval = 300
        monitor_fullscan_frequency = 12
        monitor_max_loop = 1

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "monitor_authoritative_sync": monitor_authoritative_sync,
            "include_cleanup_local_files": include_cleanup_local_files,
            "monitor_interval": monitor_interval,
            "monitor_fullscan_frequency": monitor_fullscan_frequency,
            "monitor_max_loop": monitor_max_loop,
            "expect_cleanup_after_single_monitor_pass": expect_cleanup_after_single_monitor_pass,
            "seed_root": str(seed_root),
            "monitor_root": str(monitor_root),
            "stale_file_name": self.STALE_FILE_NAME,
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
                monitor_max_loop=monitor_max_loop,
            ),
        )

        preload_result = self._preload_monitor_fixture(
            context,
            root_name=root_name,
            monitor_root=monitor_root,
            monitor_conf=monitor_conf,
            preload_stdout=preload_stdout,
            preload_stderr=preload_stderr,
        )
        details["preload_returncode"] = preload_result.returncode
        if preload_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_name}: monitor preload failed with status {preload_result.returncode}", artifacts, details

        local_anchor = monitor_root / root_name / "anchor.txt"
        stale_local_file = monitor_root / root_name / self.STALE_FILE_NAME
        write_text_file(stale_local_file, f"TC0058 local-only stale file for {root_name}\n")

        details["local_anchor_exists_after_preload"] = local_anchor.is_file()
        details["stale_local_file_exists_after_injection"] = stale_local_file.is_file()

        if not local_anchor.is_file():
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_name}: preload did not download expected anchor file", artifacts, details

        if not stale_local_file.is_file():
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_name}: failed to inject local-only stale file", artifacts, details

        # Run exactly one monitor pass against a local-only stale file. There is
        # intentionally no remote mutator in this test: a real remote tombstone
        # would trigger ordinary remote-delete propagation, which happens even
        # when --cleanup-local-files is not enabled and does not validate this option.
        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--download-only",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(monitor_root),
            "--confdir",
            str(monitor_conf),
        ]
        if include_cleanup_local_files:
            monitor_command.insert(3, "--cleanup-local-files")

        context.log(f"Executing Test Case {self.case_id} monitor {scenario_name}: {command_to_string(monitor_command)}")

        process, monitor_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            startup_timeout_seconds=300,
        )

        try:
            details["monitor_sync_complete"] = monitor_sync_complete
            details["sync_complete_count_after_monitor"] = self._count_sync_complete_markers(monitor_stdout)

            if not monitor_sync_complete:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: monitor pass did not complete", artifacts, details

            if expect_cleanup_after_single_monitor_pass:
                removed = self._wait_for_path_absent(stale_local_file, timeout_seconds=30)
            else:
                # The completion marker should be emitted after the pass has
                # finished. A short grace period catches incorrect cleanup that
                # occurs immediately after the marker without waiting for another
                # 300-second monitor interval.
                time.sleep(5)
                removed = not stale_local_file.exists()

            details["stale_local_file_exists_after_single_monitor_pass"] = stale_local_file.exists()
            details["stale_local_file_removed_after_single_monitor_pass"] = removed
            details["local_anchor_exists_after_single_monitor_pass"] = local_anchor.is_file()

            monitor_manifest = build_manifest(monitor_root)
            write_manifest(monitor_manifest_file, monitor_manifest)
            details["monitor_manifest_entries"] = len(monitor_manifest)

            if expect_cleanup_after_single_monitor_pass and not removed:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: local-only stale file was not removed by the authoritative monitor pass", artifacts, details

            if not expect_cleanup_after_single_monitor_pass and removed:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: local-only stale file was removed when cleanup should have remained deferred/disabled", artifacts, details

            if not local_anchor.is_file():
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: retained anchor file disappeared during cleanup validation", artifacts, details

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
                "scenario_id": "MSIGNAL",
                "scenario_name": "monitor_and_signal cleanup enabled",
                "monitor_authoritative_sync": "monitor_and_signal",
                "include_cleanup_local_files": True,
                "expect_cleanup_after_single_monitor_pass": True,
            },
            {
                "scenario_id": "MINTERVAL",
                "scenario_name": "monitor_interval cleanup enabled",
                "monitor_authoritative_sync": "monitor_interval",
                "include_cleanup_local_files": True,
                "expect_cleanup_after_single_monitor_pass": True,
            },
            {
                "scenario_id": "MFULLSCAN",
                "scenario_name": "monitor_fullscan_frequency cleanup deferred",
                "monitor_authoritative_sync": "monitor_fullscan_frequency",
                "include_cleanup_local_files": True,
                "expect_cleanup_after_single_monitor_pass": False,
            },
            {
                "scenario_id": "NOCLEANUP",
                "scenario_name": "cleanup disabled control",
                "monitor_authoritative_sync": "monitor_and_signal",
                "include_cleanup_local_files": False,
                "expect_cleanup_after_single_monitor_pass": False,
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
