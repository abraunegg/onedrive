from __future__ import annotations

import json
import os
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, compute_quickxor_hash_file, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class _MonitorStatusSampler:
    """Observe the client's atomically replaced status document during transfers."""

    def __init__(self, path: Path, evidence: Path):
        self.path = path
        self.evidence = evidence
        self.samples: list[dict[str, object]] = []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._sample, name="tc0091-status-sampler", daemon=True)

    def _sample(self) -> None:
        last_observation = None
        with self.evidence.open("w", encoding="utf-8") as log:
            while not self.stop_event.is_set():
                try:
                    document = json.loads(self.path.read_text(encoding="utf-8"))
                    if not isinstance(document, dict):
                        raise ValueError("status document is not an object")
                    process = document.get("process", {})
                    snapshot = {
                        "state": process.get("state"),
                        "pid": document.get("pid"),
                        "instance_id": document.get("instance_id"),
                        "monitor_loop": process.get("monitor_loop"),
                        "successful_cycle_count": document.get("sync", {}).get("successful_cycle_count"),
                        "last_cycle_result": document.get("sync", {}).get("last_cycle", {}).get("result"),
                        "updated_at": document.get("updated_at"),
                    }
                    observation = ("document", *snapshot.values())
                except (OSError, ValueError, TypeError, AttributeError) as error:
                    snapshot = {"read_error": type(error).__name__}
                    observation = ("read_error", type(error).__name__)
                if observation != last_observation:
                    entry = {"observed_at": datetime.now(timezone.utc).isoformat(),
                             "observed_monotonic": time.monotonic(), **snapshot}
                    self.samples.append(entry)
                    log.write(json.dumps(entry, sort_keys=True) + "\n")
                    log.flush()
                    last_observation = observation
                self.stop_event.wait(0.05)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=5)

    def current(self, pid: int) -> dict[str, object] | None:
        for entry in reversed(self.samples):
            if entry.get("pid") == pid and "state" in entry:
                return entry
        return None

    def observed(self, pid: int, state: str, since: int = 0) -> bool:
        return any(item.get("pid") == pid and item.get("state") == state
                   for item in self.samples[since:])


