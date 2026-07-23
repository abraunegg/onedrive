from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0025InvalidCharacterFilenameValidation(E2ETestCase):
    case_id = "0025"
    name = "invalid character filename validation"
    description = "Validate invalid filename characters are blocked while valid sibling files still synchronise"

    def _write_config(self, config_path: Path, sync_dir: Path) -> None:
        write_onedrive_config(
            config_path,
            "\n".join(
                [
                    "# tc0025 config",
                    f'sync_dir = "{sync_dir}"',
                    'bypass_data_preservation = "true"',
                    'classify_as_big_delete = "1000"',
                ]
            )
            + "\n",
        )

    def _create_binary_file(self, path: Path, size_kb: int = 8) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = os.urandom(size_kb * 1024)
        path.write_bytes(payload)

    def _run_and_capture(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0025",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        confdir = case_work_dir / "conf-main"
        verify_conf = case_work_dir / "conf-verify"

        reset_directory(sync_root)
        reset_directory(verify_root)

        context.bootstrap_config_dir(confdir)
        context.bootstrap_config_dir(verify_conf)

        self._write_config(confdir / "config", sync_root)
        self._write_config(verify_conf / "config", verify_root)

        root_name = f"ZZ_E2E_TC0025_{context.run_id}_{os.getpid()}"

        valid_files = [
            f"{root_name}/valid_file_1.bin",
            f"{root_name}/valid_file_2.txt",
            f"{root_name}/valid_subdir/nested_valid_file.dat",
        ]

        invalid_files = [
            f"{root_name}/includes < in the filename",
            f"{root_name}/includes > in the filename",
            f'{root_name}/includes " in the filename',
            f"{root_name}/includes | in the filename",
            f"{root_name}/includes ? in the filename",
            f"{root_name}/includes * in the filename",
        ]

        for rel_path in valid_files + invalid_files:
            self._create_binary_file(sync_root / rel_path, size_kb=8)

        initial_stdout = case_log_dir / "initial_sync_stdout.log"
        initial_stderr = case_log_dir / "initial_sync_stderr.log"

        second_stdout = case_log_dir / "second_sync_stdout.log"
        second_stderr = case_log_dir / "second_sync_stderr.log"

        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"

        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        initial_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--confdir",
            str(confdir),
        ]
        initial_result = self._run_and_capture(
            context,
            "initial sync",
            initial_command,
            initial_stdout,
            initial_stderr,
        )

        second_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--confdir",
            str(confdir),
        ]
        second_result = self._run_and_capture(
            context,
            "second sync",
            second_command,
            second_stdout,
            second_stderr,
        )

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--confdir",
            str(verify_conf),
        ]
        verify_result = self._run_and_capture(
            context,
            "remote verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        combined_output = (
            initial_result.stdout
            + "\n"
            + initial_result.stderr
            + "\n"
            + second_result.stdout
            + "\n"
            + second_result.stderr
        )

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"initial_returncode={initial_result.returncode}",
                    f"second_returncode={second_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"valid_files={valid_files!r}",
                    f"invalid_files={invalid_files!r}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(initial_stdout),
            str(initial_stderr),
            str(second_stdout),
            str(second_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details = {
            "initial_returncode": initial_result.returncode,
            "second_returncode": second_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        for label, rc in [
            ("initial sync", initial_result.returncode),
            ("second sync", second_result.returncode),
            ("remote verification", verify_result.returncode),
        ]:
            if rc != 0:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} failed with status {rc}",
                    artifacts,
                    details,
                )

        for expected in valid_files:
            if expected not in remote_manifest:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Expected valid file missing remotely: {expected}",
                    artifacts,
                    details,
                )

        for unwanted in invalid_files:
            if unwanted in remote_manifest:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Invalid filename was synchronised remotely: {unwanted}",
                    artifacts,
                    details,
                )

        expected_skip_markers = [
            'Skipping item - invalid name (Microsoft Naming Convention): ./'
            + f"{root_name}/includes < in the filename",
            'Skipping item - invalid name (Microsoft Naming Convention): ./'
            + f"{root_name}/includes > in the filename",
            'Skipping item - invalid name (Microsoft Naming Convention): ./'
            + f'{root_name}/includes " in the filename',
            'Skipping item - invalid name (Microsoft Naming Convention): ./'
            + f"{root_name}/includes | in the filename",
            'Skipping item - invalid name (Microsoft Naming Convention): ./'
            + f"{root_name}/includes ? in the filename",
            'Skipping item - invalid name (Microsoft Naming Convention): ./'
            + f"{root_name}/includes * in the filename",
        ]
        for marker in expected_skip_markers:
            if marker not in combined_output:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Expected invalid filename skip marker not found: {marker}",
                    artifacts,
                    details,
                )

        crash_markers = [
            "Segmentation fault",
            "Traceback",
            "core dumped",
            "std.conv.ConvException",
            "std.utf.UTFException",
        ]
        for marker in crash_markers:
            if marker in combined_output:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Client output indicates crash or exception: {marker}",
                    artifacts,
                    details,
                )

        return self.pass_result(self.case_id, self.name, artifacts, details)