from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0028ControlCharacterNonUtf8FilenameValidation(E2ETestCase):
    case_id = "0028"
    name = "control character and non-UTF8 filename validation"
    description = "Validate control character and non-UTF8 filenames are safely skipped without client crash while valid sibling files still synchronise"

    def _write_config(self, config_path: Path, sync_dir: Path) -> None:
        write_text_file(
            config_path,
            "\n".join(
                [
                    "# tc0028 config",
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

    def _extract_bad_filename_archive(
        self,
        context: E2EContext,
        archive_path: Path,
        destination: Path,
        stdout_file: Path,
        stderr_file: Path,
    ):
        destination.mkdir(parents=True, exist_ok=True)
        command = [
            "tar",
            "-xJf",
            str(archive_path),
            "-C",
            str(destination),
        ]
        return self._run_and_capture(context, "archive extract", command, stdout_file, stderr_file)

    def _collect_extracted_file_entries(self, root_name: str, extract_root: Path) -> list[str]:
        extracted_files: list[str] = []

        if not extract_root.exists():
            return extracted_files

        for current_root, _, filenames in os.walk(str(extract_root)):
            for filename in filenames:
                full_path = Path(current_root) / filename
                relative_path = full_path.relative_to(extract_root)
                extracted_files.append(f"{root_name}/archive_payload/{relative_path.as_posix()}")

        extracted_files.sort()
        return extracted_files

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0028"
        case_log_dir = context.logs_dir / "tc0028"
        state_dir = context.state_dir / "tc0028"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

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

        root_name = f"ZZ_E2E_TC0028_{context.run_id}_{os.getpid()}"
        archive_path = context.repo_root / "tests" / "bad-file-name.tar.xz"

        if not archive_path.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Required archive not found: {archive_path}",
                [],
                {"archive_path": str(archive_path)},
            )

        valid_files = [
            f"{root_name}/valid_file_1.bin",
            f"{root_name}/valid_file_2.txt",
            f"{root_name}/valid_subdir/nested_valid_file.dat",
        ]

        for rel_path in valid_files:
            self._create_binary_file(sync_root / rel_path, size_kb=8)

        archive_extract_root = sync_root / root_name / "archive_payload"

        extract_stdout = case_log_dir / "archive_extract_stdout.log"
        extract_stderr = case_log_dir / "archive_extract_stderr.log"

        extract_result = self._extract_bad_filename_archive(
            context,
            archive_path,
            archive_extract_root,
            extract_stdout,
            extract_stderr,
        )

        initial_stdout = case_log_dir / "initial_sync_stdout.log"
        initial_stderr = case_log_dir / "initial_sync_stderr.log"

        second_stdout = case_log_dir / "second_sync_stdout.log"
        second_stderr = case_log_dir / "second_sync_stderr.log"

        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"

        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        if extract_result.returncode != 0:
            artifacts = [
                str(extract_stdout),
                str(extract_stderr),
            ]
            details = {
                "archive_path": str(archive_path),
                "extract_returncode": extract_result.returncode,
            }
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Archive extraction failed with status {extract_result.returncode}",
                artifacts,
                details,
            )

        extracted_file_entries = self._collect_extracted_file_entries(root_name, archive_extract_root)

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
            extract_result.stdout
            + "\n"
            + extract_result.stderr
            + "\n"
            + initial_result.stdout
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
                    f"archive_path={archive_path}",
                    f"extract_returncode={extract_result.returncode}",
                    f"initial_returncode={initial_result.returncode}",
                    f"second_returncode={second_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"valid_files={valid_files!r}",
                    f"extracted_file_entries={extracted_file_entries!r}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(extract_stdout),
            str(extract_stderr),
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
            "extract_returncode": extract_result.returncode,
            "initial_returncode": initial_result.returncode,
            "second_returncode": second_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
            "archive_path": str(archive_path),
            "extracted_file_count": len(extracted_file_entries),
        }

        for label, rc in [
            ("archive extraction", extract_result.returncode),
            ("initial sync", initial_result.returncode),
            ("second sync", second_result.returncode),
            ("remote verification", verify_result.returncode),
        ]:
            if rc != 0:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} failed with status {rc}",
                    artifacts,
                    details,
                )

        for expected in valid_files:
            if expected not in remote_manifest:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"Expected valid file missing remotely: {expected}",
                    artifacts,
                    details,
                )

        for unwanted in extracted_file_entries:
            if unwanted in remote_manifest:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"Control character or non-UTF8 filename was synchronised remotely: {unwanted!r}",
                    artifacts,
                    details,
                )

        if len(extracted_file_entries) == 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Archive extraction produced no test files under archive_payload",
                artifacts,
                details,
            )

        if (
            f"./{root_name}/archive_payload" not in combined_output
            and f"{root_name}/archive_payload" not in combined_output
        ):
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Client output does not reference the extracted archive payload paths",
                artifacts,
                details,
            )

        skip_indicators = [
            "Skipping item - invalid name",
            "Microsoft Naming Convention",
            "Skipping item",
        ]
        if not any(indicator in combined_output for indicator in skip_indicators):
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Expected skip behaviour was not observed in client output",
                artifacts,
                details,
            )

        disallowed_remote_failure_markers = [
            "HTTP 400",
            "The resource name is invalid",
            "invalidRequest",
        ]
        for marker in disallowed_remote_failure_markers:
            if marker in combined_output:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"Client attempted remote invalid-name operation instead of safe local skip: {marker}",
                    artifacts,
                    details,
                )

        crash_markers = [
            "Segmentation fault",
            "Traceback",
            "core dumped",
            "std.conv.ConvException",
            "std.utf.UTFException",
            "UnicodeDecodeError",
            "UnicodeEncodeError",
        ]
        for marker in crash_markers:
            if marker in combined_output:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"Client output indicates crash or exception: {marker}",
                    artifacts,
                    details,
                )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)