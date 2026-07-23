from __future__ import annotations

import os
import re
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_onedrive_config, write_text_file


TRANSFER_METRICS_PATTERN = re.compile(
    r"Transfer Metrics - File: (?P<file>.+?) \| "
    r"Size: (?P<size>\d+) Bytes \| "
    r"Transfer: (?P<transfer>[0-9]+(?:\.[0-9]+)?) Seconds \| "
    r"End-to-End: (?P<end_to_end>[0-9]+(?:\.[0-9]+)?) Seconds \| "
    r"Speed: (?P<speed>[0-9]+(?:\.[0-9]+)?) Mbps \(approx\)"
)


class TestCase0062TransferMetricsValidation(E2ETestCase):
    case_id = "0062"
    name = "transfer metrics validation"
    description = "Validate upload and download transfer metric log format and values"

    TEST_FILE_SIZE_BYTES = 1024 * 1024

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0062 config\n"
            "bypass_data_preservation = \"true\"\n",
        )

    def _write_deterministic_binary_file(self, path: Path, size_bytes: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        pattern = b"onedrive-tc0062-transfer-metrics\n"
        full_repeats, remainder = divmod(size_bytes, len(pattern))
        path.write_bytes(pattern * full_repeats + pattern[:remainder])

    def _find_transfer_metric_line(self, output: str, *, relative_file: str, expected_size: int) -> str | None:
        for line in output.splitlines():
            if "Transfer Metrics - File:" not in line:
                continue
            if relative_file not in line:
                continue
            match = TRANSFER_METRICS_PATTERN.search(line)
            if not match:
                continue
            if int(match.group("size")) != expected_size:
                continue
            return line
        return None

    def _validate_transfer_metric_line(self, line: str, *, expected_size: int) -> tuple[bool, str, dict[str, object]]:
        match = TRANSFER_METRICS_PATTERN.search(line)
        if not match:
            return False, "Transfer Metrics line does not match expected format", {"line": line}

        parsed_size = int(match.group("size"))
        transfer_seconds = float(match.group("transfer"))
        end_to_end_seconds = float(match.group("end_to_end"))
        speed_mbps = float(match.group("speed"))

        details: dict[str, object] = {
            "line": line,
            "parsed_size": parsed_size,
            "transfer_seconds": transfer_seconds,
            "end_to_end_seconds": end_to_end_seconds,
            "speed_mbps": speed_mbps,
        }

        if parsed_size != expected_size:
            return False, f"Transfer Metrics size mismatch: expected {expected_size}, got {parsed_size}", details
        if transfer_seconds < 0:
            return False, "Transfer Metrics transfer duration is negative", details
        if end_to_end_seconds < 0:
            return False, "Transfer Metrics end-to-end duration is negative", details
        if end_to_end_seconds + 0.01 < transfer_seconds:
            return False, "Transfer Metrics end-to-end duration is less than transfer duration", details
        if speed_mbps < 0:
            return False, "Transfer Metrics speed is negative", details
        if " Duration:" in line:
            return False, "Transfer Metrics still contains legacy Duration field", details
        if " Transfer:" not in line or " End-to-End:" not in line or " Mbps (approx)" not in line:
            return False, "Transfer Metrics line is missing required fields", details

        return True, "", details

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0062",
            ensure_refresh_token=True,
        )

        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        upload_root = case_work_dir / "uploadroot"
        upload_conf = case_work_dir / "conf-upload"
        download_root = case_work_dir / "downloadroot"
        download_conf = case_work_dir / "conf-download"

        root_name = f"ZZ_E2E_TC0062_{context.run_id}_{os.getpid()}"
        file_name = "transfer-metrics-1MiB.data"
        relative_file = f"{root_name}/{file_name}"
        local_file = upload_root / root_name / file_name

        self._write_deterministic_binary_file(local_file, self.TEST_FILE_SIZE_BYTES)

        context.bootstrap_config_dir(upload_conf)
        self._write_config(upload_conf / "config")
        context.bootstrap_config_dir(download_conf)
        self._write_config(download_conf / "config")

        upload_stdout = case_log_dir / "upload_stdout.log"
        upload_stderr = case_log_dir / "upload_stderr.log"
        download_stdout = case_log_dir / "download_stdout.log"
        download_stderr = case_log_dir / "download_stderr.log"
        download_manifest_file = state_dir / "download_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        upload_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(upload_root),
            "--confdir",
            str(upload_conf),
        ]
        upload_result = run_command(upload_command, cwd=context.repo_root)
        write_text_file(upload_stdout, upload_result.stdout)
        write_text_file(upload_stderr, upload_result.stderr)

        download_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(download_root),
            "--confdir",
            str(download_conf),
        ]
        download_result = run_command(download_command, cwd=context.repo_root)
        write_text_file(download_stdout, download_result.stdout)
        write_text_file(download_stderr, download_result.stderr)

        download_manifest = build_manifest(download_root)
        write_manifest(download_manifest_file, download_manifest)

        upload_output = f"{upload_result.stdout}\n{upload_result.stderr}"
        download_output = f"{download_result.stdout}\n{download_result.stderr}"

        upload_metric_line = self._find_transfer_metric_line(
            upload_output,
            relative_file=relative_file,
            expected_size=self.TEST_FILE_SIZE_BYTES,
        )
        download_metric_line = self._find_transfer_metric_line(
            download_output,
            relative_file=relative_file,
            expected_size=self.TEST_FILE_SIZE_BYTES,
        )

        upload_metric_ok = False
        download_metric_ok = False
        upload_metric_reason = "Upload Transfer Metrics line not found"
        download_metric_reason = "Download Transfer Metrics line not found"
        upload_metric_details: dict[str, object] = {}
        download_metric_details: dict[str, object] = {}

        if upload_metric_line:
            upload_metric_ok, upload_metric_reason, upload_metric_details = self._validate_transfer_metric_line(
                upload_metric_line,
                expected_size=self.TEST_FILE_SIZE_BYTES,
            )
        if download_metric_line:
            download_metric_ok, download_metric_reason, download_metric_details = self._validate_transfer_metric_line(
                download_metric_line,
                expected_size=self.TEST_FILE_SIZE_BYTES,
            )

        details = {
            "root_name": root_name,
            "file_name": file_name,
            "expected_size_bytes": self.TEST_FILE_SIZE_BYTES,
            "upload_returncode": upload_result.returncode,
            "download_returncode": download_result.returncode,
            "upload_metric_line": upload_metric_line or "",
            "download_metric_line": download_metric_line or "",
            "upload_metric_details": upload_metric_details,
            "download_metric_details": download_metric_details,
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"root_name={root_name}",
                    f"file_name={file_name}",
                    f"expected_size_bytes={self.TEST_FILE_SIZE_BYTES}",
                    f"upload_command={command_to_string(upload_command)}",
                    f"upload_returncode={upload_result.returncode}",
                    f"download_command={command_to_string(download_command)}",
                    f"download_returncode={download_result.returncode}",
                    f"upload_metric_line={upload_metric_line or ''}",
                    f"download_metric_line={download_metric_line or ''}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(upload_stdout),
            str(upload_stderr),
            str(download_stdout),
            str(download_stderr),
            str(download_manifest_file),
            str(metadata_file),
        ]

        if upload_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Upload sync failed with status {upload_result.returncode}",
                artifacts,
                details,
            )
        if download_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Download verification sync failed with status {download_result.returncode}",
                artifacts,
                details,
            )
        if relative_file not in download_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Downloaded manifest missing expected file: {relative_file}",
                artifacts,
                details,
            )
        if not upload_metric_ok:
            return self.fail_result(self.case_id, self.name, upload_metric_reason, artifacts, details)
        if not download_metric_ok:
            return self.fail_result(self.case_id, self.name, download_metric_reason, artifacts, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)
