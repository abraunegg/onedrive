from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx, mutate_xlsx_revision, validate_xlsx
from framework.pdf import create_random_pdf, mutate_pdf_revision, validate_pdf
from framework.image import create_random_image_set, mutate_image_set_revision, validate_image_set, image_set_hashes, set_image_set_mtime


class TestCase0029LocalFirstUploadOnlyTimestampPreservationValidation(E2ETestCase):
    case_id = "0029"
    name = "local_first upload_only Microsoft file timestamp preservation validation"
    description = (
        "Validate with real XLSX/PDF documents and a real PNG/JPEG image set that --local-first --upload-only uploads local content "
        "without rewriting local file timestamps from Microsoft API response data"
    )

    XLSX_PAYLOAD_ROWS = 80
    FIXED_MTIME_INITIAL = 1577882096  # 2020-01-01 12:34:56 UTC
    FIXED_MTIME_UPDATED = 1577968496  # 2020-01-02 12:34:56 UTC

    def _write_config(self, config_path: Path, sync_dir: Path) -> None:
        content = (
            "# tc0029 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'upload_only = "true"\n'
            'local_first = "true"\n'
            'cleanup_local_files = "false"\n'
            'bypass_data_preservation = "false"\n'
        )
        write_onedrive_config(config_path, content)

    def _set_file_mtime(self, path: Path, epoch_seconds: int) -> None:
        os.utime(path, (epoch_seconds, epoch_seconds))

    def _file_stat_snapshot(self, path: Path) -> dict[str, object]:
        stat_data = path.stat()
        return {
            "mtime": int(stat_data.st_mtime),
            "size": stat_data.st_size,
        }

    def _assert_local_file_state(
        self,
        path: Path,
        expected_revision: str,
        expected_hash: str,
        expected_mtime: int,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        if not path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} did not leave the expected local file in place",
                artifacts,
                details,
            )

        validation_error = validate_xlsx(path, expected_revision)
        actual_hash = compute_quickxor_hash_file(path)
        actual_mtime = int(path.stat().st_mtime)

        details[f"{phase_name}_validation_error"] = validation_error
        details[f"{phase_name}_actual_hash"] = actual_hash
        details[f"{phase_name}_actual_mtime"] = actual_mtime
        details[f"{phase_name}_expected_revision"] = expected_revision
        details[f"{phase_name}_expected_hash"] = expected_hash
        details[f"{phase_name}_expected_mtime"] = expected_mtime

        if validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} left an invalid XLSX workbook: {validation_error}",
                artifacts,
                details,
            )

        if actual_hash != expected_hash:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local XLSX content unexpectedly",
                artifacts,
                details,
            )

        if actual_mtime != expected_mtime:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local file timestamp unexpectedly",
                artifacts,
                details,
            )

        return None


    def _assert_local_pdf_state(
        self,
        path: Path,
        expected_revision: str,
        expected_hash: str,
        expected_mtime: int,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        if not path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} did not leave the expected local PDF in place",
                artifacts,
                details,
            )

        validation_error = validate_pdf(path, expected_revision)
        actual_hash = compute_quickxor_hash_file(path)
        actual_mtime = int(path.stat().st_mtime)

        details[f"{phase_name}_pdf_validation_error"] = validation_error
        details[f"{phase_name}_pdf_actual_hash"] = actual_hash
        details[f"{phase_name}_pdf_actual_mtime"] = actual_mtime
        details[f"{phase_name}_pdf_expected_revision"] = expected_revision
        details[f"{phase_name}_pdf_expected_hash"] = expected_hash
        details[f"{phase_name}_pdf_expected_mtime"] = expected_mtime

        if validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} left an invalid PDF document: {validation_error}",
                artifacts,
                details,
            )

        if actual_hash != expected_hash:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local PDF content unexpectedly",
                artifacts,
                details,
            )

        if actual_mtime != expected_mtime:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local PDF timestamp unexpectedly",
                artifacts,
                details,
            )

        return None

    def _assert_local_image_state(
        self,
        path: Path,
        expected_revision: str,
        expected_hashes: dict[str, str],
        expected_mtime: int,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        if not path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} did not leave the expected local image set in place",
                artifacts,
                details,
            )

        validation_error = validate_image_set(path, expected_revision)
        actual_hashes = image_set_hashes(path, compute_quickxor_hash_file)
        actual_mtime = int(path.stat().st_mtime)

        details[f"{phase_name}_image_validation_error"] = validation_error
        details[f"{phase_name}_image_actual_hashes"] = actual_hashes
        details[f"{phase_name}_image_actual_mtime"] = actual_mtime
        details[f"{phase_name}_image_expected_revision"] = expected_revision
        details[f"{phase_name}_image_expected_hashes"] = expected_hashes
        details[f"{phase_name}_image_expected_mtime"] = expected_mtime

        if validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} left an invalid image set: {validation_error}",
                artifacts,
                details,
            )

        if actual_hashes != expected_hashes:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local image-set content unexpectedly",
                artifacts,
                details,
            )

        if actual_mtime != expected_mtime:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{phase_name} changed the local image-set timestamp unexpectedly",
                artifacts,
                details,
            )

        return None

    def _assert_no_download_activity(
        self,
        stdout_text: str,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        unexpected_markers = [
            "Downloading file:",
            "Creating local directory",
        ]
        for marker in unexpected_markers:
            if marker in stdout_text:
                details[f"{phase_name}_unexpected_download_marker"] = marker
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"{phase_name} showed unexpected download-side local reconciliation activity in upload-only mode",
                    artifacts,
                    details,
                )
        return None

    def _assert_no_upload_activity(
        self,
        stdout_text: str,
        phase_name: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> TestResult | None:
        unexpected_markers = [
            "Uploading new file:",
            "Uploading modified file:",
            "Uploading file:",
        ]
        for marker in unexpected_markers:
            if marker in stdout_text:
                details[f"{phase_name}_unexpected_upload_marker"] = marker
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"{phase_name} unexpectedly attempted another upload despite no local changes",
                    artifacts,
                    details,
                )
        return None

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0029",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        conf_dir = case_work_dir / "conf"
        reset_directory(sync_root)

        context.bootstrap_config_dir(conf_dir)
        self._write_config(conf_dir / "config", sync_root)

        root_name = f"ZZ_E2E_TC0029_{context.run_id}_{os.getpid()}"
        relative_file = f"{root_name}/timestamp-probe.xlsx"
        pdf_relative_file = f"{root_name}/timestamp-probe.pdf"
        image_relative_file = f"{root_name}/timestamp-probe.png"
        local_file = sync_root / relative_file
        local_pdf_file = sync_root / pdf_relative_file
        local_image_file = sync_root / image_relative_file
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0029:{os.getpid()}"
        pdf_seed = f"{xlsx_seed}:pdf"
        image_seed = f"{xlsx_seed}:image"

        phase1_stdout = case_log_dir / "phase1_initial_upload_stdout.log"
        phase1_stderr = case_log_dir / "phase1_initial_upload_stderr.log"
        phase2_stdout = case_log_dir / "phase2_modified_upload_stdout.log"
        phase2_stderr = case_log_dir / "phase2_modified_upload_stderr.log"
        phase3_stdout = case_log_dir / "phase3_noop_sync_stdout.log"
        phase3_stderr = case_log_dir / "phase3_noop_sync_stderr.log"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(phase3_stdout),
            str(phase3_stderr),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "root_name": root_name,
            "relative_file": relative_file,
            "xlsx_seed": xlsx_seed,
            "pdf_relative_file": pdf_relative_file,
            "pdf_seed": pdf_seed,
            "image_relative_file": image_relative_file,
            "image_seed": image_seed,
        }

        # Phase 1: create a real Microsoft XLSX file, set a fixed local timestamp, and upload it.
        generated = create_random_xlsx(
            local_file,
            xlsx_seed,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0029 upload-only timestamp preservation workbook",
        )
        generated_pdf = create_random_pdf(
            local_pdf_file,
            pdf_seed,
            revision=REVISION_0,
            title="TC0029 upload-only timestamp preservation PDF",
        )
        generated_images = create_random_image_set(
            local_image_file,
            image_seed,
            revision=REVISION_0,
            title="TC0029 upload-only timestamp preservation images",
        )
        initial_hash = compute_quickxor_hash_file(local_file)
        initial_pdf_hash = compute_quickxor_hash_file(local_pdf_file)
        initial_image_hashes = image_set_hashes(local_image_file, compute_quickxor_hash_file)
        details["generated_size"] = int(generated["size_bytes"])
        details["generated_pdf_size"] = int(generated_pdf["size_bytes"])
        details["generated_image_sizes"] = {k: int(v) for k, v in generated_images.items() if k.endswith("_size_bytes")}
        details["initial_hash"] = initial_hash
        details["initial_pdf_hash"] = initial_pdf_hash
        details["initial_image_hashes"] = initial_image_hashes
        self._set_file_mtime(local_file, self.FIXED_MTIME_INITIAL)
        self._set_file_mtime(local_pdf_file, self.FIXED_MTIME_INITIAL)
        set_image_set_mtime(local_image_file, (self.FIXED_MTIME_INITIAL, self.FIXED_MTIME_INITIAL))
        phase1_before = self._file_stat_snapshot(local_file)
        phase1_pdf_before = self._file_stat_snapshot(local_pdf_file)
        phase1_image_before = self._file_stat_snapshot(local_image_file)

        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--upload-only",
            "--local-first",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_dir),
        ]
        context.log(f"Executing Test Case {self.case_id} phase1: {command_to_string(phase1_command)}")
        phase1_result = run_command(phase1_command, cwd=context.repo_root)
        write_text_file(phase1_stdout, phase1_result.stdout)
        write_text_file(phase1_stderr, phase1_result.stderr)
        phase1_after = self._file_stat_snapshot(local_file)
        phase1_pdf_after = self._file_stat_snapshot(local_pdf_file)
        phase1_image_after = self._file_stat_snapshot(local_image_file)

        details["phase1_returncode"] = phase1_result.returncode
        details["phase1_before"] = phase1_before
        details["phase1_after"] = phase1_after
        details["phase1_pdf_before"] = phase1_pdf_before
        details["phase1_pdf_after"] = phase1_pdf_after
        details["phase1_image_before"] = phase1_image_before
        details["phase1_image_after"] = phase1_image_after

        if phase1_result.returncode != 0:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return self.fail_result(
                self.case_id,
                self.name,
                f"initial upload phase failed with status {phase1_result.returncode}",
                artifacts,
                details,
            )

        failure = self._assert_no_download_activity(
            phase1_result.stdout,
            "Initial upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_file_state(
            local_file,
            REVISION_0,
            initial_hash,
            self.FIXED_MTIME_INITIAL,
            "Initial upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_pdf_state(
            local_pdf_file,
            REVISION_0,
            initial_pdf_hash,
            self.FIXED_MTIME_INITIAL,
            "Initial upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_image_state(
            local_image_file,
            REVISION_0,
            initial_image_hashes,
            self.FIXED_MTIME_INITIAL,
            "Initial upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        # Phase 2: mutate the real XLSX content, set a newer fixed local timestamp, and upload again.
        time.sleep(2)
        mutate_xlsx_revision(local_file, REVISION_0, REVISION_1)
        mutate_pdf_revision(local_pdf_file, REVISION_0, REVISION_1)
        mutate_image_set_revision(local_image_file, REVISION_0, REVISION_1)
        updated_hash = compute_quickxor_hash_file(local_file)
        updated_pdf_hash = compute_quickxor_hash_file(local_pdf_file)
        updated_image_hashes = image_set_hashes(local_image_file, compute_quickxor_hash_file)
        details["updated_hash"] = updated_hash
        details["updated_pdf_hash"] = updated_pdf_hash
        details["updated_image_hashes"] = updated_image_hashes
        if updated_hash == initial_hash:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return self.fail_result(
                self.case_id,
                self.name,
                "XLSX revision mutation did not change the local workbook content",
                artifacts,
                details,
            )
        if updated_pdf_hash == initial_pdf_hash:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return self.fail_result(
                self.case_id,
                self.name,
                "PDF revision mutation did not change the local document content",
                artifacts,
                details,
            )
        self._set_file_mtime(local_file, self.FIXED_MTIME_UPDATED)
        self._set_file_mtime(local_pdf_file, self.FIXED_MTIME_UPDATED)
        set_image_set_mtime(local_image_file, (self.FIXED_MTIME_UPDATED, self.FIXED_MTIME_UPDATED))
        phase2_before = self._file_stat_snapshot(local_file)
        phase2_pdf_before = self._file_stat_snapshot(local_pdf_file)
        phase2_image_before = self._file_stat_snapshot(local_image_file)

        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--upload-only",
            "--local-first",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_dir),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2: {command_to_string(phase2_command)}")
        phase2_result = run_command(phase2_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)
        phase2_after = self._file_stat_snapshot(local_file)
        phase2_pdf_after = self._file_stat_snapshot(local_pdf_file)
        phase2_image_after = self._file_stat_snapshot(local_image_file)

        details["phase2_returncode"] = phase2_result.returncode
        details["phase2_before"] = phase2_before
        details["phase2_after"] = phase2_after
        details["phase2_pdf_before"] = phase2_pdf_before
        details["phase2_pdf_after"] = phase2_pdf_after
        details["phase2_image_before"] = phase2_image_before
        details["phase2_image_after"] = phase2_image_after

        if phase2_result.returncode != 0:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return self.fail_result(
                self.case_id,
                self.name,
                f"modified upload phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        failure = self._assert_no_download_activity(
            phase2_result.stdout,
            "Modified upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_file_state(
            local_file,
            REVISION_1,
            updated_hash,
            self.FIXED_MTIME_UPDATED,
            "Modified upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_pdf_state(
            local_pdf_file,
            REVISION_1,
            updated_pdf_hash,
            self.FIXED_MTIME_UPDATED,
            "Modified upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_image_state(
            local_image_file,
            REVISION_1,
            updated_image_hashes,
            self.FIXED_MTIME_UPDATED,
            "Modified upload phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        # Phase 3: run again with no local changes; the local file must remain untouched.
        time.sleep(2)
        phase3_before = self._file_stat_snapshot(local_file)
        phase3_pdf_before = self._file_stat_snapshot(local_pdf_file)
        phase3_image_before = self._file_stat_snapshot(local_image_file)

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--upload-only",
            "--local-first",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_dir),
        ]
        context.log(f"Executing Test Case {self.case_id} phase3: {command_to_string(phase3_command)}")
        phase3_result = run_command(phase3_command, cwd=context.repo_root)
        write_text_file(phase3_stdout, phase3_result.stdout)
        write_text_file(phase3_stderr, phase3_result.stderr)
        phase3_after = self._file_stat_snapshot(local_file)
        phase3_pdf_after = self._file_stat_snapshot(local_pdf_file)
        phase3_image_after = self._file_stat_snapshot(local_image_file)

        details["phase3_returncode"] = phase3_result.returncode
        details["phase3_before"] = phase3_before
        details["phase3_after"] = phase3_after
        details["phase3_pdf_before"] = phase3_pdf_before
        details["phase3_pdf_after"] = phase3_pdf_after
        details["phase3_image_before"] = phase3_image_before
        details["phase3_image_after"] = phase3_image_after

        if phase3_result.returncode != 0:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return self.fail_result(
                self.case_id,
                self.name,
                f"no-op sync phase failed with status {phase3_result.returncode}",
                artifacts,
                details,
            )

        failure = self._assert_no_download_activity(
            phase3_result.stdout,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_file_state(
            local_file,
            REVISION_1,
            updated_hash,
            self.FIXED_MTIME_UPDATED,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_pdf_state(
            local_pdf_file,
            REVISION_1,
            updated_pdf_hash,
            self.FIXED_MTIME_UPDATED,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_local_image_state(
            local_image_file,
            REVISION_1,
            updated_image_hashes,
            self.FIXED_MTIME_UPDATED,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        failure = self._assert_no_upload_activity(
            phase3_result.stdout,
            "No-op sync phase",
            artifacts,
            details,
        )
        if failure is not None:
            write_text_file(
                metadata_file,
                "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
            )
            return failure

        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

        return self.pass_result(self.case_id, self.name, artifacts, details)