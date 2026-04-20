from __future__ import annotations

import signal
import subprocess
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.utils import run_command, write_text_file


class MonitorModeTestCaseBase(E2ETestCase):
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
        config_lines = [
            f"# tc{self.case_id} config",
            f'sync_dir = "{sync_dir}"',
            'bypass_data_preservation = "true"',
            'enable_logging = "true"',
            f'log_dir = "{app_log_dir}"',
            'monitor_interval = "5"',
            'monitor_fullscan_frequency = "1"',
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

    def _wait_for_initial_sync_complete(
        self,
        stdout_file: Path,
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds
        marker = "Sync with Microsoft OneDrive is complete"

        while time.time() < deadline:
            if marker in self._read_stdout(stdout_file):
                return True
            time.sleep(poll_interval)

        return False

    def _wait_for_monitor_patterns(
        self,
        stdout_file: Path,
        required_patterns: list[str],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> bool:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            content = self._read_stdout(stdout_file)
            if all(pattern in content for pattern in required_patterns):
                return True
            time.sleep(poll_interval)

        return False

    def _wait_for_any_monitor_pattern_group(
        self,
        stdout_file: Path,
        alternative_pattern_groups: list[list[str]],
        timeout_seconds: int = 120,
        poll_interval: float = 0.5,
    ) -> tuple[bool, int]:
        deadline = time.time() + timeout_seconds

        while time.time() < deadline:
            content = self._read_stdout(stdout_file)
            for idx, group in enumerate(alternative_pattern_groups):
                if all(pattern in content for pattern in group):
                    return True, idx
            time.sleep(poll_interval)

        return False, -1

    def _launch_monitor_process(
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
