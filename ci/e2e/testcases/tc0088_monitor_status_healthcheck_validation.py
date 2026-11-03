from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class HealthcheckAssertionError(AssertionError):
    pass


class TestCase0088MonitorStatusHealthcheckValidation(MonitorModeTestCaseBase):
    case_id = "0088"
    name = "monitor status container healthcheck validation"
    description = (
        "Validate contrib/docker/healthcheck.sh against the monitor-status.json "
        "published by a real --monitor process across startup, staleness, abnormal "
        "termination, restart and orderly shutdown"
    )

    HEALTHCHECK_SCRIPT = Path("contrib") / "docker" / "healthcheck.sh"
    # The jq one-liner documented in docs/docker.md, with the status file
    # path passed as an argument instead of the container path.
    JQ_ONE_LINER = 'jq -e ".sync.initial_successful_sync_completed == true" "$1" || exit 1'
    HEALTHY_TIMEOUT_SECONDS = 120

    def _run_healthcheck(
        self,
        context: E2EContext,
        status_file: Path,
        *,
        max_age_seconds: int | None = None,
    ) -> tuple[int, str]:
        env = dict(os.environ)
        env["ONEDRIVE_HEALTHCHECK_STATUS_FILE"] = str(status_file)
        env.pop("ONEDRIVE_HEALTHCHECK_MAX_AGE", None)
        if max_age_seconds is not None:
            env["ONEDRIVE_HEALTHCHECK_MAX_AGE"] = str(max_age_seconds)

        result = subprocess.run(
            ["bash", str(context.repo_root / self.HEALTHCHECK_SCRIPT)],
            cwd=str(context.repo_root),
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.returncode, (result.stdout + result.stderr).strip()

    def _record_step(
        self,
        steps: list[dict[str, object]],
        state_dir: Path,
        status_file: Path,
        step: str,
        returncode: int,
        output: str,
    ) -> None:
        status_copy = state_dir / f"monitor-status_{step}.json"
        status_file_present = status_file.is_file()
        if status_file_present:
            shutil.copy2(status_file, status_copy)
        steps.append(
            {
                "step": step,
                "returncode": returncode,
                "output": output,
                "status_file_present": status_file_present,
            }
        )

    def _expect(self, condition: bool, reason: str) -> None:
        if not condition:
            raise HealthcheckAssertionError(reason)

    def _read_status_pid(self, status_file: Path) -> int | None:
        try:
            return json.loads(status_file.read_text(encoding="utf-8")).get("pid")
        except (OSError, ValueError):
            return None

    def _wait_for_healthy(
        self,
        context: E2EContext,
        steps: list[dict[str, object]],
        state_dir: Path,
        status_file: Path,
        step: str,
        pid: int,
    ) -> str:
        """Poll the healthcheck until it reports the monitor with this pid as healthy.

        The sync-complete console message can precede the status file update
        that marks the first cycle as successful, so a short window where the
        check still reports "starting" (or the file has not been published yet)
        is expected. Any other failure is a defect and is reported immediately.
        """
        deadline = time.time() + self.HEALTHY_TIMEOUT_SECONDS
        returncode, output = self._run_healthcheck(context, status_file)

        while returncode != 0 and time.time() < deadline:
            transient = output.startswith("starting: initial sync not yet completed") or (
                output.startswith("unhealthy:") and "not found" in output
            )
            if not transient:
                break
            time.sleep(1)
            returncode, output = self._run_healthcheck(context, status_file)

        self._record_step(steps, state_dir, status_file, step, returncode, output)
        self._expect(
            returncode == 0,
            f"{step}: healthcheck did not report healthy (exit {returncode}): {output}",
        )
        self._expect(
            output.startswith(f"healthy: pid={pid} "),
            f"{step}: healthcheck reported an unexpected monitor: {output} (expected pid {pid})",
        )
        status_pid = self._read_status_pid(status_file)
        self._expect(
            status_pid == pid,
            f"{step}: monitor-status.json pid is {status_pid}, expected the monitor pid {pid}",
        )
        return output

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0088",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-main"
        status_file = confdir / "monitor-status.json"
        root_name = f"ZZ_E2E_TC0088_{context.run_id}_{os.getpid()}"
        app_log_dir = case_log_dir / "app-logs"

        write_text_file(sync_root / root_name / "baseline.txt", "baseline\n")

        context.bootstrap_config_dir(confdir)
        write_text_file(confdir / "config", self._build_config_text(sync_root, app_log_dir))

        first_stdout = case_log_dir / "monitor_first_stdout.log"
        first_stderr = case_log_dir / "monitor_first_stderr.log"
        restart_stdout = case_log_dir / "monitor_restart_stdout.log"
        restart_stderr = case_log_dir / "monitor_restart_stderr.log"
        steps_file = state_dir / "healthcheck_steps.json"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(first_stdout),
            str(first_stderr),
            str(restart_stdout),
            str(restart_stderr),
            str(steps_file),
            str(metadata_file),
            str(state_dir),
        ]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        steps: list[dict[str, object]] = []
        details: dict[str, object] = {
            "root_name": root_name,
            "sync_root": str(sync_root),
            "conf_main": str(confdir),
            "status_file": str(status_file),
            "monitor_interval": 300,
            "websocket_disabled": True,
        }

        base_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(confdir),
        ]
        first_command = base_command[:4] + ["--resync", "--resync-auth"] + base_command[4:]
        # A restarted container runs the same command again, without --resync.
        restart_command = base_command

        if shutil.which("jq") is None:
            return self.fail_result(
                self.case_id,
                self.name,
                "jq is required by the healthcheck and is not installed",
                artifacts,
                details,
            )

        process = None
        try:
            # S01: before the monitor has started there is no status file.
            returncode, output = self._run_healthcheck(context, status_file)
            self._record_step(steps, state_dir, status_file, "s01_before_start", returncode, output)
            self._expect(
                returncode == 1 and "not found" in output,
                f"s01_before_start: expected 'not found' (exit 1), got exit {returncode}: {output}",
            )

            # S02: the first monitor becomes healthy once its initial sync completes.
            context.log(f"Executing Test Case {self.case_id}: {command_to_string(first_command)}")
            process, initial_sync_complete = self._launch_monitor_process(
                context, first_command, first_stdout, first_stderr
            )
            details["first_monitor_pid"] = process.pid
            details["first_initial_sync_complete"] = initial_sync_complete
            self._expect(
                initial_sync_complete,
                "Monitor mode did not complete the initial sync within the expected time",
            )
            self._wait_for_healthy(context, steps, state_dir, status_file, "s02_first_monitor_healthy", process.pid)

            # S03: the documented jq one-liner agrees with the script.
            one_liner = subprocess.run(
                ["sh", "-c", self.JQ_ONE_LINER, "sh", str(status_file)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self._record_step(
                steps,
                state_dir,
                status_file,
                "s03_jq_one_liner",
                one_liner.returncode,
                (one_liner.stdout + one_liner.stderr).strip(),
            )
            self._expect(
                one_liner.returncode == 0,
                f"s03_jq_one_liner: expected exit 0, got {one_liner.returncode}",
            )

            # S04: the status file is only republished at cycle boundaries, so
            # with a 300 second monitor_interval it ages between cycles and a
            # short maximum age must report it as stale.
            time.sleep(3)
            returncode, output = self._run_healthcheck(context, status_file, max_age_seconds=1)
            self._record_step(steps, state_dir, status_file, "s04_stale_max_age", returncode, output)
            self._expect(
                returncode == 1 and "monitor loop may be stuck" in output,
                f"s04_stale_max_age: expected a stale status file (exit 1), got exit {returncode}: {output}",
            )

            # S05: an abnormal termination leaves the status file behind, and
            # the healthcheck must not trust it.
            killed_pid = process.pid
            process.kill()
            process.wait(timeout=30)
            self._shutdown_monitor_process(process, details)
            details["first_monitor_returncode"] = process.returncode
            process = None
            self._expect(
                status_file.is_file(),
                "s05_after_sigkill: the killed monitor did not leave its status file behind",
            )
            returncode, output = self._run_healthcheck(context, status_file)
            self._record_step(steps, state_dir, status_file, "s05_after_sigkill", returncode, output)
            self._expect(
                returncode == 1 and f"monitor pid {killed_pid} from status file is not running" in output,
                f"s05_after_sigkill: expected pid {killed_pid} to be reported as not running (exit 1), "
                f"got exit {returncode}: {output}",
            )

            # S06: a restarted monitor replaces the leftover file and becomes
            # healthy under its own pid. Outside a container the new process
            # always has a different pid; the container case, where the client
            # is pid 1 both before and after the restart, is covered by the
            # process start time check in the script and cannot be reproduced
            # here.
            context.log(f"Restarting monitor for Test Case {self.case_id}: {command_to_string(restart_command)}")
            process, restart_sync_complete = self._launch_monitor_process(
                context, restart_command, restart_stdout, restart_stderr
            )
            details["restart_monitor_pid"] = process.pid
            details["restart_initial_sync_complete"] = restart_sync_complete
            self._expect(
                restart_sync_complete,
                "Restarted monitor did not complete its initial sync within the expected time",
            )
            self._wait_for_healthy(context, steps, state_dir, status_file, "s06_restarted_monitor_healthy", process.pid)

            # S07: an orderly shutdown removes the status file.
            self._shutdown_monitor_process(process, details)
            process = None
            self._expect(
                not status_file.exists(),
                "s07_after_shutdown: monitor-status.json was not removed by an orderly shutdown",
            )
            returncode, output = self._run_healthcheck(context, status_file)
            self._record_step(steps, state_dir, status_file, "s07_after_shutdown", returncode, output)
            self._expect(
                returncode == 1 and "not found" in output,
                f"s07_after_shutdown: expected 'not found' (exit 1), got exit {returncode}: {output}",
            )
        except HealthcheckAssertionError as error:
            details["failure"] = str(error)
            return self.fail_result(self.case_id, self.name, str(error), artifacts, details)
        finally:
            if process is not None:
                self._shutdown_monitor_process(process, details)
            write_text_file(steps_file, json.dumps(steps, indent=2) + "\n")
            details["steps_completed"] = [step["step"] for step in steps]
            self._write_metadata(metadata_file, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)
