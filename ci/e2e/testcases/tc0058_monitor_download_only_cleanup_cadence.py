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
        "--cleanup-local-files using one debug-logged monitor pass per policy mode"
    )

    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"
    REMOTE_DELETE_FILE_NAME = "delete-me.txt"
    LOCAL_ONLY_STALE_FILE_NAME = "tc0058-local-only-stale-file.txt"

    def _build_config_text(
        self,
        sync_dir: Path,
        app_log_dir: Path,
        *,
        monitor_authoritative_sync: str,
        monitor_interval: int = 300,
        monitor_fullscan_frequency: int = 12,
        monitor_max_loop: int = 1,
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
        write_text_file(seed_root / root_name / "anchor.txt", f"TC0058 anchor for {root_name}\n")
        write_text_file(
            seed_root / root_name / self.REMOTE_DELETE_FILE_NAME,
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

        delete_target = mutator_root / root_name / self.REMOTE_DELETE_FILE_NAME
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
        include_cleanup_local_files: bool,
        stimulus: str,
        expect_target_removed_after_single_monitor_pass: bool,
        enforce_target_state: bool,
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
        preload_stdout = scenario_logs / "preload_stdout.log"
        preload_stderr = scenario_logs / "preload_stderr.log"
        mutator_pull_stdout = scenario_logs / "mutator_pull_stdout.log"
        mutator_pull_stderr = scenario_logs / "mutator_pull_stderr.log"
        mutator_delete_stdout = scenario_logs / "mutator_delete_stdout.log"
        mutator_delete_stderr = scenario_logs / "mutator_delete_stderr.log"
        monitor_stdout = scenario_logs / "monitor_stdout.log"
        monitor_stderr = scenario_logs / "monitor_stderr.log"
        monitor_manifest_file = scenario_state / "monitor_manifest.txt"
        metadata_file = scenario_state / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(preload_stdout),
            str(preload_stderr),
            str(mutator_pull_stdout),
            str(mutator_pull_stderr),
            str(mutator_delete_stdout),
            str(mutator_delete_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(monitor_manifest_file),
            str(metadata_file),
            str(app_log_dir),
        ]

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "monitor_authoritative_sync": monitor_authoritative_sync,
            "include_cleanup_local_files": include_cleanup_local_files,
            "stimulus": stimulus,
            "monitor_interval": 300,
            "monitor_fullscan_frequency": 12,
            "monitor_max_loop": 1,
            "expect_target_removed_after_single_monitor_pass": expect_target_removed_after_single_monitor_pass,
            "enforce_target_state": enforce_target_state,
            "seed_root": str(seed_root),
            "monitor_root": str(monitor_root),
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
        remote_delete_target = monitor_root / root_name / self.REMOTE_DELETE_FILE_NAME
        local_only_target = monitor_root / root_name / self.LOCAL_ONLY_STALE_FILE_NAME

        details["local_anchor_exists_after_preload"] = local_anchor.is_file()
        details["remote_delete_target_exists_after_preload"] = remote_delete_target.is_file()
        if not local_anchor.is_file() or not remote_delete_target.is_file():
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_name}: preload did not download expected fixture files", artifacts, details

        if stimulus == "remote_delete":
            # This is the valid stimulus for monitor_authoritative_sync. The file is
            # DB-known locally, then removed online by an independent mutator. An
            # authoritative monitor pass should remove it locally; a native /delta
            # pass in monitor_fullscan_frequency mode should defer the tombstone.
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
            target_path = remote_delete_target
        elif stimulus == "local_only":
            # This control deliberately avoids a real remote delete. Remote tombstones
            # are normal sync activity and may remove local files even when
            # --cleanup-local-files is disabled, so the disabled-control case uses a
            # local-only file that has never existed online.
            write_text_file(local_only_target, f"TC0058 local-only stale file for {root_name}\n")
            details["local_only_target_exists_after_injection"] = local_only_target.is_file()
            if not local_only_target.is_file():
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: failed to inject local-only stale file", artifacts, details
            target_path = local_only_target
        else:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_name}: invalid stimulus '{stimulus}'", artifacts, details

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--download-only",
            "--verbose",
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

            if expect_target_removed_after_single_monitor_pass:
                removed = self._wait_for_path_absent(target_path, timeout_seconds=30)
            else:
                time.sleep(5)
                removed = not target_path.exists()

            details["target_path"] = str(target_path)
            details["target_exists_after_single_monitor_pass"] = target_path.exists()
            details["target_removed_after_single_monitor_pass"] = removed
            details["local_anchor_exists_after_single_monitor_pass"] = local_anchor.is_file()

            # These policy markers are DEBUG-level messages. The monitor command
            # intentionally uses --verbose twice above so that they are emitted in
            # normal CI, not only in the framework's debug rerun. Read both process
            # stdout/stderr and the application log because logging destinations can
            # differ across harness/debug paths.
            monitor_log_text_parts: list[str] = []
            for candidate in (monitor_stdout, monitor_stderr, app_log_dir / "root.onedrive.log"):
                try:
                    monitor_log_text_parts.append(candidate.read_text(errors="replace"))
                except FileNotFoundError:
                    pass
            monitor_log_text = "\n".join(monitor_log_text_parts)

            authoritative_marker = "Unsetting fullScanTrueUpRequired after authoritative cleanup pass"
            deferred_marker = "Using native /delta for this pass; authoritative cleanup deferred until monitor full-scan cadence"
            full_scan_true_marker = "Perform a Full Scan True-Up: true"

            details["authoritative_cleanup_marker_seen"] = authoritative_marker in monitor_log_text
            details["deferred_cleanup_marker_seen"] = deferred_marker in monitor_log_text
            details["full_scan_true_marker_seen"] = full_scan_true_marker in monitor_log_text
            details["monitor_log_text_bytes_checked"] = len(monitor_log_text)

            monitor_manifest = build_manifest(monitor_root)
            write_manifest(monitor_manifest_file, monitor_manifest)
            details["monitor_manifest_entries"] = len(monitor_manifest)

            if monitor_authoritative_sync in ("monitor_and_signal", "monitor_interval") and include_cleanup_local_files:
                if authoritative_marker not in monitor_log_text or full_scan_true_marker not in monitor_log_text:
                    self._write_metadata(metadata_file, details)
                    return False, f"{scenario_name}: expected authoritative cleanup monitor pass was not logged", artifacts, details

            if monitor_authoritative_sync == "monitor_fullscan_frequency" and include_cleanup_local_files:
                if deferred_marker not in monitor_log_text:
                    self._write_metadata(metadata_file, details)
                    return False, f"{scenario_name}: expected deferred native /delta monitor pass was not logged", artifacts, details
                if authoritative_marker in monitor_log_text or full_scan_true_marker in monitor_log_text:
                    self._write_metadata(metadata_file, details)
                    return False, f"{scenario_name}: unexpected authoritative cleanup/full-scan marker was logged", artifacts, details

            if enforce_target_state and expect_target_removed_after_single_monitor_pass and not removed:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: target file was not removed by the authoritative monitor pass", artifacts, details
            if enforce_target_state and not expect_target_removed_after_single_monitor_pass and removed:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_name}: target file was removed when cleanup should have remained deferred/disabled", artifacts, details
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
                "stimulus": "remote_delete",
                "expect_target_removed_after_single_monitor_pass": True,
                "enforce_target_state": True,
            },
            {
                "scenario_id": "MINTERVAL",
                "scenario_name": "monitor_interval cleanup enabled",
                "monitor_authoritative_sync": "monitor_interval",
                "include_cleanup_local_files": True,
                "stimulus": "remote_delete",
                "expect_target_removed_after_single_monitor_pass": True,
                "enforce_target_state": True,
            },
            {
                "scenario_id": "MFULLSCAN",
                "scenario_name": "monitor_fullscan_frequency cleanup deferred",
                "monitor_authoritative_sync": "monitor_fullscan_frequency",
                "include_cleanup_local_files": True,
                "stimulus": "remote_delete",
                "expect_target_removed_after_single_monitor_pass": False,
                "enforce_target_state": False,
            },
            {
                "scenario_id": "NOCLEANUP",
                "scenario_name": "cleanup disabled control",
                "monitor_authoritative_sync": "monitor_and_signal",
                "include_cleanup_local_files": False,
                "stimulus": "local_only",
                "expect_target_removed_after_single_monitor_pass": False,
                "enforce_target_state": True,
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
