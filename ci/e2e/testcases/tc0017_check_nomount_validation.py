from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0017CheckNomountValidation(E2ETestCase):
    case_id = "0017"
    name = "check_nomount validation"
    description = "Validate that check_nomount aborts synchronisation when .nosync exists in the sync_dir mount point"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0017 config\n"
            'bypass_data_preservation = "true"\n'
            'check_nomount = "true"\n',
        )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0017",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-main"
        root_name = f"ZZ_E2E_TC0017_{context.run_id}_{os.getpid()}"

        write_text_file(sync_root / ".nosync", "")
        write_text_file(sync_root / root_name / "should_not_upload.txt", "blocked by check_nomount\n")

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config")

        stdout_file = case_log_dir / "check_nomount_stdout.log"
        stderr_file = case_log_dir / "check_nomount_stderr.log"
        metadata_file = state_dir / "metadata.txt"

        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(confdir),
        ]
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"command={command_to_string(command)}",
                    f"returncode={result.returncode}",
                ]
            )
            + "\n",
        )

        artifacts = [str(stdout_file), str(stderr_file), str(metadata_file)]
        details = {
            "command": command,
            "returncode": result.returncode,
            "root_name": root_name,
        }

        combined_output = (result.stdout + "\n" + result.stderr).lower()

        if result.returncode == 0:
            return self.fail_result(
                self.case_id,
                self.name,
                "check_nomount did not abort synchronisation when .nosync existed in the sync_dir mount point",
                artifacts,
                details,
            )

        if ".nosync file found" not in combined_output and "aborting synchronization process to safeguard data" not in combined_output:
            return self.fail_result(
                self.case_id,
                self.name,
                "check_nomount did not emit the expected .nosync safeguard message",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