class TestCase0091MonitorRuntimeTelemetry(MonitorModeTestCaseBase):
    case_id = "0091"
    name = "monitor runtime telemetry state validation"
    description = (
        "Validate monitor-status.json during scheduled sync, inotify session upload "
        "and WebSocket-triggered download without changing scheduled-cycle counters"
    )

    SCENARIOS = ("RT-0001", "RT-0002", "RT-0003")
    PAYLOAD_BYTES = 16 * 1024 * 1024
    RATE_LIMIT = 1048576

    @staticmethod
    def _write_payload(path: Path, size: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        chunk = b"TC0091_TRANSFER_PAYLOAD_" * 4096
        with path.open("wb") as handle:
            while size:
                part = chunk[:min(size, len(chunk))]
                handle.write(part)
                size -= len(part)

    @staticmethod
    def _wait_status(sampler: _MonitorStatusSampler, pid: int, state: str,
                     timeout_seconds: int = 30, since: int = 0) -> dict[str, object] | None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            status = sampler.current(pid)
            if status is not None and status.get("state") == state and sampler.observed(pid, state, since):
                return status
            time.sleep(0.1)
        return None

    def _run_scenario(self, context: E2EContext, layout, scenario_id: str,
                      artifacts: list[str], details: dict[str, object]) -> str | None:
        work_dir = layout.work_dir / scenario_id
        log_dir = layout.log_dir / scenario_id
        state_dir = layout.state_dir / scenario_id
        for directory in (work_dir, log_dir, state_dir):
            directory.mkdir(parents=True, exist_ok=True)
        root_name = f"ZZ_E2E_TC0091_{context.run_id}_{os.getpid()}_{scenario_id.replace('-', '')}"
        sync_root = work_dir / "monitorroot"
        conf_monitor = work_dir / "conf-monitor"
        uploader_root = work_dir / "uploaderroot"
        conf_uploader = work_dir / "conf-uploader"
        verifier_root = work_dir / "verifyroot"
        conf_verify = work_dir / "conf-verify"
        app_logs = log_dir / "app-logs"
        stdout = log_dir / "monitor_stdout.log"
        stderr = log_dir / "monitor_stderr.log"
        metadata = state_dir / "metadata.txt"
        status_log = state_dir / "monitor_status_observations.jsonl"
        manifest_path = state_dir / "monitor_manifest.txt"
        artifacts.extend(str(p) for p in (stdout, stderr, metadata, status_log, manifest_path, app_logs))
        scenario_details: dict[str, object] = {"root_name": root_name, "scenario_id": scenario_id}
        details[scenario_id] = scenario_details
        conf_text = self._build_config_text(sync_root, app_logs, [
            'monitor_status = "true"', 'threads = "1"',
            f'rate_limit = "{self.RATE_LIMIT}"',
        ])
        if scenario_id == "RT-0003":
            conf_text = conf_text.replace(
                'disable_websocket_support = "true"', 'disable_websocket_support = "false"'
            )
        context.prepare_minimal_config_dir(conf_monitor, conf_text)
        # TC0059's independent uploader and verifier: no shared database, tokens or local tree.
        if scenario_id == "RT-0003":
            context.prepare_minimal_config_dir(conf_uploader, f'# tc0091 remote mutator\nsync_dir = "{uploader_root}"\n' 'bypass_data_preservation = "true"\n')
        if scenario_id in ("RT-0002", "RT-0003"):
            context.prepare_minimal_config_dir(conf_verify, f'# tc0091 independent verifier\nsync_dir = "{verifier_root}"\n' 'bypass_data_preservation = "true"\n')
        write_text_file(sync_root / root_name / "baseline.txt", f"TC0091 {scenario_id} initial sync\n")
        sampler = _MonitorStatusSampler(conf_monitor / "monitor-status.json", status_log)
        sampler.start()  # Before spawning monitor so initial scheduled-cycle activity is observable.
        command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--verbose",
                   "--resync", "--resync-auth", "--single-directory", root_name,
                   "--confdir", str(conf_monitor)]
        context.log(f"Executing TC0091 {scenario_id} monitor: {command_to_string(command)}")
        process = None
        try:
            process, ready = self._launch_monitor_process(context, command, stdout, stderr, startup_timeout_seconds=300)
            scenario_details["initial_sync_complete"] = ready
            if not ready:
                return "initial scheduled monitor sync did not complete"
            pid = process.pid
            initial = self._wait_status(sampler, pid, "idle", 30)
            scenario_details["initial_status"] = initial
            if initial is None:
                return "initial monitor cycle did not publish idle status"
            if initial.get("monitor_loop") != 1 or initial.get("successful_cycle_count") != 1 or initial.get("last_cycle_result") != "success":
                return "initial scheduled cycle counters/result are incorrect"
            if scenario_id == "RT-0001":
                scenario_details["scheduled_syncing_observed"] = sampler.observed(pid, "syncing")
                if not scenario_details["scheduled_syncing_observed"]:
                    return "scheduled monitor cycle never published syncing"
                return None

            if not self._wait_for_monitor_stdout_quiet(process, stdout, quiet_seconds=3, timeout_seconds=30):
                return "monitor did not settle after initial synchronisation"
            before = self._wait_status(sampler, pid, "idle", 10)
            if before is None:
                return "monitor was not idle before independent transfer"
            start_offset = self._prepare_monitor_for_local_mutation(process, stdout, scenario_details)
            start_index = len(sampler.samples)
            scenario_details["baseline_monitor_loop"] = before["monitor_loop"]
            scenario_details["baseline_successful_cycle_count"] = before["successful_cycle_count"]
            payload_rel = f"{root_name}/telemetry-transfer.bin"
            if scenario_id == "RT-0002":
                self._write_payload(sync_root / payload_rel, self.PAYLOAD_BYTES)
                expected_hash = compute_quickxor_hash_file(sync_root / payload_rel)
                required_pattern = f"Uploading new file: {payload_rel} ... done"
                transferred = self._wait_for_monitor_patterns(stdout, [required_pattern],
                                                              timeout_seconds=150, start_offset=start_offset,
                                                              poll_interval=0.25)
                scenario_details["upload_completed_marker"] = transferred
                if not transferred:
                    return "inotify-triggered session upload did not complete"
            else:
                # Follow TC0059: verify the WebSocket was enabled and a fresh signal
                # was received, rather than crediting a scheduled delta scan.
                pre_text = self._read_stdout(stdout) + self._read_stdout(stderr) + self._read_app_logs(app_logs)
                if "Enabled WebSocket support" not in pre_text:
                    return "WebSocket support was not enabled"
                signal_before = pre_text.count("signal(s) from WebSocket handler")
                self._write_payload(uploader_root / payload_rel, self.PAYLOAD_BYTES)
                expected_hash = compute_quickxor_hash_file(uploader_root / payload_rel)
                upload_cmd = [context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
                              "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                              "--confdir", str(conf_uploader)]
                context.log(f"Executing TC0091 independent remote upload: {command_to_string(upload_cmd)}")
                result = run_command(upload_cmd, cwd=context.repo_root)
                mutator_stdout = log_dir / "mutator_stdout.log"
                mutator_stderr = log_dir / "mutator_stderr.log"
                write_text_file(mutator_stdout, result.stdout)
                write_text_file(mutator_stderr, result.stderr)
                artifacts.extend((str(mutator_stdout), str(mutator_stderr)))
                scenario_details["mutator_returncode"] = result.returncode
                if result.returncode != 0:
                    return f"independent remote upload failed with status {result.returncode}"
                deadline = time.monotonic() + 180
                downloaded = False
                signal_seen = False
                while time.monotonic() < deadline and process.poll() is None:
                    now_text = self._read_stdout(stdout) + self._read_stdout(stderr) + self._read_app_logs(app_logs)
                    signal_seen = now_text.count("signal(s) from WebSocket handler") > signal_before
                    downloaded_path = sync_root / payload_rel
                    downloaded = downloaded_path.is_file() and downloaded_path.stat().st_size == self.PAYLOAD_BYTES
                    if signal_seen and downloaded:
                        break
                    time.sleep(0.25)
                scenario_details["websocket_signal_seen"] = signal_seen
                scenario_details["remote_downloaded"] = downloaded
                if not signal_seen or not downloaded:
                    return "remote download or the associated WebSocket signal was not observed"

            # A pre-existing idle snapshot must not satisfy completion: require a
            # fresh syncing observation followed by a subsequent idle transition.
            deadline = time.monotonic() + 30
            syncing_index = next((index for index in range(start_index, len(sampler.samples))
                                  if sampler.samples[index].get("pid") == pid
                                  and sampler.samples[index].get("state") == "syncing"), None)
            while syncing_index is None and time.monotonic() < deadline:
                time.sleep(0.1)
                syncing_index = next((index for index in range(start_index, len(sampler.samples))
                                      if sampler.samples[index].get("pid") == pid
                                      and sampler.samples[index].get("state") == "syncing"), None)
            scenario_details["syncing_observed_after_mutation"] = syncing_index is not None
            if syncing_index is None:
                return "client never published syncing while handling the independently triggered transfer"
            final = self._wait_status(sampler, pid, "idle", 30, since=syncing_index + 1)
            scenario_details["final_status"] = final
            if final is None:
                return "client did not restore idle after the observed syncing interval"
            if (final.get("monitor_loop") != before.get("monitor_loop") or
                    final.get("successful_cycle_count") != before.get("successful_cycle_count")):
                return "independent transfer incorrectly changed scheduled monitor-cycle counters"

            # Existing independent download-only verification pattern used by TC0052/TC0059.
            verifier_stdout = log_dir / "verify_stdout.log"
            verifier_stderr = log_dir / "verify_stderr.log"
            artifacts.extend((str(verifier_stdout), str(verifier_stderr)))
            verify_cmd = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                          "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                          "--confdir", str(conf_verify)]
            result = run_command(verify_cmd, cwd=context.repo_root)
            write_text_file(verifier_stdout, result.stdout)
            write_text_file(verifier_stderr, result.stderr)
            scenario_details["verify_returncode"] = result.returncode
            if result.returncode != 0:
                return f"independent remote verification failed with status {result.returncode}"
            verify_path = verifier_root / payload_rel
            if not verify_path.is_file() or verify_path.stat().st_size != self.PAYLOAD_BYTES:
                return "independent verification did not download the transferred payload"
            scenario_details["expected_quickxor_hash"] = expected_hash
            scenario_details["verified_quickxor_hash"] = compute_quickxor_hash_file(verify_path)
            if scenario_details["verified_quickxor_hash"] != expected_hash:
                return "independent verification payload hash does not match the source"
            return None
        finally:
            if process is not None:
                self._shutdown_monitor_process(process, scenario_details)
            sampler.stop()
            write_manifest(manifest_path, build_manifest(sync_root))
            scenario_details["status_sample_count"] = len(sampler.samples)
            self._write_metadata(metadata, scenario_details)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0091", ensure_refresh_token=True)
        details: dict[str, object] = {"executed_scenario_ids": []}
        artifacts: list[str] = [str(layout.state_dir / "metadata.txt")]
        for scenario_id in self.SCENARIOS:
            if not context.should_run_scenario(self.case_id, scenario_id):
                continue
            details["executed_scenario_ids"].append(scenario_id)
            try:
                error = self._run_scenario(context, layout, scenario_id, artifacts, details)
            except Exception as exc:
                error = f"unexpected harness exception: {type(exc).__name__}: {exc}"
            if error:
                self._write_metadata(layout.state_dir / "metadata.txt", details)
                return self.fail_result(reason=f"{scenario_id}: {error}", artifacts=artifacts, details=details)
        if not details["executed_scenario_ids"]:
            return self.fail_result(reason="No TC0091 scenarios selected/executed", artifacts=artifacts, details=details)
        self._write_metadata(layout.state_dir / "metadata.txt", details)
        return self.pass_result(artifacts=artifacts, details=details)
