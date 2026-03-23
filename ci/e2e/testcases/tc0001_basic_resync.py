from __future__ import annotations

from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0001BasicResync(E2ETestCase):
    """
    Test Case 0001: basic resync

    Purpose:
    - validate that the E2E framework can invoke the client
    - validate that the configured environment is sufficient to run a basic sync
    - provide a simple baseline smoke test before more advanced E2E scenarios
    """

    case_id = "0001"
    name = "basic resync"
    description = "Run a basic --sync --resync --resync-auth operation and capture the outcome"

    def run(self, context: E2EContext) -> TestResult:
        
        case_work_dir = context.work_root / f"tc{self.case_id}"
        case_log_dir = context.logs_dir / f"tc{self.case_id}"
        state_dir = context.state_dir / f"tc{self.case_id}"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        
        context.ensure_refresh_token_available()

        stdout_file = case_log_dir / "stdout.log"
        stderr_file = case_log_dir / "stderr.log"
        metadata_file = state_dir / "metadata.txt"

        command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
        ]

        context.log(
            f"Executing Test Case {self.case_id}: {command_to_string(command)}"
        )

        result = run_command(command, cwd=context.repo_root)

        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        metadata_lines = [
            f"case_id={self.case_id}",
            f"name={self.name}",
            f"command={command_to_string(command)}",
            f"returncode={result.returncode}",
        ]
        write_text_file(metadata_file, "\n".join(metadata_lines) + "\n")

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(metadata_file),
        ]

        details = {
            "command": command,
            "returncode": result.returncode,
        }

        if result.returncode != 0:
            reason = f"onedrive exited with non-zero status {result.returncode}"
            return TestResult.fail_result(
                case_id=self.case_id,
                name=self.name,
                reason=reason,
                artifacts=artifacts,
                details=details,
            )

        return TestResult.pass_result(
            case_id=self.case_id,
            name=self.name,
            artifacts=artifacts,
            details=details,
        )