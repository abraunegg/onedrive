from __future__ import annotations

import signal
import subprocess
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.utils import (
    STARTUP_RETRY_ATTEMPTS,
    STARTUP_RETRY_SLEEP_SECONDS,
    is_transient_startup_discovery_failure,
    run_command,
    write_text_file,
)


class MonitorModeTestCaseBase(E2ETestCase):
    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _build_config_text(
        self,
        sync_dir: Path,
        app_log_dir: Path,
        extra_config_lines: list[str] | None = None,
    ) -> str:
        """Build a monitor-mode config for local filesystem event tests.

        monitor_interval has an application-enforced minimum of 300 seconds.  These
        tests validate the local inotify/wake path, so do not try to shorten the
        scheduled monitor cadence and do not allow fullscan fallback to mask a
        missed local event.
        """
        config_lines = [
            f"# tc{self.case_id} config",
            f'sync_dir = "{sync_dir}"',
            'bypass_data_preservation = "true"',
            'enable_logging = "true"',
            f'log_dir = "{app_log_dir}"',
            'monitor_interval = "300"',
            'monitor_fullscan_frequency = "0"',
            'disable_websocket_support = "true"',
        ]
        if extra_config_lines:
            config_lines.extend(extra_config_lines)
        return "\n".join(config_lines) + "\n"

    def _read_stdout(self, stdout_file: Path) -> str:
        if not stdout_file.exists():
            return ""
        try:
            return stdout_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def _read_stdout_from_offset(self, stdout_file: Path, start_offset: int) -> str:
        content = self._read_stdout(stdout_file)
        if start_offset <= 0:
            return content
        if start_offset >= len(content):
            return ""
        return content[start_offset:]

    def _read_app_logs(self, app_log_dir: Path) -> str:
        if not app_log_dir.exists():
            return ""

        segments: list[str] = []
        for log_file in sorted(path for path in app_log_dir.rglob("*.log") if path.is_file()):
            try:
                segments.append(log_file.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
        return "\n".join(segments)

    def _read_app_logs_from_offset(self, app_log_dir: Path, start_offset: int) -> str:
        content = self._read_app_logs(app_log_dir)
        if start_offset <= 0:
            return content
        if start_offset >= len(content):
            return ""
        return content[start_offset:]

    def _monitor_app_log_dir_for_stdout(self, stdout_file: Path) -> Path:
        return stdout_file.parent / "app-logs"

    def _remember_monitor_app_log_offset(self, stdout_file: Path, offset: int) -> None:
        if not hasattr(self, "_monitor_app_log_start_offsets"):
            self._monitor_app_log_start_offsets = {}
        self._monitor_app_log_start_offsets[str(stdout_file)] = offset

    def _monitor_app_log_start_offset(self, stdout_file: Path) -> int:
        offsets = getattr(self, "_monitor_app_log_start_offsets", {})
        return int(offsets.get(str(stdout_file), 0))

    def _read_monitor_output_from_offsets(self, stdout_file: Path, stdout_start_offset: int) -> str:
        """Read post-mutation monitor evidence from stdout and the app log.

        Local monitor event processing does not always emit another global
        sync-complete marker after an inotify wake.  The stable evidence is the
        per-event upload/delete/move output, and that may be present in stdout,
        the configured application log, or both depending on verbosity and CI
        buffering.  Offset both streams so assertions only inspect activity that
        happened after the test mutation.
        """
        stdout_segment = self._read_stdout_from_offset(stdout_file, stdout_start_offset)
        app_log_dir = self._monitor_app_log_dir_for_stdout(stdout_file)
        app_log_segment = self._read_app_logs_from_offset(
            app_log_dir,
            self._monitor_app_log_start_offset(stdout_file),
        )
        if stdout_segment and app_log_segment:
            return stdout_segment + "\n" + app_log_segment
        return stdout_segment or app_log_segment

    def _wait_for_initial_sync_complete(
        self,
        stdout_file: Path,
        timeout_seconds: int = 300,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            if self.SYNC_COMPLETE_PATTERN in self._read_stdout(stdout_file):
                return True
            time.sleep(poll_interval)

        return False

    def _wait_for_monitor_stdout_quiet(
        self,
        process: subprocess.Popen[str],
        stdout_file: Path,
        *,
        quiet_seconds: float = 3.0,
        timeout_seconds: int = 30,
        poll_interval: float = 0.5,
    ) -> bool:
        """Wait until monitor stdout has stopped growing for a short period.

        This prevents local mutations being injected while the monitor is still
        emitting follow-up output immediately after the initial sync-complete marker.
        """
        deadline = time.time() + timeout_seconds
        last_size = -1
        quiet_started_at: float | None = None

        while time.time() < deadline:
            if process.poll() is not None:
                return False

            try:
                current_size = stdout_file.stat().st_size
            except OSError:
                current_size = 0

            now = time.time()
            if current_size != last_size:
                last_size = current_size
                quiet_started_at = now
            elif quiet_started_at is not None and now - quiet_started_at >= quiet_seconds:
                return True

            time.sleep(poll_interval)

        return False

    def _prepare_monitor_for_local_mutation(
        self,
        process: subprocess.Popen[str],
        stdout_file: Path,
        details: dict[str, object],
        *,
        quiet_seconds: float = 3.0,
        timeout_seconds: int = 30,
    ) -> int:
        """Wait for monitor readiness and return the post-mutation stdout offset."""
        ready = self._wait_for_monitor_stdout_quiet(
            process,
            stdout_file,
            quiet_seconds=quiet_seconds,
            timeout_seconds=timeout_seconds,
        )
        content = self._read_stdout(stdout_file)
        app_log_content = self._read_app_logs(self._monitor_app_log_dir_for_stdout(stdout_file))
        self._remember_monitor_app_log_offset(stdout_file, len(app_log_content))
        details["monitor_ready_after_initial_sync"] = ready
        details["initial_sync_complete_count_before_mutation"] = content.count(self.SYNC_COMPLETE_PATTERN)
        details["app_log_sync_complete_count_before_mutation"] = app_log_content.count(self.SYNC_COMPLETE_PATTERN)
        details["mutation_log_start_offset"] = len(content)
        details["mutation_app_log_start_offset"] = len(app_log_content)
        return len(content)

    def _wait_for_monitor_patterns(
        self,
        stdout_file: Path,
        required_patterns: list[str],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
        start_offset: int = 0,
    ) -> bool:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            content = self._read_monitor_output_from_offsets(stdout_file, start_offset)
            if all(pattern in content for pattern in required_patterns):
                return True
            time.sleep(poll_interval)

        return False

    def _wait_for_stdout_growth_patterns(
        self,
        stdout_file: Path,
        *,
        start_offset: int,
        required_patterns: list[str],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> tuple[bool, str]:
        deadline = time.time() + timeout_seconds
        latest_segment = ""

        while time.time() < deadline:
            latest_segment = self._read_monitor_output_from_offsets(stdout_file, start_offset)
            if all(pattern in latest_segment for pattern in required_patterns):
                return True, latest_segment
            time.sleep(poll_interval)

        return False, latest_segment

    def _wait_for_any_monitor_pattern_group(
        self,
        stdout_file: Path,
        alternative_pattern_groups: list[list[str]],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
        start_offset: int = 0,
    ) -> tuple[bool, int]:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            content = self._read_monitor_output_from_offsets(stdout_file, start_offset)
            for idx, group in enumerate(alternative_pattern_groups):
                if all(pattern in content for pattern in group):
                    return True, idx
            time.sleep(poll_interval)

        return False, -1

    def _wait_for_any_stdout_growth_pattern_group(
        self,
        stdout_file: Path,
        *,
        start_offset: int,
        alternative_pattern_groups: list[list[str]],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> tuple[bool, int, str]:
        deadline = time.time() + timeout_seconds
        latest_segment = ""

        while time.time() < deadline:
            latest_segment = self._read_monitor_output_from_offsets(stdout_file, start_offset)
            for idx, group in enumerate(alternative_pattern_groups):
                if all(pattern in latest_segment for pattern in group):
                    return True, idx, latest_segment
            time.sleep(poll_interval)

        return False, -1, latest_segment

    def _wait_for_required_patterns_and_any_group(
        self,
        stdout_file: Path,
        *,
        start_offset: int,
        required_patterns: list[str],
        alternative_pattern_groups: list[list[str]],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> tuple[bool, bool, int, str]:
        """Wait until all fixed patterns and one alternative group are observed."""
        deadline = time.time() + timeout_seconds
        latest_segment = ""
        matched_group = -1

        while time.time() < deadline:
            latest_segment = self._read_monitor_output_from_offsets(stdout_file, start_offset)
            fixed_ok = all(pattern in latest_segment for pattern in required_patterns)
            matched_group = -1
            for idx, group in enumerate(alternative_pattern_groups):
                if all(pattern in latest_segment for pattern in group):
                    matched_group = idx
                    break
            group_ok = matched_group >= 0
            if fixed_ok and group_ok:
                return True, True, matched_group, latest_segment
            time.sleep(poll_interval)

        fixed_ok = all(pattern in latest_segment for pattern in required_patterns)
        matched_group = -1
        for idx, group in enumerate(alternative_pattern_groups):
            if all(pattern in latest_segment for pattern in group):
                matched_group = idx
                break
        return fixed_ok, matched_group >= 0, matched_group, latest_segment

    def _wait_for_post_mutation_sync_complete(
        self,
        stdout_file: Path,
        *,
        start_offset: int,
        timeout_seconds: int = 180,
        poll_interval: float = 0.5,
        quiet_seconds_after_marker: float = 3.0,
    ) -> tuple[bool, str]:
        """Wait for a post-mutation global sync-complete marker when a test needs it.

        Most local inotify tests should not use this helper.  Local event handling
        can complete successfully without emitting another global sync-complete
        line, so those tests should wait for their event-specific patterns instead.
        """
        deadline = time.time() + timeout_seconds
        latest_segment = ""
        marker_seen = False
        last_length = -1
        quiet_started_at: float | None = None

        while time.time() < deadline:
            latest_segment = self._read_monitor_output_from_offsets(stdout_file, start_offset)
            now = time.time()

            if self.SYNC_COMPLETE_PATTERN in latest_segment:
                marker_seen = True

            current_length = len(latest_segment)
            if current_length != last_length:
                last_length = current_length
                quiet_started_at = now
            elif (
                marker_seen
                and quiet_started_at is not None
                and now - quiet_started_at >= quiet_seconds_after_marker
            ):
                return True, latest_segment

            time.sleep(poll_interval)

        return marker_seen, latest_segment

    def _launch_monitor_process_raw(
        self,
        context: E2EContext,
        monitor_command: list[str],
        monitor_stdout: Path,
        monitor_stderr: Path,
    ) -> subprocess.Popen[str]:
        stdout_fp = monitor_stdout.open("w", encoding="utf-8")
        stderr_fp = monitor_stderr.open("w", encoding="utf-8")
        process = subprocess.Popen(
            monitor_command,
            cwd=str(context.repo_root),
            stdout=stdout_fp,
            stderr=stderr_fp,
            text=True,
        )
        process._tc_stdout_fp = stdout_fp  # type: ignore[attr-defined]
        process._tc_stderr_fp = stderr_fp  # type: ignore[attr-defined]
        return process

    def _wait_for_initial_sync_complete_or_transient_failure(
        self,
        process: subprocess.Popen[str],
        stdout_file: Path,
        stderr_file: Path,
        timeout_seconds: int = 300,
        poll_interval: float = 0.5,
    ) -> str:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            stdout_content = self._read_stdout(stdout_file)
            stderr_content = self._read_stdout(stderr_file)

            if self.SYNC_COMPLETE_PATTERN in stdout_content:
                return "complete"

            if is_transient_startup_discovery_failure(stdout_content, stderr_content):
                return "transient_failure"

            if process.poll() is not None:
                return "process_exited"

            time.sleep(poll_interval)

        return "timeout"

    def _launch_monitor_process(
        self,
        context: E2EContext,
        monitor_command: list[str],
        monitor_stdout: Path,
        monitor_stderr: Path,
        *,
        startup_timeout_seconds: int = 300,
        startup_retry_attempts: int = STARTUP_RETRY_ATTEMPTS,
        startup_retry_sleep_seconds: float = STARTUP_RETRY_SLEEP_SECONDS,
    ) -> tuple[subprocess.Popen[str], bool]:
        last_process: subprocess.Popen[str] | None = None

        for attempt in range(1, startup_retry_attempts + 1):
            monitor_stdout.parent.mkdir(parents=True, exist_ok=True)
            monitor_stderr.parent.mkdir(parents=True, exist_ok=True)
            monitor_stdout.write_text("", encoding="utf-8")
            monitor_stderr.write_text("", encoding="utf-8")

            process = self._launch_monitor_process_raw(context, monitor_command, monitor_stdout, monitor_stderr)
            status = self._wait_for_initial_sync_complete_or_transient_failure(
                process,
                monitor_stdout,
                monitor_stderr,
                timeout_seconds=startup_timeout_seconds,
            )

            if status == "complete":
                return process, True

            self._shutdown_monitor_process(process, {})
            last_process = process

            if status != "transient_failure" or attempt >= startup_retry_attempts:
                return process, False

            time.sleep(startup_retry_sleep_seconds)

        assert last_process is not None
        return last_process, False

    def _shutdown_monitor_process(self, process: subprocess.Popen[str], details: dict[str, object]) -> None:
        try:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=30)
            details["monitor_returncode"] = process.returncode
        finally:
            stdout_fp = getattr(process, "_tc_stdout_fp", None)
            stderr_fp = getattr(process, "_tc_stderr_fp", None)
            if stdout_fp is not None:
                stdout_fp.close()
            if stderr_fp is not None:
                stderr_fp.close()

    def _run_verify_command(
        self,
        context: E2EContext,
        verify_command: list[str],
        verify_stdout: Path,
        verify_stderr: Path,
    ):
        result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, result.stdout)
        write_text_file(verify_stderr, result.stderr)
        return result

    def _write_file_with_exact_size(self, path: Path, size_bytes: int, header_text: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)

        header_bytes = header_text.encode("utf-8")
        if len(header_bytes) > size_bytes:
            raise ValueError(f"header_text is larger than requested file size for {path}")

        filler_size = size_bytes - len(header_bytes)
        filler_chunk = b"0123456789ABCDEF" * 4096

        with path.open("wb") as handle:
            handle.write(header_bytes)
            while filler_size > 0:
                chunk = filler_chunk[: min(len(filler_chunk), filler_size)]
                handle.write(chunk)
                filler_size -= len(chunk)
