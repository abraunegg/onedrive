from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0019LoggingAndRunningConfig(E2ETestCase):
    case_id = "0019"
    name = "logging and running config validation"
    description = "Validate custom log_dir output and display-running-config visibility"

    def _write_config(self, config_path: Path, app_log_dir: Path) -> None:
        write_text_file(
            config_path,
            "# tc0019 config\n"
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n',
        )

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0019"
        case_log_dir = context.logs_dir / "tc0019"
        state_dir = context.state_dir / "tc0019"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-main"
        root_name = f"ZZ_E2E_TC0019_{context.run_id}_{os.getpid()}"
        app_log_dir = case_log_dir / "app-logs"

        write_text_file(sync_root / root_name / "logging.txt", "log me\n")

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config", app_log_dir)

        stdout_file = case_log_dir / "logging_stdout.log"
        stderr_file = case_log_dir / "logging_stderr.log"
        metadata_file = state_dir / "metadata.txt"

        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(confdir),
        ]
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        log_entries = sorted(str(p.relative_to(app_log_dir)) for p in app_log_dir.rglob("*") if p.is_file()) if app_log_dir.exists() else []
        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"returncode={result.returncode}",
                ] + [f"log_file={entry}" for entry in log_entries]
            ) + "\n",
        )

        artifacts = [str(stdout_file), str(stderr_file), str(metadata_file)]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))
        details = {
            "returncode": result.returncode,
            "root_name": root_name,
            "log_file_count": len(log_entries),
        }

        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Logging validation failed with status {result.returncode}", artifacts, details)
        if not log_entries:
            return TestResult.fail_result(self.case_id, self.name, "No application log files were created in the configured log_dir", artifacts, details)

        stdout_lower = result.stdout.lower()
        if "display_running_config" not in stdout_lower and "log_dir" not in stdout_lower:
            return TestResult.fail_result(self.case_id, self.name, "display-running-config output did not expose the active runtime configuration", artifacts, details)

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
