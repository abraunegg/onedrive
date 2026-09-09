from __future__ import annotations

import base64
import hashlib
import json
import os
import random
import re
import signal
import subprocess
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import CommandResult, command_to_string, reset_directory, write_onedrive_config, write_text_file


@dataclass
class ScenarioResult:
    scenario_id: str
    description: str
    passed: bool
    failure_message: str = ""
    artifacts: list[str] | None = None
    details: dict | None = None


class TestCase0021ResumableTransfersValidation(E2ETestCase):
    case_id = "0021"
    name = "resumable transfers validation"
    description = "Validate resumable transfers, source identity, and modified multi-fragment upload-session replacement"

    LARGE_FILE_SIZE = 100 * 1024 * 1024
    INTERRUPT_THRESHOLD_PERCENT = 15.0
    TRANSFER_WAIT_TIMEOUT = 300
    PROCESS_EXIT_TIMEOUT = 120
    PHASE_COMMAND_TIMEOUT = 1200

    XLSX_FRAGMENT_SIZE_BYTES = 10 * 1024 * 1024
    XLSX_MIN_SIZE_BYTES = 2 * XLSX_FRAGMENT_SIZE_BYTES
    XLSX_RANDOM_PAYLOAD_ROWS = 1000
    XLSX_RANDOM_PAYLOAD_BYTES_PER_ROW = 24_000
    XLSX_REVISION_0 = "E2E-REVISION-0000"
    XLSX_REVISION_1 = "E2E-REVISION-0001"

    # Use 10 MB/s to deliberately slow both upload and download so the 15% threshold
    # is reached with ample time to deliver SIGINT before the transfer can complete.
    RATE_LIMIT: str | None = "10485760"

    # Force active upload / download transfer abortion on SIGINT so resumable state is
    # actually persisted for recovery testing. This must only be enabled for tc0021.
    FORCE_XFER_ABORT = True

    # Poll frequently to reduce brittleness caused by buffered log writes.
    TRANSFER_POLL_INTERVAL_SECONDS = 0.25

    def _write_config(
        self,
        config_path: Path,
        sync_dir: Path,
        app_log_dir: Path,
        extra_config_lines: list[str] | None = None,
    ) -> None:
        lines = [
            "# tc0021 config",
            f'sync_dir = "{sync_dir}"',
            'enable_logging = "true"',
            f'log_dir = "{app_log_dir}"',
            'skip_symlinks = "false"',
        ]
        if self.RATE_LIMIT:
            lines.append(f'rate_limit = "{self.RATE_LIMIT}"')
        if self.FORCE_XFER_ABORT:
            lines.append('force_xfer_abort = "true"')
        if extra_config_lines:
            lines.extend(extra_config_lines)
        write_onedrive_config(config_path, "\n".join(lines) + "\n")

    def _read_text_if_exists(self, path: Path) -> str:
        if not path.exists():
            return ""
        return path.read_text(encoding="utf-8", errors="replace")

    def _append_if_exists(self, artifacts: list[str], path: Path) -> None:
        if path.exists():
            artifacts.append(str(path))

    def _snapshot_tree(self, root: Path, output: Path) -> None:
        lines: list[str] = []
        if root.exists():
            for path in sorted(root.rglob("*")):
                rel = path.relative_to(root).as_posix()
                if path.is_dir():
                    lines.append(rel + "/")
                else:
                    lines.append(rel)
        write_text_file(output, "\n".join(lines) + ("\n" if lines else ""))

    def _create_large_file(self, path: Path, size_bytes: int, fill_byte: bytes = b"R") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        if len(fill_byte) != 1:
            raise ValueError("fill_byte must contain exactly one byte")
        chunk = fill_byte * (1024 * 1024)
        chunk_count = size_bytes // len(chunk)
        with path.open("wb") as fp:
            for _ in range(chunk_count):
                fp.write(chunk)
            remainder = size_bytes % len(chunk)
            if remainder:
                fp.write(chunk[:remainder])

    def _sha256_file(self, path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as fp:
            for chunk in iter(lambda: fp.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def _create_random_xlsx(self, path: Path, seed: str) -> dict:
        """
        Create a real XLSX package without external Python dependencies.

        Cell A1 carries a fixed revision marker used by the mutation and
        verification phases. The remaining rows contain deterministic
        high-entropy base64 payloads generated from the supplied per-run seed,
        preventing ZIP compression from collapsing the workbook below the
        multi-fragment session-upload boundary.
        """
        path.parent.mkdir(parents=True, exist_ok=True)
        rng = random.Random(seed)

        content_types = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
'''
        package_rels = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
'''
        workbook = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="Issue3859" sheetId="1" r:id="rId1"/></sheets>
</workbook>
'''
        workbook_rels = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>
'''
        core_props = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>TC0021 session replacement workbook</dc:title>
  <dc:creator>OneDrive E2E Harness</dc:creator>
</cp:coreProperties>
'''
        app_props = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>OneDrive E2E Harness</Application>
</Properties>
'''

        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            archive.writestr("[Content_Types].xml", content_types)
            archive.writestr("_rels/.rels", package_rels)
            archive.writestr("xl/workbook.xml", workbook)
            archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
            archive.writestr("docProps/core.xml", core_props)
            archive.writestr("docProps/app.xml", app_props)

            with archive.open("xl/worksheets/sheet1.xml", "w") as sheet:
                sheet.write(
                    b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
                    b'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\n'
                    b'<sheetData>\n'
                )
                sheet.write(
                    (
                        '<row r="1"><c r="A1" t="inlineStr"><is><t>'
                        f'{self.XLSX_REVISION_0}'
                        '</t></is></c></row>\n'
                    ).encode("utf-8")
                )

                for row_index in range(2, self.XLSX_RANDOM_PAYLOAD_ROWS + 2):
                    payload = base64.b64encode(
                        rng.randbytes(self.XLSX_RANDOM_PAYLOAD_BYTES_PER_ROW)
                    ).decode("ascii")
                    sheet.write(
                        (
                            f'<row r="{row_index}"><c r="A{row_index}" t="inlineStr">'
                            f'<is><t>{payload}</t></is></c></row>\n'
                        ).encode("ascii")
                    )

                sheet.write(b'</sheetData>\n</worksheet>\n')

        validation_error = self._validate_xlsx(path, self.XLSX_REVISION_0)
        if validation_error:
            raise RuntimeError(validation_error)

        return {
            "seed": seed,
            "payload_rows": self.XLSX_RANDOM_PAYLOAD_ROWS,
            "payload_bytes_per_row": self.XLSX_RANDOM_PAYLOAD_BYTES_PER_ROW,
            "size_bytes": path.stat().st_size,
            "revision": self.XLSX_REVISION_0,
        }

    def _validate_xlsx(self, path: Path, expected_revision: str) -> str:
        required_members = {
            "[Content_Types].xml",
            "_rels/.rels",
            "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels",
            "xl/worksheets/sheet1.xml",
        }

        if not path.is_file():
            return f"XLSX file does not exist: {path}"

        try:
            with zipfile.ZipFile(path, "r") as archive:
                names = set(archive.namelist())
                missing = sorted(required_members - names)
                if missing:
                    return f"XLSX package is missing required members: {', '.join(missing)}"
                corrupt_member = archive.testzip()
                if corrupt_member is not None:
                    return f"XLSX package contains corrupt ZIP member: {corrupt_member}"
                sheet_xml = archive.read("xl/worksheets/sheet1.xml")
        except (OSError, zipfile.BadZipFile) as exc:
            return f"Unable to validate XLSX package: {exc}"

        if expected_revision.encode("utf-8") not in sheet_xml:
            return f"XLSX worksheet does not contain expected revision marker: {expected_revision}"

        return ""

    def _mutate_xlsx_revision(self, path: Path) -> None:
        """
        Modify the already-uploaded XLSX in place while preserving all other
        package members, including any SharePoint enrichment added after the
        first upload. The revision markers are the same length, so the test
        changes workbook content without using file-size inflation as mutation.
        """
        temp_path = path.with_name(path.name + ".mutating")
        old_marker = self.XLSX_REVISION_0.encode("utf-8")
        new_marker = self.XLSX_REVISION_1.encode("utf-8")
        replacement_count = 0

        try:
            with zipfile.ZipFile(path, "r") as source, zipfile.ZipFile(temp_path, "w") as target:
                for info in source.infolist():
                    data = source.read(info.filename)
                    if info.filename == "xl/worksheets/sheet1.xml":
                        replacement_count = data.count(old_marker)
                        data = data.replace(old_marker, new_marker, 1)
                    target.writestr(info, data)

            if replacement_count != 1:
                raise RuntimeError(
                    f"Expected exactly one XLSX revision marker before mutation; found {replacement_count}"
                )

            os.replace(temp_path, path)
        finally:
            temp_path.unlink(missing_ok=True)

        validation_error = self._validate_xlsx(path, self.XLSX_REVISION_1)
        if validation_error:
            raise RuntimeError(validation_error)

    def _extract_upload_session_guids(self, text: str) -> list[str]:
        guids: list[str] = []
        for line in text.splitlines():
            if "HTTP put request to URL:" not in line or "uploadSession?guid='" not in line:
                continue
            match = re.search(r"uploadSession\?guid='([^']+)'", line)
            if match:
                guids.append(match.group(1))
        return guids

    def _contains_any_marker(self, text: str, markers: list[str]) -> bool:
        return any(marker in text for marker in markers)

    def _extract_max_progress_percent(self, text: str) -> float:
        max_percent = 0.0
        for match in re.finditer(r"(?P<percent>\d{1,3}(?:\.\d+)?)\s*%", text):
            try:
                value = float(match.group("percent"))
            except ValueError:
                continue
            if 0.0 <= value <= 100.0 and value > max_percent:
                max_percent = value
        return max_percent

    def _build_transfer_observation(
        self,
        stdout_file: Path,
        stderr_file: Path,
        app_log_file: Path,
        target_filename: str,
    ) -> tuple[str, float]:
        stdout_text = self._read_text_if_exists(stdout_file)
        stderr_text = self._read_text_if_exists(stderr_file)
        app_log_text = self._read_text_if_exists(app_log_file)

        combined_text = stdout_text + "\n" + stderr_text + "\n" + app_log_text

        relevant_lines: list[str] = []
        for line in combined_text.splitlines():
            if target_filename in line:
                relevant_lines.append(line)

        relevant_text = "\n".join(relevant_lines)
        max_percent = 0.0

        if relevant_text:
            max_percent = self._extract_max_progress_percent(relevant_text)

        if max_percent == 0.0:
            max_percent = self._extract_max_progress_percent(combined_text)

        return combined_text, max_percent

    def _interrupt_process_at_transfer_threshold(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        app_log_file: Path,
        target_filename: str,
        threshold_percent: float,
        wait_timeout: int,
        exit_timeout: int,
    ) -> tuple[int, str, str, bool, float]:
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")

        threshold_reached = False
        observed_max_percent = 0.0

        with stdout_file.open("w", encoding="utf-8") as stdout_fp, stderr_file.open(
            "w", encoding="utf-8"
        ) as stderr_fp:
            process = subprocess.Popen(
                command,
                cwd=str(context.repo_root),
                stdout=stdout_fp,
                stderr=stderr_fp,
                text=True,
            )

            start_time = time.time()

            while True:
                if process.poll() is not None:
                    break

                _, current_max = self._build_transfer_observation(
                    stdout_file,
                    stderr_file,
                    app_log_file,
                    target_filename,
                )

                if current_max > observed_max_percent:
                    observed_max_percent = current_max

                if current_max >= threshold_percent:
                    threshold_reached = True
                    process.send_signal(signal.SIGINT)
                    break

                if (time.time() - start_time) > wait_timeout:
                    process.send_signal(signal.SIGINT)
                    break

                time.sleep(self.TRANSFER_POLL_INTERVAL_SECONDS)

            try:
                process.wait(timeout=exit_timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)

        stdout_text = self._read_text_if_exists(stdout_file)
        stderr_text = self._read_text_if_exists(stderr_file)
        return process.returncode, stdout_text, stderr_text, threshold_reached, observed_max_percent

    def _run_and_capture(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        timeout_seconds: int | None = None,
    ) -> CommandResult:
        timeout = timeout_seconds or self.PHASE_COMMAND_TIMEOUT
        context.log(
            f"Executing Test Case {self.case_id} {label}: {command_to_string(command)} "
            f"(timeout {timeout}s)"
        )

        try:
            completed = subprocess.run(
                command,
                cwd=str(context.repo_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
            )
            result = CommandResult(
                command=command,
                returncode=completed.returncode,
                stdout=completed.stdout or "",
                stderr=completed.stderr or "",
            )
        except subprocess.TimeoutExpired as exc:
            stdout = exc.stdout or ""
            stderr = exc.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", errors="replace")
            stderr = (
                f"{stderr}\n"
                f"Test Case {self.case_id} {label} timed out after {timeout} seconds; "
                "the onedrive process was terminated by the harness.\n"
            )
            result = CommandResult(
                command=command,
                returncode=124,
                stdout=stdout,
                stderr=stderr,
            )

        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def _scenario_fail(
        self,
        scenario_id: str,
        description: str,
        message: str,
        artifacts: list[str],
        details: dict,
    ) -> ScenarioResult:
        return ScenarioResult(
            scenario_id=scenario_id,
            description=description,
            passed=False,
            failure_message=message,
            artifacts=artifacts,
            details=details,
        )

    def _scenario_pass(
        self,
        scenario_id: str,
        description: str,
        artifacts: list[str],
        details: dict,
    ) -> ScenarioResult:
        return ScenarioResult(
            scenario_id=scenario_id,
            description=description,
            passed=True,
            artifacts=artifacts,
            details=details,
        )

    def _phase_app_log_file(self, phase_app_log_dir: Path) -> Path:
        return phase_app_log_dir / "root.onedrive.log"

    def _phase1_interruption_acceptable(self, combined_phase1_output: str, phase1_returncode: int) -> tuple[bool, str]:
        crash_markers = [
            "Segmentation fault",
            "core dumped",
            "SIGSEGV",
        ]

        crash_marker_seen = ""
        for marker in crash_markers:
            if marker in combined_phase1_output:
                crash_marker_seen = marker
                break

        interrupted_as_expected = (
            phase1_returncode in (-2, 2, 130, -11, 139)
            or crash_marker_seen in {"Segmentation fault", "core dumped", "SIGSEGV"}
        )

        return interrupted_as_expected, crash_marker_seen

    def _target_transfer_completed_in_phase1(
        self,
        combined_phase1_output: str,
        target_filename: str,
        transfer_kind: str,
    ) -> bool:
        for line in combined_phase1_output.splitlines():
            if target_filename not in line:
                continue

            line_lower = line.lower()

            if transfer_kind == "upload":
                if "upload" in line_lower and "done" in line_lower:
                    return True
            elif transfer_kind == "download":
                if "download" in line_lower and "done" in line_lower:
                    return True

        return False

    def _find_resumable_state_files(self, conf_dir: Path, patterns: list[str]) -> list[str]:
        matches: list[str] = []
        for pattern in patterns:
            for path in sorted(conf_dir.glob(pattern)):
                if path.is_file():
                    matches.append(str(path))
        return matches

    def _write_resumable_state_listing(self, output: Path, resumable_files: list[str]) -> None:
        if resumable_files:
            write_text_file(output, "\n".join(resumable_files) + "\n")
        else:
            write_text_file(output, "")

    def _write_resumable_state_dump(self, output: Path, resumable_files: list[str]) -> None:
        lines: list[str] = []
        for session_file in resumable_files:
            path = Path(session_file)
            lines.append(f"===== {path} =====")
            try:
                lines.append(path.read_text(encoding="utf-8", errors="replace"))
            except OSError as exc:
                lines.append(f"<unable to read resumable state file: {exc}>")
            lines.append("")
        write_text_file(output, "\n".join(lines) + ("\n" if lines else ""))

    def _write_symlink_metadata(self, output: Path, symlink_path: Path) -> None:
        try:
            target = os.readlink(symlink_path)
        except OSError as exc:
            target = f"<readlink failed: {exc}>"
        write_text_file(
            output,
            "\n".join(
                [
                    f"path={symlink_path}",
                    f"is_symlink={symlink_path.is_symlink()}",
                    f"exists={symlink_path.exists()}",
                    f"lexists={os.path.lexists(symlink_path)}",
                    f"readlink={target}",
                ]
            )
            + "\n",
        )

    def _run_upload_resume_scenario(
        self,
        context: E2EContext,
        root_name: str,
        sync_root: Path,
        verify_root: Path,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "RT-0001"
        description = "resumable upload"

        conf_dir = scenario_work_dir / "conf"
        verify_conf_dir = scenario_work_dir / "verify-conf"

        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        app_log_file = self._phase_app_log_file(app_log_dir)
        verify_app_log_file = self._phase_app_log_file(verify_app_log_dir)

        reset_directory(conf_dir)
        reset_directory(verify_conf_dir)
        context.bootstrap_config_dir(conf_dir)
        context.bootstrap_config_dir(verify_conf_dir)

        self._write_config(conf_dir / "config", sync_root, app_log_dir)
        self._write_config(verify_conf_dir / "config", verify_root, verify_app_log_dir)

        relative_path = f"{root_name}/{scenario_id}/session-large.bin"
        local_file = sync_root / relative_path
        self._create_large_file(local_file, self.LARGE_FILE_SIZE)

        phase1_stdout = scenario_log_dir / "phase1_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"

        local_tree_before = scenario_state_dir / "local_tree_before_phase1.txt"
        local_tree_after_phase1 = scenario_state_dir / "local_tree_after_phase1.txt"
        local_tree_after_phase2 = scenario_state_dir / "local_tree_after_phase2.txt"
        remote_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        resumable_state_file = scenario_state_dir / "phase1_resumable_state_files.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        self._snapshot_tree(sync_root, local_tree_before)

        upload_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        (
            phase1_returncode,
            phase1_stdout_text,
            phase1_stderr_text,
            threshold_reached,
            observed_max_percent,
        ) = self._interrupt_process_at_transfer_threshold(
            context,
            f"{scenario_id} phase 1",
            upload_command,
            phase1_stdout,
            phase1_stderr,
            app_log_file,
            "session-large.bin",
            self.INTERRUPT_THRESHOLD_PERCENT,
            self.TRANSFER_WAIT_TIMEOUT,
            self.PROCESS_EXIT_TIMEOUT,
        )

        self._snapshot_tree(sync_root, local_tree_after_phase1)

        phase1_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase1_output = phase1_stdout_text + "\n" + phase1_stderr_text + "\n" + phase1_app_log_text

        phase1_completed_transfer = self._target_transfer_completed_in_phase1(
            combined_phase1_output,
            "session-large.bin",
            "upload",
        )

        resumable_state_files = self._find_resumable_state_files(
            conf_dir,
            [
                "session_upload*",
                "session_upload.*",
            ],
        )
        self._write_resumable_state_listing(resumable_state_file, resumable_state_files)

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            upload_command,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        phase2_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase2_output = phase2_stdout_text + "\n" + phase2_stderr_text + "\n" + phase2_app_log_text

        self._snapshot_tree(sync_root, local_tree_after_phase2)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(verify_conf_dir),
        ]

        verify_result = self._run_and_capture(
            context,
            f"{scenario_id} verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        interrupted_as_expected, crash_marker_seen = self._phase1_interruption_acceptable(
            combined_phase1_output,
            phase1_returncode,
        )

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_tree_before),
            str(local_tree_after_phase1),
            str(local_tree_after_phase2),
            str(remote_manifest_file),
            str(resumable_state_file),
            str(metadata_file),
        ]
        self._append_if_exists(artifacts, app_log_dir)
        self._append_if_exists(artifacts, verify_app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "relative_path": relative_path,
            "large_size": self.LARGE_FILE_SIZE,
            "interrupt_threshold_percent": self.INTERRUPT_THRESHOLD_PERCENT,
            "threshold_reached": threshold_reached,
            "observed_max_percent": observed_max_percent,
            "phase1_transfer_completed": phase1_completed_transfer,
            "phase1_resumable_state_files": resumable_state_files,
            "phase1_crash_marker_seen": crash_marker_seen,
            "phase1_interrupted_as_expected": interrupted_as_expected,
            "rate_limit": self.RATE_LIMIT or "disabled",
            "force_xfer_abort": self.FORCE_XFER_ABORT,
            "conf_dir": str(conf_dir),
            "app_log_file": str(app_log_file),
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"scenario_id={scenario_id}",
                    f"phase1_returncode={phase1_returncode}",
                    f"phase2_returncode={phase2_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"relative_path={relative_path}",
                    f"large_size={self.LARGE_FILE_SIZE}",
                    f"interrupt_threshold_percent={self.INTERRUPT_THRESHOLD_PERCENT}",
                    f"threshold_reached={threshold_reached}",
                    f"observed_max_percent={observed_max_percent}",
                    f"phase1_transfer_completed={phase1_completed_transfer}",
                    f"phase1_resumable_state_files={len(resumable_state_files)}",
                    f"phase1_crash_marker_seen={crash_marker_seen}",
                    f"phase1_interrupted_as_expected={interrupted_as_expected}",
                    f"rate_limit={self.RATE_LIMIT or 'disabled'}",
                    f"force_xfer_abort={self.FORCE_XFER_ABORT}",
                    f"conf_dir={conf_dir}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )

        if not threshold_reached:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted upload phase never reached {self.INTERRUPT_THRESHOLD_PERCENT}% transfer progress before shutdown; observed maximum was {observed_max_percent:.2f}%",
                artifacts,
                details,
            )

        if phase1_completed_transfer:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted upload phase completed the target file transfer before SIGINT landed, so no resumable upload state was guaranteed",
                artifacts,
                details,
            )

        if not interrupted_as_expected:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted upload phase did not terminate as expected after threshold was reached; return code was {phase1_returncode}",
                artifacts,
                details,
            )

        if not resumable_state_files:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted upload phase did not leave resumable upload session state on disk",
                artifacts,
                details,
            )

        if phase2_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Resumable upload recovery phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        upload_resume_markers = [
            "There are interrupted session uploads that need to be resumed",
            "Attempting to restore file upload session using this session data file",
            "Attempting to restore file upload session",
        ]
        if not self._contains_any_marker(combined_phase2_output, upload_resume_markers):
            return self._scenario_fail(
                scenario_id,
                description,
                "Subsequent upload run did not show evidence of resumable upload recovery",
                artifacts,
                details,
            )

        if relative_path not in remote_manifest:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted resumable upload did not complete successfully on the subsequent run",
                artifacts,
                details,
            )

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def _run_upload_source_change_scenario(
        self,
        context: E2EContext,
        root_name: str,
        sync_root: Path,
        verify_root: Path,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "RT-0005"
        description = "changed local source invalidates resumable upload session"

        conf_dir = scenario_work_dir / "conf"
        verify_conf_dir = scenario_work_dir / "verify-conf"
        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        reset_directory(conf_dir)
        reset_directory(verify_conf_dir)
        context.bootstrap_config_dir(conf_dir)
        context.bootstrap_config_dir(verify_conf_dir)

        self._write_config(
            conf_dir / "config",
            sync_root,
            app_log_dir,
            extra_config_lines=['file_fragment_size = "10"'],
        )
        self._write_config(
            verify_conf_dir / "config",
            verify_root,
            verify_app_log_dir,
            extra_config_lines=['file_fragment_size = "10"'],
        )

        app_log_file = self._phase_app_log_file(app_log_dir)

        relative_path = f"{root_name}/{scenario_id}/session-source-change.bin"
        local_file = sync_root / relative_path
        verify_file = verify_root / relative_path
        self._create_large_file(local_file, self.LARGE_FILE_SIZE, b"A")

        revision_a_size = local_file.stat().st_size
        revision_a_mtime_ns = local_file.stat().st_mtime_ns
        revision_a_sha256 = self._sha256_file(local_file)

        phase1_stdout = scenario_log_dir / "phase1_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_stderr.log"
        phase1_app_log_capture = scenario_log_dir / "phase1_app.log"
        phase2_stdout = scenario_log_dir / "phase2_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"

        session_state_dump = scenario_state_dir / "phase1_session_state.txt"
        metadata_file = scenario_state_dir / "metadata.txt"
        verify_manifest_file = scenario_state_dir / "verify_manifest.txt"

        upload_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        (
            phase1_returncode,
            phase1_stdout_text,
            phase1_stderr_text,
            threshold_reached,
            observed_max_percent,
        ) = self._interrupt_process_at_transfer_threshold(
            context,
            f"{scenario_id} phase 1",
            upload_command,
            phase1_stdout,
            phase1_stderr,
            app_log_file,
            "session-source-change.bin",
            self.INTERRUPT_THRESHOLD_PERCENT,
            self.TRANSFER_WAIT_TIMEOUT,
            self.PROCESS_EXIT_TIMEOUT,
        )

        phase1_app_log_text = self._read_text_if_exists(app_log_file)
        write_text_file(phase1_app_log_capture, phase1_app_log_text)
        combined_phase1_output = (
            phase1_stdout_text + "\n" + phase1_stderr_text + "\n" + phase1_app_log_text
        )
        phase1_completed_transfer = self._target_transfer_completed_in_phase1(
            combined_phase1_output,
            "session-source-change.bin",
            "upload",
        )
        interrupted_as_expected, crash_marker_seen = self._phase1_interruption_acceptable(
            combined_phase1_output,
            phase1_returncode,
        )

        resumable_state_files = self._find_resumable_state_files(
            conf_dir,
            ["session_upload.*"],
        )
        self._write_resumable_state_dump(session_state_dump, resumable_state_files)

        saved_source_size = None
        saved_source_mtime = ""
        saved_next_offset = -1
        saved_upload_url = ""
        session_parse_error = ""

        if len(resumable_state_files) == 1:
            try:
                saved_session = json.loads(
                    Path(resumable_state_files[0]).read_text(encoding="utf-8")
                )
                saved_source_size = saved_session.get("sourceFileSize")
                saved_source_mtime = saved_session.get("sourceFileMtime", "")
                saved_upload_url = saved_session.get("uploadUrl", "")
                next_ranges = saved_session.get("nextExpectedRanges", [])
                if next_ranges:
                    saved_next_offset = int(str(next_ranges[0]).split("-", 1)[0])
            except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
                session_parse_error = str(exc)

        # Replace revision A with a different revision B while preserving the exact
        # byte size. Force a distinct filesystem mtime as well so the persisted
        # source identity must reject the old Microsoft upload session.
        self._create_large_file(local_file, self.LARGE_FILE_SIZE, b"B")
        revision_b_stat = local_file.stat()
        if revision_b_stat.st_mtime_ns == revision_a_mtime_ns:
            forced_mtime_ns = revision_a_mtime_ns + 1_000_000_000
            os.utime(
                local_file,
                ns=(revision_b_stat.st_atime_ns, forced_mtime_ns),
            )
            revision_b_stat = local_file.stat()

        revision_b_size = revision_b_stat.st_size
        revision_b_mtime_ns = revision_b_stat.st_mtime_ns
        revision_b_sha256 = self._sha256_file(local_file)

        # Isolate phase-2 application logging so source-rejection and fresh-upload
        # evidence cannot be satisfied by messages from the interrupted first run.
        app_log_file.unlink(missing_ok=True)

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            upload_command,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase2_output = (
            phase2_result.stdout + "\n" + phase2_result.stderr + "\n" + phase2_app_log_text
        )

        source_change_rejected_seen = (
            "The local file has changed since the upload session was created; "
            "the existing upload session cannot be resumed"
            in combined_phase2_output
        )
        stale_session_cancel_seen = (
            "Cancelling invalid Microsoft OneDrive upload session"
            in combined_phase2_output
        )
        fresh_zero_start_seen = any(
            "session-source-change.bin" in line
            and "Uploading:" in line
            and re.search(r"\b0%", line) is not None
            for line in combined_phase2_output.splitlines()
        )

        post_phase2_resumable_state_files = self._find_resumable_state_files(
            conf_dir,
            ["session_upload.*"],
        )

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(verify_conf_dir),
        ]
        verify_result = self._run_and_capture(
            context,
            f"{scenario_id} verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        verified_size = verify_file.stat().st_size if verify_file.is_file() else -1
        verified_sha256 = self._sha256_file(verify_file) if verify_file.is_file() else ""

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase1_app_log_capture),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(session_state_dump),
            str(metadata_file),
            str(verify_manifest_file),
        ]
        self._append_if_exists(artifacts, app_log_dir)
        self._append_if_exists(artifacts, verify_app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "threshold_reached": threshold_reached,
            "observed_max_percent": observed_max_percent,
            "phase1_transfer_completed": phase1_completed_transfer,
            "phase1_interrupted_as_expected": interrupted_as_expected,
            "phase1_crash_marker_seen": crash_marker_seen,
            "resumable_state_files": resumable_state_files,
            "session_parse_error": session_parse_error,
            "saved_source_size": saved_source_size,
            "saved_source_mtime": saved_source_mtime,
            "saved_next_offset": saved_next_offset,
            "saved_upload_url_present": bool(saved_upload_url),
            "revision_a_size": revision_a_size,
            "revision_b_size": revision_b_size,
            "revision_a_mtime_ns": revision_a_mtime_ns,
            "revision_b_mtime_ns": revision_b_mtime_ns,
            "revision_a_sha256": revision_a_sha256,
            "revision_b_sha256": revision_b_sha256,
            "source_change_rejected_seen": source_change_rejected_seen,
            "stale_session_cancel_seen": stale_session_cancel_seen,
            "fresh_zero_start_seen": fresh_zero_start_seen,
            "post_phase2_resumable_state_files": post_phase2_resumable_state_files,
            "verified_size": verified_size,
            "verified_sha256": verified_sha256,
        }

        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value}" for key, value in details.items()) + "\n",
        )

        if not threshold_reached:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted upload never reached {self.INTERRUPT_THRESHOLD_PERCENT}% transfer progress; observed maximum was {observed_max_percent:.2f}%",
                artifacts,
                details,
            )

        if phase1_completed_transfer:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted phase completed the target transfer before shutdown, so no reusable partial upload was guaranteed",
                artifacts,
                details,
            )

        if not interrupted_as_expected:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted phase did not terminate as expected; return code was {phase1_returncode}",
                artifacts,
                details,
            )

        if len(resumable_state_files) != 1:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Expected exactly one persisted upload session after interruption, found {len(resumable_state_files)}",
                artifacts,
                details,
            )

        if session_parse_error:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Unable to parse persisted upload-session metadata: {session_parse_error}",
                artifacts,
                details,
            )

        if saved_source_size != revision_a_size or not saved_source_mtime:
            return self._scenario_fail(
                scenario_id,
                description,
                "Persisted upload session did not contain the expected sourceFileSize/sourceFileMtime identity for revision A",
                artifacts,
                details,
            )

        minimum_expected_offset = 2 * self.XLSX_FRAGMENT_SIZE_BYTES
        if saved_next_offset < minimum_expected_offset:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Persisted upload session did not contain progress from at least two completed fragments; observed offset {saved_next_offset}, required at least {minimum_expected_offset}",
                artifacts,
                details,
            )

        if revision_a_size != revision_b_size:
            return self._scenario_fail(
                scenario_id,
                description,
                "Revision B did not preserve the exact byte size of revision A",
                artifacts,
                details,
            )

        if revision_a_mtime_ns == revision_b_mtime_ns:
            return self._scenario_fail(
                scenario_id,
                description,
                "Revision B did not receive a distinct local modification timestamp",
                artifacts,
                details,
            )

        if revision_a_sha256 == revision_b_sha256:
            return self._scenario_fail(
                scenario_id,
                description,
                "Revision B content hash unexpectedly matches revision A",
                artifacts,
                details,
            )

        if phase2_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Recovery run failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if not source_change_rejected_seen:
            return self._scenario_fail(
                scenario_id,
                description,
                "Recovery run did not report rejection of the resumable upload because the local source had changed",
                artifacts,
                details,
            )

        if not stale_session_cancel_seen:
            return self._scenario_fail(
                scenario_id,
                description,
                "Recovery run did not show best-effort cancellation of the stale Microsoft upload session",
                artifacts,
                details,
            )

        if not fresh_zero_start_seen:
            return self._scenario_fail(
                scenario_id,
                description,
                "Recovery run did not show the current local revision starting a fresh upload from zero percent",
                artifacts,
                details,
            )

        if post_phase2_resumable_state_files:
            return self._scenario_fail(
                scenario_id,
                description,
                "Stale resumable upload-session metadata remained after successful recovery",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Independent remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if relative_path not in verify_manifest or not verify_file.is_file():
            return self._scenario_fail(
                scenario_id,
                description,
                "Independent verification client did not download the expected remote file",
                artifacts,
                details,
            )

        if verified_size != revision_b_size or verified_sha256 != revision_b_sha256:
            return self._scenario_fail(
                scenario_id,
                description,
                "Remote object does not exactly match local revision B after stale-session recovery",
                artifacts,
                details,
            )

        if verified_sha256 == revision_a_sha256:
            return self._scenario_fail(
                scenario_id,
                description,
                "Remote object unexpectedly matches revision A after source-change recovery",
                artifacts,
                details,
            )

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def _run_download_resume_scenario(
        self,
        context: E2EContext,
        root_name: str,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "RT-0002"
        description = "resumable download"

        seed_root = scenario_work_dir / "seedroot"
        download_root = scenario_work_dir / "downloadroot"
        verify_root = scenario_work_dir / "verifyroot"

        seed_conf_dir = scenario_work_dir / "seed-conf"
        conf_dir = scenario_work_dir / "conf"
        verify_conf_dir = scenario_work_dir / "verify-conf"

        seed_app_log_dir = scenario_log_dir / "seed-app-logs"
        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        seed_app_log_file = self._phase_app_log_file(seed_app_log_dir)
        app_log_file = self._phase_app_log_file(app_log_dir)
        verify_app_log_file = self._phase_app_log_file(verify_app_log_dir)

        reset_directory(seed_root)
        reset_directory(download_root)
        reset_directory(verify_root)
        reset_directory(seed_conf_dir)
        reset_directory(conf_dir)
        reset_directory(verify_conf_dir)

        context.bootstrap_config_dir(seed_conf_dir)
        context.bootstrap_config_dir(conf_dir)
        context.bootstrap_config_dir(verify_conf_dir)

        self._write_config(seed_conf_dir / "config", seed_root, seed_app_log_dir)
        self._write_config(conf_dir / "config", download_root, app_log_dir)
        self._write_config(verify_conf_dir / "config", verify_root, verify_app_log_dir)

        relative_path = f"{root_name}/{scenario_id}/session-large.bin"
        seed_file = seed_root / relative_path
        self._create_large_file(seed_file, self.LARGE_FILE_SIZE)

        seed_stdout = scenario_log_dir / "seed_stdout.log"
        seed_stderr = scenario_log_dir / "seed_stderr.log"
        phase1_stdout = scenario_log_dir / "phase1_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"

        local_tree_before = scenario_state_dir / "local_tree_before_phase1.txt"
        local_tree_after_phase1 = scenario_state_dir / "local_tree_after_phase1.txt"
        local_tree_after_phase2 = scenario_state_dir / "local_tree_after_phase2.txt"
        local_tree_after_verify = scenario_state_dir / "local_tree_after_verify.txt"
        verify_manifest_file = scenario_state_dir / "verify_manifest.txt"
        resumable_state_file = scenario_state_dir / "phase1_resumable_state_files.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(seed_conf_dir),
        ]
        seed_result = self._run_and_capture(
            context,
            f"{scenario_id} seed",
            seed_command,
            seed_stdout,
            seed_stderr,
        )

        if seed_result.returncode != 0:
            artifacts = [str(seed_stdout), str(seed_stderr)]
            self._append_if_exists(artifacts, seed_app_log_dir)
            details = {
                "scenario_id": scenario_id,
                "seed_returncode": seed_result.returncode,
                "relative_path": relative_path,
                "rate_limit": self.RATE_LIMIT or "disabled",
                "force_xfer_abort": self.FORCE_XFER_ABORT,
            }
            return self._scenario_fail(
                scenario_id,
                description,
                f"Seed upload phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        reset_directory(download_root)

        items_db = conf_dir / "items.sqlite3"
        items_db_wal = conf_dir / "items.sqlite3-wal"
        items_db_shm = conf_dir / "items.sqlite3-shm"
        for db_file in (items_db, items_db_wal, items_db_shm):
            if db_file.exists():
                db_file.unlink()

        self._snapshot_tree(download_root, local_tree_before)

        download_command_phase1 = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        (
            phase1_returncode,
            phase1_stdout_text,
            phase1_stderr_text,
            threshold_reached,
            observed_max_percent,
        ) = self._interrupt_process_at_transfer_threshold(
            context,
            f"{scenario_id} phase 1",
            download_command_phase1,
            phase1_stdout,
            phase1_stderr,
            app_log_file,
            "session-large.bin",
            self.INTERRUPT_THRESHOLD_PERCENT,
            self.TRANSFER_WAIT_TIMEOUT,
            self.PROCESS_EXIT_TIMEOUT,
        )

        self._snapshot_tree(download_root, local_tree_after_phase1)

        phase1_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase1_output = phase1_stdout_text + "\n" + phase1_stderr_text + "\n" + phase1_app_log_text

        phase1_completed_transfer = self._target_transfer_completed_in_phase1(
            combined_phase1_output,
            "session-large.bin",
            "download",
        )

        resumable_state_files = self._find_resumable_state_files(
            conf_dir,
            [
                "resume_download*",
                "resume_download.*",
            ],
        )
        self._write_resumable_state_listing(resumable_state_file, resumable_state_files)

        download_command_phase2 = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            download_command_phase2,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        phase2_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase2_output = phase2_stdout_text + "\n" + phase2_stderr_text + "\n" + phase2_app_log_text

        self._snapshot_tree(download_root, local_tree_after_phase2)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(verify_conf_dir),
        ]
        verify_result = self._run_and_capture(
            context,
            f"{scenario_id} verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        self._snapshot_tree(verify_root, local_tree_after_verify)

        downloaded_file = download_root / relative_path

        interrupted_as_expected, crash_marker_seen = self._phase1_interruption_acceptable(
            combined_phase1_output,
            phase1_returncode,
        )

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_tree_before),
            str(local_tree_after_phase1),
            str(local_tree_after_phase2),
            str(local_tree_after_verify),
            str(verify_manifest_file),
            str(resumable_state_file),
            str(metadata_file),
        ]
        self._append_if_exists(artifacts, seed_app_log_dir)
        self._append_if_exists(artifacts, app_log_dir)
        self._append_if_exists(artifacts, verify_app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "seed_returncode": seed_result.returncode,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "relative_path": relative_path,
            "large_size": self.LARGE_FILE_SIZE,
            "interrupt_threshold_percent": self.INTERRUPT_THRESHOLD_PERCENT,
            "threshold_reached": threshold_reached,
            "observed_max_percent": observed_max_percent,
            "phase1_transfer_completed": phase1_completed_transfer,
            "phase1_resumable_state_files": resumable_state_files,
            "downloaded_file_exists_after_phase2": downloaded_file.exists(),
            "phase1_crash_marker_seen": crash_marker_seen,
            "phase1_interrupted_as_expected": interrupted_as_expected,
            "rate_limit": self.RATE_LIMIT or "disabled",
            "force_xfer_abort": self.FORCE_XFER_ABORT,
            "conf_dir": str(conf_dir),
            "app_log_file": str(app_log_file),
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"scenario_id={scenario_id}",
                    f"seed_returncode={seed_result.returncode}",
                    f"phase1_returncode={phase1_returncode}",
                    f"phase2_returncode={phase2_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"relative_path={relative_path}",
                    f"large_size={self.LARGE_FILE_SIZE}",
                    f"interrupt_threshold_percent={self.INTERRUPT_THRESHOLD_PERCENT}",
                    f"threshold_reached={threshold_reached}",
                    f"observed_max_percent={observed_max_percent}",
                    f"phase1_transfer_completed={phase1_completed_transfer}",
                    f"phase1_resumable_state_files={len(resumable_state_files)}",
                    f"downloaded_file_exists_after_phase2={downloaded_file.exists()}",
                    f"phase1_crash_marker_seen={crash_marker_seen}",
                    f"phase1_interrupted_as_expected={interrupted_as_expected}",
                    f"rate_limit={self.RATE_LIMIT or 'disabled'}",
                    f"force_xfer_abort={self.FORCE_XFER_ABORT}",
                    f"conf_dir={conf_dir}",
                    f"app_log_file={app_log_file}",
                ]
            )
            + "\n",
        )

        if not threshold_reached:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted download phase never reached {self.INTERRUPT_THRESHOLD_PERCENT}% transfer progress before shutdown; observed maximum was {observed_max_percent:.2f}%",
                artifacts,
                details,
            )

        if phase1_completed_transfer:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted download phase completed the target file transfer before SIGINT landed, so no resumable download state was guaranteed",
                artifacts,
                details,
            )

        if not interrupted_as_expected:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted download phase did not terminate as expected after threshold was reached; return code was {phase1_returncode}",
                artifacts,
                details,
            )

        if not resumable_state_files:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted download phase did not leave resumable download state on disk",
                artifacts,
                details,
            )

        if phase2_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Resumable download recovery phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Download verification phase failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        download_resume_markers = [
            "There are interrupted downloads that need to be resumed",
            "Attempting to resume file download using this 'resumable data' file",
            "Attempting to resume file download using this resumable data file",
        ]
        if not self._contains_any_marker(combined_phase2_output, download_resume_markers):
            return self._scenario_fail(
                scenario_id,
                description,
                "Subsequent download run did not show evidence of resumable download recovery",
                artifacts,
                details,
            )

        if not downloaded_file.exists():
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted resumable download did not produce the expected local file on the subsequent run",
                artifacts,
                details,
            )

        if downloaded_file.stat().st_size != self.LARGE_FILE_SIZE:
            return self._scenario_fail(
                scenario_id,
                description,
                "Downloaded file size after resumed download did not match expected size",
                artifacts,
                details,
            )

        if relative_path not in verify_manifest:
            return self._scenario_fail(
                scenario_id,
                description,
                "Verification download did not contain the expected remote file",
                artifacts,
                details,
            )

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def _run_upload_resume_dangling_symlink_scenario(
        self,
        context: E2EContext,
        root_name: str,
        sync_root: Path,
        verify_root: Path,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "RT-0003"
        description = "resumable upload with local source replaced by dangling symlink"

        conf_dir = scenario_work_dir / "conf"
        verify_conf_dir = scenario_work_dir / "verify-conf"

        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        app_log_file = self._phase_app_log_file(app_log_dir)
        verify_app_log_file = self._phase_app_log_file(verify_app_log_dir)

        reset_directory(conf_dir)
        reset_directory(verify_conf_dir)
        context.bootstrap_config_dir(conf_dir)
        context.bootstrap_config_dir(verify_conf_dir)

        self._write_config(conf_dir / "config", sync_root, app_log_dir)
        self._write_config(verify_conf_dir / "config", verify_root, verify_app_log_dir)

        relative_path = f"{root_name}/{scenario_id}/session-large-becomes-dangling-symlink.bin"
        control_relative_path = f"{root_name}/{scenario_id}/control-after-broken-session.txt"
        local_file = sync_root / relative_path
        control_file = sync_root / control_relative_path
        self._create_large_file(local_file, self.LARGE_FILE_SIZE)

        phase1_stdout = scenario_log_dir / "phase1_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"

        local_tree_before = scenario_state_dir / "local_tree_before_phase1.txt"
        local_tree_after_phase1 = scenario_state_dir / "local_tree_after_phase1.txt"
        local_tree_before_phase2 = scenario_state_dir / "local_tree_before_phase2.txt"
        local_tree_after_phase2 = scenario_state_dir / "local_tree_after_phase2.txt"
        remote_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        resumable_state_file = scenario_state_dir / "phase1_resumable_state_files.txt"
        resumable_state_dump_file = scenario_state_dir / "phase1_resumable_state_dump.txt"
        post_phase2_resumable_state_file = scenario_state_dir / "post_phase2_resumable_state_files.txt"
        symlink_metadata_file = scenario_state_dir / "dangling_symlink_metadata.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        self._snapshot_tree(sync_root, local_tree_before)

        upload_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]

        (
            phase1_returncode,
            phase1_stdout_text,
            phase1_stderr_text,
            threshold_reached,
            observed_max_percent,
        ) = self._interrupt_process_at_transfer_threshold(
            context,
            f"{scenario_id} phase 1",
            upload_command,
            phase1_stdout,
            phase1_stderr,
            app_log_file,
            "session-large-becomes-dangling-symlink.bin",
            self.INTERRUPT_THRESHOLD_PERCENT,
            self.TRANSFER_WAIT_TIMEOUT,
            self.PROCESS_EXIT_TIMEOUT,
        )

        self._snapshot_tree(sync_root, local_tree_after_phase1)

        phase1_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase1_output = phase1_stdout_text + "\n" + phase1_stderr_text + "\n" + phase1_app_log_text

        phase1_completed_transfer = self._target_transfer_completed_in_phase1(
            combined_phase1_output,
            "session-large-becomes-dangling-symlink.bin",
            "upload",
        )

        resumable_state_files = self._find_resumable_state_files(
            conf_dir,
            [
                "session_upload*",
                "session_upload.*",
            ],
        )
        self._write_resumable_state_listing(resumable_state_file, resumable_state_files)
        self._write_resumable_state_dump(resumable_state_dump_file, resumable_state_files)

        # Reproduce the #3770-style failure mode: the interrupted upload session
        # still points at the original local path, but that path is now a broken
        # symlink by the time upload-session recovery runs.
        if local_file.exists() or local_file.is_symlink():
            local_file.unlink()
        local_file.symlink_to("missing-target-after-interruption.bin")
        write_text_file(control_file, "control file created after the interrupted upload source became a dangling symlink\n")

        self._write_symlink_metadata(symlink_metadata_file, local_file)
        self._snapshot_tree(sync_root, local_tree_before_phase2)

        phase2_result = self._run_and_capture(
            context,
            f"{scenario_id} phase 2",
            upload_command,
            phase2_stdout,
            phase2_stderr,
        )

        phase2_stdout_text = self._read_text_if_exists(phase2_stdout)
        phase2_stderr_text = self._read_text_if_exists(phase2_stderr)
        phase2_app_log_text = self._read_text_if_exists(app_log_file)
        combined_phase2_output = phase2_stdout_text + "\n" + phase2_stderr_text + "\n" + phase2_app_log_text

        self._snapshot_tree(sync_root, local_tree_after_phase2)

        post_phase2_resumable_state_files = self._find_resumable_state_files(
            conf_dir,
            [
                "session_upload*",
                "session_upload.*",
            ],
        )
        self._write_resumable_state_listing(post_phase2_resumable_state_file, post_phase2_resumable_state_files)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(verify_conf_dir),
        ]

        verify_result = self._run_and_capture(
            context,
            f"{scenario_id} verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        interrupted_as_expected, crash_marker_seen = self._phase1_interruption_acceptable(
            combined_phase1_output,
            phase1_returncode,
        )

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_tree_before),
            str(local_tree_after_phase1),
            str(local_tree_before_phase2),
            str(local_tree_after_phase2),
            str(remote_manifest_file),
            str(resumable_state_file),
            str(resumable_state_dump_file),
            str(post_phase2_resumable_state_file),
            str(symlink_metadata_file),
            str(metadata_file),
        ]
        self._append_if_exists(artifacts, app_log_dir)
        self._append_if_exists(artifacts, verify_app_log_dir)

        details = {
            "scenario_id": scenario_id,
            "phase1_returncode": phase1_returncode,
            "phase2_returncode": phase2_result.returncode,
            "verify_returncode": verify_result.returncode,
            "relative_path": relative_path,
            "control_relative_path": control_relative_path,
            "large_size": self.LARGE_FILE_SIZE,
            "interrupt_threshold_percent": self.INTERRUPT_THRESHOLD_PERCENT,
            "threshold_reached": threshold_reached,
            "observed_max_percent": observed_max_percent,
            "phase1_transfer_completed": phase1_completed_transfer,
            "phase1_resumable_state_files": resumable_state_files,
            "post_phase2_resumable_state_files": post_phase2_resumable_state_files,
            "control_uploaded": control_relative_path in remote_manifest,
            "dangling_source_uploaded": relative_path in remote_manifest,
            "phase1_crash_marker_seen": crash_marker_seen,
            "phase1_interrupted_as_expected": interrupted_as_expected,
            "phase2_file_exception_seen": "std.file.FileException" in combined_phase2_output,
            "phase2_no_such_file_seen": "No such file or directory" in combined_phase2_output,
            "phase2_dangling_symlink_path_seen": str(local_file) in combined_phase2_output,
            "rate_limit": self.RATE_LIMIT or "disabled",
            "force_xfer_abort": self.FORCE_XFER_ABORT,
            "conf_dir": str(conf_dir),
            "app_log_file": str(app_log_file),
            "dangling_symlink_path": str(local_file),
            "dangling_symlink_target": "missing-target-after-interruption.bin",
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"scenario_id={scenario_id}",
                    f"phase1_returncode={phase1_returncode}",
                    f"phase2_returncode={phase2_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"relative_path={relative_path}",
                    f"control_relative_path={control_relative_path}",
                    f"large_size={self.LARGE_FILE_SIZE}",
                    f"interrupt_threshold_percent={self.INTERRUPT_THRESHOLD_PERCENT}",
                    f"threshold_reached={threshold_reached}",
                    f"observed_max_percent={observed_max_percent}",
                    f"phase1_transfer_completed={phase1_completed_transfer}",
                    f"phase1_resumable_state_files={len(resumable_state_files)}",
                    f"post_phase2_resumable_state_files={len(post_phase2_resumable_state_files)}",
                    f"control_uploaded={details['control_uploaded']}",
                    f"dangling_source_uploaded={details['dangling_source_uploaded']}",
                    f"phase1_crash_marker_seen={crash_marker_seen}",
                    f"phase1_interrupted_as_expected={interrupted_as_expected}",
                    f"phase2_file_exception_seen={details['phase2_file_exception_seen']}",
                    f"phase2_no_such_file_seen={details['phase2_no_such_file_seen']}",
                    f"phase2_dangling_symlink_path_seen={details['phase2_dangling_symlink_path_seen']}",
                    f"rate_limit={self.RATE_LIMIT or 'disabled'}",
                    f"force_xfer_abort={self.FORCE_XFER_ABORT}",
                    f"conf_dir={conf_dir}",
                    f"app_log_file={app_log_file}",
                    f"dangling_symlink_path={local_file}",
                    "dangling_symlink_target=missing-target-after-interruption.bin",
                ]
            )
            + "\n",
        )

        if not threshold_reached:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted upload phase never reached {self.INTERRUPT_THRESHOLD_PERCENT}% transfer progress before shutdown; observed maximum was {observed_max_percent:.2f}%",
                artifacts,
                details,
            )

        if phase1_completed_transfer:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted upload phase completed the target file transfer before SIGINT landed, so no resumable upload state was guaranteed",
                artifacts,
                details,
            )

        if not interrupted_as_expected:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Interrupted upload phase did not terminate as expected after threshold was reached; return code was {phase1_returncode}",
                artifacts,
                details,
            )

        if not resumable_state_files:
            return self._scenario_fail(
                scenario_id,
                description,
                "Interrupted upload phase did not leave resumable upload session state on disk",
                artifacts,
                details,
            )

        if phase2_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Resumable upload recovery with dangling symlink source failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        upload_resume_markers = [
            "There are interrupted session uploads that need to be resumed",
            "Attempting to restore file upload session using this session data file",
            "Attempting to restore file upload session",
        ]
        if not self._contains_any_marker(combined_phase2_output, upload_resume_markers):
            return self._scenario_fail(
                scenario_id,
                description,
                "Subsequent upload run did not show evidence of resumable upload recovery before handling the dangling symlink source",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        # This scenario validates the #3770 safety invariant: an interrupted
        # upload session whose source has become a dangling symlink must be
        # handled without crashing, must not upload the invalid symlink source,
        # and must not leave the invalid resumable session state behind. The
        # sibling control file remains useful diagnostic evidence, but requiring
        # it to upload in the same pass makes the E2E result depend on local scan
        # ordering after the intentionally invalid path is encountered.
        if not (details["phase2_file_exception_seen"] or details["phase2_no_such_file_seen"]):
            return self._scenario_fail(
                scenario_id,
                description,
                "Dangling symlink upload-session source was not exercised during recovery",
                artifacts,
                details,
            )

        if details["post_phase2_resumable_state_files"]:
            return self._scenario_fail(
                scenario_id,
                description,
                "Invalid resumable upload session state was not cleaned up after dangling symlink handling",
                artifacts,
                details,
            )

        if details["dangling_source_uploaded"]:
            return self._scenario_fail(
                scenario_id,
                description,
                "Dangling symlink upload-session source was unexpectedly synchronised as a remote file",
                artifacts,
                details,
            )

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def _run_modified_xlsx_session_replacement_scenario(
        self,
        context: E2EContext,
        root_name: str,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "RT-0004"
        description = "modified multi-fragment XLSX upload session replacement"

        sync_root = scenario_work_dir / "syncroot"
        verify_root = scenario_work_dir / "verifyroot"
        conf_dir = scenario_work_dir / "conf"
        verify_conf_dir = scenario_work_dir / "verify-conf"
        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        reset_directory(sync_root)
        reset_directory(verify_root)
        reset_directory(conf_dir)
        reset_directory(verify_conf_dir)
        context.bootstrap_config_dir(conf_dir)
        context.bootstrap_config_dir(verify_conf_dir)

        self._write_config(
            conf_dir / "config",
            sync_root,
            app_log_dir,
            extra_config_lines=['file_fragment_size = "10"'],
        )
        self._write_config(
            verify_conf_dir / "config",
            verify_root,
            verify_app_log_dir,
            extra_config_lines=['file_fragment_size = "10"'],
        )

        app_log_file = self._phase_app_log_file(app_log_dir)
        verify_app_log_file = self._phase_app_log_file(verify_app_log_dir)

        relative_path = f"{root_name}/{scenario_id}/session-replacement.xlsx"
        local_file = sync_root / relative_path
        verify_file = verify_root / relative_path
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:{scenario_id}:{os.getpid()}"

        seed_stdout = scenario_log_dir / "seed_stdout.log"
        seed_stderr = scenario_log_dir / "seed_stderr.log"
        modify_stdout = scenario_log_dir / "modify_stdout.log"
        modify_stderr = scenario_log_dir / "modify_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"
        metadata_file = scenario_state_dir / "metadata.txt"
        pre_modify_state_file = scenario_state_dir / "pre_modify_state.txt"
        post_modify_state_file = scenario_state_dir / "post_modify_state.txt"
        session_guid_file = scenario_state_dir / "session_guid_sequence.txt"
        verify_manifest_file = scenario_state_dir / "verify_manifest.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(modify_stdout),
            str(modify_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(metadata_file),
            str(pre_modify_state_file),
            str(post_modify_state_file),
            str(session_guid_file),
            str(verify_manifest_file),
        ]

        try:
            generated = self._create_random_xlsx(local_file, xlsx_seed)
        except Exception as exc:
            details = {
                "scenario_id": scenario_id,
                "xlsx_seed": xlsx_seed,
                "generation_error": str(exc),
            }
            write_text_file(metadata_file, f"generation_error={exc}\n")
            return self._scenario_fail(
                scenario_id,
                description,
                f"Failed to generate runtime XLSX fixture: {exc}",
                artifacts,
                details,
            )

        generated_size = local_file.stat().st_size
        write_text_file(
            pre_modify_state_file,
            "\n".join(
                [
                    f"xlsx_seed={xlsx_seed}",
                    f"generated_size={generated_size}",
                    f"generated_revision={self.XLSX_REVISION_0}",
                    f"payload_rows={generated['payload_rows']}",
                    f"payload_bytes_per_row={generated['payload_bytes_per_row']}",
                ]
            )
            + "\n",
        )

        if generated_size <= self.XLSX_MIN_SIZE_BYTES:
            details = {
                "scenario_id": scenario_id,
                "xlsx_seed": xlsx_seed,
                "generated_size": generated_size,
                "required_minimum_size": self.XLSX_MIN_SIZE_BYTES + 1,
            }
            return self._scenario_fail(
                scenario_id,
                description,
                "Generated XLSX did not exceed two 10 MiB fragments; multi-fragment regression coverage is not guaranteed",
                artifacts,
                details,
            )

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]
        seed_result = self._run_and_capture(
            context,
            f"{scenario_id} seed",
            seed_command,
            seed_stdout,
            seed_stderr,
        )

        if seed_result.returncode != 0:
            details = {
                "scenario_id": scenario_id,
                "seed_returncode": seed_result.returncode,
                "relative_path": relative_path,
                "generated_size": generated_size,
            }
            return self._scenario_fail(
                scenario_id,
                description,
                f"Initial XLSX seed upload failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        canonical_validation_error = self._validate_xlsx(local_file, self.XLSX_REVISION_0)
        if canonical_validation_error:
            details = {
                "scenario_id": scenario_id,
                "seed_returncode": seed_result.returncode,
                "relative_path": relative_path,
                "canonical_validation_error": canonical_validation_error,
            }
            return self._scenario_fail(
                scenario_id,
                description,
                f"Post-seed local XLSX is not a valid canonical workbook: {canonical_validation_error}",
                artifacts,
                details,
            )

        canonical_size_before_modify = local_file.stat().st_size
        if canonical_size_before_modify <= self.XLSX_MIN_SIZE_BYTES:
            details = {
                "scenario_id": scenario_id,
                "relative_path": relative_path,
                "canonical_size_before_modify": canonical_size_before_modify,
                "required_minimum_size": self.XLSX_MIN_SIZE_BYTES + 1,
            }
            return self._scenario_fail(
                scenario_id,
                description,
                "Canonical XLSX after initial upload/enrichment no longer exceeds the multi-fragment boundary",
                artifacts,
                details,
            )

        try:
            self._mutate_xlsx_revision(local_file)
        except Exception as exc:
            details = {
                "scenario_id": scenario_id,
                "relative_path": relative_path,
                "mutation_error": str(exc),
            }
            return self._scenario_fail(
                scenario_id,
                description,
                f"Failed to mutate the canonical XLSX in place: {exc}",
                artifacts,
                details,
            )

        modified_size = local_file.stat().st_size
        write_text_file(
            post_modify_state_file,
            "\n".join(
                [
                    f"canonical_size_before_modify={canonical_size_before_modify}",
                    f"modified_size={modified_size}",
                    f"modified_revision={self.XLSX_REVISION_1}",
                ]
            )
            + "\n",
        )

        if modified_size <= self.XLSX_MIN_SIZE_BYTES:
            details = {
                "scenario_id": scenario_id,
                "relative_path": relative_path,
                "modified_size": modified_size,
                "required_minimum_size": self.XLSX_MIN_SIZE_BYTES + 1,
            }
            return self._scenario_fail(
                scenario_id,
                description,
                "Modified XLSX no longer exceeds the multi-fragment session-upload boundary",
                artifacts,
                details,
            )

        # The seed upload has already written this application's log. Remove it
        # before the modified-file phase so the GUID sequence below contains
        # only the session upload under test.
        app_log_file.unlink(missing_ok=True)

        # RT-0004 validates the real Microsoft response and upload-session GUID
        # continuity during replacement. Those diagnostics require the client's
        # double-verbose logging level, so use --verbose --verbose for the
        # modified-upload phase being inspected. This does not inject or
        # manufacture any API response.
        modify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(conf_dir),
        ]
        modify_result = self._run_and_capture(
            context,
            f"{scenario_id} modified upload",
            modify_command,
            modify_stdout,
            modify_stderr,
        )

        modify_app_log_text = self._read_text_if_exists(app_log_file)
        combined_modify_output = (
            modify_result.stdout + "\n" + modify_result.stderr + "\n" + modify_app_log_text
        )
        session_guids = self._extract_upload_session_guids(
            modify_app_log_text if modify_app_log_text else combined_modify_output
        )
        write_text_file(session_guid_file, "\n".join(session_guids) + ("\n" if session_guids else ""))

        upload_session_not_found_seen = (
            "The upload session was not found" in combined_modify_output
            and "itemNotFound" in combined_modify_output
        )
        replacement_adopted_seen = (
            "Adopted replacement upload session after 404; restarting from offset: 0"
            in combined_modify_output
        )
        name_already_exists_seen = "nameAlreadyExists" in combined_modify_output
        safe_backup_seen = "safeBackup" in combined_modify_output
        modified_upload_done_seen = (
            f"Uploading modified file: {relative_path} ... done" in combined_modify_output
        )

        replacement_guid_continuity = False
        if len(session_guids) >= 3:
            original_guid = session_guids[0]
            replacement_guid = session_guids[1]
            replacement_guid_continuity = (
                original_guid != replacement_guid
                and all(guid == replacement_guid for guid in session_guids[1:])
            )

        post_modify_resumable_state_files = self._find_resumable_state_files(
            conf_dir,
            ["session_upload*", "session_upload.*"],
        )
        safe_backup_files = sorted(
            str(path.relative_to(sync_root))
            for path in sync_root.rglob("*safeBackup*")
            if path.is_file()
        )

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--confdir",
            str(verify_conf_dir),
        ]
        verify_result = self._run_and_capture(
            context,
            f"{scenario_id} verify",
            verify_command,
            verify_stdout,
            verify_stderr,
        )
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        verify_validation_error = self._validate_xlsx(verify_file, self.XLSX_REVISION_1)
        self._append_if_exists(artifacts, app_log_dir)
        self._append_if_exists(artifacts, verify_app_log_dir)

        # The exact first-fragment 404 is a SharePoint document-library service
        # behaviour. Other account types still exercise a real modified XLSX
        # multi-fragment session upload, but only the SharePoint target requires
        # the replacement-session path to occur on every E2E run.
        replacement_required = context.e2e_target == "sharepoint"
        details = {
            "scenario_id": scenario_id,
            "relative_path": relative_path,
            "xlsx_seed": xlsx_seed,
            "generated_size": generated_size,
            "canonical_size_before_modify": canonical_size_before_modify,
            "modified_size": modified_size,
            "seed_returncode": seed_result.returncode,
            "modify_returncode": modify_result.returncode,
            "verify_returncode": verify_result.returncode,
            "replacement_required": replacement_required,
            "upload_session_not_found_seen": upload_session_not_found_seen,
            "replacement_adopted_seen": replacement_adopted_seen,
            "session_guids": session_guids,
            "replacement_guid_continuity": replacement_guid_continuity,
            "name_already_exists_seen": name_already_exists_seen,
            "safe_backup_seen": safe_backup_seen,
            "safe_backup_files": safe_backup_files,
            "modified_upload_done_seen": modified_upload_done_seen,
            "post_modify_resumable_state_files": post_modify_resumable_state_files,
            "verify_validation_error": verify_validation_error,
        }

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"scenario_id={scenario_id}",
                    f"relative_path={relative_path}",
                    f"xlsx_seed={xlsx_seed}",
                    f"generated_size={generated_size}",
                    f"canonical_size_before_modify={canonical_size_before_modify}",
                    f"modified_size={modified_size}",
                    f"seed_returncode={seed_result.returncode}",
                    f"modify_returncode={modify_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"replacement_required={replacement_required}",
                    f"upload_session_not_found_seen={upload_session_not_found_seen}",
                    f"replacement_adopted_seen={replacement_adopted_seen}",
                    f"session_guid_count={len(session_guids)}",
                    f"replacement_guid_continuity={replacement_guid_continuity}",
                    f"name_already_exists_seen={name_already_exists_seen}",
                    f"safe_backup_seen={safe_backup_seen}",
                    f"safe_backup_file_count={len(safe_backup_files)}",
                    f"modified_upload_done_seen={modified_upload_done_seen}",
                    f"post_modify_resumable_state_file_count={len(post_modify_resumable_state_files)}",
                    f"verify_validation_error={verify_validation_error}",
                ]
            )
            + "\n",
        )

        if modify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Modified XLSX upload failed with status {modify_result.returncode}",
                artifacts,
                details,
            )

        if not modified_upload_done_seen:
            return self._scenario_fail(
                scenario_id,
                description,
                "Modified XLSX upload did not report successful completion",
                artifacts,
                details,
            )

        if replacement_required and not upload_session_not_found_seen:
            return self._scenario_fail(
                scenario_id,
                description,
                "SharePoint modified-XLSX upload did not exercise the expected upload-session-not-found recovery path",
                artifacts,
                details,
            )

        if upload_session_not_found_seen and not replacement_adopted_seen:
            return self._scenario_fail(
                scenario_id,
                description,
                "Upload-session 404 was observed but the replacement session was not adopted",
                artifacts,
                details,
            )

        if upload_session_not_found_seen and not replacement_guid_continuity:
            return self._scenario_fail(
                scenario_id,
                description,
                "Replacement upload-session GUID was not used consistently for all fragments after the 404 recovery",
                artifacts,
                details,
            )

        if name_already_exists_seen:
            return self._scenario_fail(
                scenario_id,
                description,
                "Modified XLSX upload regressed to nameAlreadyExists after upload-session replacement",
                artifacts,
                details,
            )

        if safe_backup_seen or safe_backup_files:
            return self._scenario_fail(
                scenario_id,
                description,
                "Modified XLSX upload unexpectedly created or reported a safeBackup",
                artifacts,
                details,
            )

        if post_modify_resumable_state_files:
            return self._scenario_fail(
                scenario_id,
                description,
                "Successful modified XLSX upload left stale resumable upload-session state behind",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Remote XLSX verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if verify_validation_error:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Remote verification did not contain the expected modified XLSX revision: {verify_validation_error}",
                artifacts,
                details,
            )

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0021",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        root_name = f"ZZ_E2E_TC0021_{context.run_id}_{os.getpid()}"

        upload_sync_root = case_work_dir / "upload-syncroot"
        upload_verify_root = case_work_dir / "upload-verifyroot"
        upload_work_dir = case_work_dir / "rt0001-upload"
        upload_log_dir = case_log_dir / "rt0001-upload"
        upload_state_dir = state_dir / "rt0001-upload"

        reset_directory(upload_sync_root)
        reset_directory(upload_verify_root)
        reset_directory(upload_work_dir)
        reset_directory(upload_log_dir)
        reset_directory(upload_state_dir)

        results: list[ScenarioResult] = []

        if context.should_run_scenario(self.case_id, "RT-0001"):
            results.append(
                self._run_upload_resume_scenario(
                    context,
                    root_name,
                    upload_sync_root,
                    upload_verify_root,
                    upload_work_dir,
                    upload_log_dir,
                    upload_state_dir,
                )
            )

        download_work_dir = case_work_dir / "rt0002-download"
        download_log_dir = case_log_dir / "rt0002-download"
        download_state_dir = state_dir / "rt0002-download"

        reset_directory(download_work_dir)
        reset_directory(download_log_dir)
        reset_directory(download_state_dir)

        if context.should_run_scenario(self.case_id, "RT-0002"):
            results.append(
                self._run_download_resume_scenario(
                    context,
                    root_name,
                    download_work_dir,
                    download_log_dir,
                    download_state_dir,
                )
            )

        upload_symlink_sync_root = case_work_dir / "upload-symlink-syncroot"
        upload_symlink_verify_root = case_work_dir / "upload-symlink-verifyroot"
        upload_symlink_work_dir = case_work_dir / "rt0003-upload-dangling-symlink"
        upload_symlink_log_dir = case_log_dir / "rt0003-upload-dangling-symlink"
        upload_symlink_state_dir = state_dir / "rt0003-upload-dangling-symlink"

        reset_directory(upload_symlink_sync_root)
        reset_directory(upload_symlink_verify_root)
        reset_directory(upload_symlink_work_dir)
        reset_directory(upload_symlink_log_dir)
        reset_directory(upload_symlink_state_dir)

        if context.should_run_scenario(self.case_id, "RT-0003"):
            results.append(
                self._run_upload_resume_dangling_symlink_scenario(
                    context,
                    root_name,
                    upload_symlink_sync_root,
                    upload_symlink_verify_root,
                    upload_symlink_work_dir,
                    upload_symlink_log_dir,
                    upload_symlink_state_dir,
                )
            )

        xlsx_replacement_work_dir = case_work_dir / "rt0004-modified-xlsx-session-replacement"
        xlsx_replacement_log_dir = case_log_dir / "rt0004-modified-xlsx-session-replacement"
        xlsx_replacement_state_dir = state_dir / "rt0004-modified-xlsx-session-replacement"

        reset_directory(xlsx_replacement_work_dir)
        reset_directory(xlsx_replacement_log_dir)
        reset_directory(xlsx_replacement_state_dir)

        if context.should_run_scenario(self.case_id, "RT-0004"):
            results.append(
                self._run_modified_xlsx_session_replacement_scenario(
                    context,
                    root_name,
                    xlsx_replacement_work_dir,
                    xlsx_replacement_log_dir,
                    xlsx_replacement_state_dir,
                )
            )

        upload_source_change_sync_root = case_work_dir / "upload-source-change-syncroot"
        upload_source_change_verify_root = case_work_dir / "upload-source-change-verifyroot"
        upload_source_change_work_dir = case_work_dir / "rt0005-upload-source-change"
        upload_source_change_log_dir = case_log_dir / "rt0005-upload-source-change"
        upload_source_change_state_dir = state_dir / "rt0005-upload-source-change"

        reset_directory(upload_source_change_sync_root)
        reset_directory(upload_source_change_verify_root)
        reset_directory(upload_source_change_work_dir)
        reset_directory(upload_source_change_log_dir)
        reset_directory(upload_source_change_state_dir)

        if context.should_run_scenario(self.case_id, "RT-0005"):
            results.append(
                self._run_upload_source_change_scenario(
                    context,
                    root_name,
                    upload_source_change_sync_root,
                    upload_source_change_verify_root,
                    upload_source_change_work_dir,
                    upload_source_change_log_dir,
                    upload_source_change_state_dir,
                )
            )

        failed = [result for result in results if not result.passed]
        artifacts: list[str] = []
        details: dict = {
            "root_name": root_name,
            "executed_scenario_ids": [result.scenario_id for result in results],
            "failed_scenario_ids": [result.scenario_id for result in failed],
            "scenario_results": {},
        }

        for result in results:
            if result.artifacts:
                artifacts.extend(result.artifacts)
            if result.details:
                details["scenario_results"][result.scenario_id] = result.details

        deduped_artifacts = []
        seen = set()
        for artifact in artifacts:
            if artifact not in seen:
                deduped_artifacts.append(artifact)
                seen.add(artifact)

        summary_file = state_dir / "scenario_summary.txt"
        summary_lines = []
        for result in results:
            status = "PASS" if result.passed else "FAIL"
            line = f"{result.scenario_id} [{status}] {result.description}"
            if result.failure_message:
                line += f" — {result.failure_message}"
            summary_lines.append(line)
        write_text_file(summary_file, "\n".join(summary_lines) + "\n")
        deduped_artifacts.append(str(summary_file))

        if failed:
            failed_ids = ", ".join(result.scenario_id for result in failed)
            first_failure = failed[0].failure_message or "scenario failure"
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failed)} of {len(results)} resumable transfer scenarios failed: {failed_ids} — {first_failure}",
                deduped_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, deduped_artifacts, details)